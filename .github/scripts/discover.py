#!/usr/bin/env python3
# /.github/scripts/discover.py

"""Discover existing GitHub objects; write local OpenTofu and file-sync inputs."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile


ORGANIZATION = "pheaz"
SOURCE_REPOSITORY = f"{ORGANIZATION}/.github"
ROOT = Path(__file__).resolve().parents[2]


class DiscoveryError(Exception):
    """A failed or ambiguous read that must prevent configuration generation."""


class GitHub:
    def read(self, route, *, paginate=False, missing_ok=False):
        arguments = ["gh", "api", "--method", "GET"]
        if paginate:
            arguments.extend(["--paginate", "--slurp"])
        result = subprocess.run(
            [*arguments, route], capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            # Distinguish a missing path from authentication/rate-limit failures.
            status = re.search(r"\(HTTP (\d{3})\)", result.stderr)
            if missing_ok and status and status.group(1) == "404":
                return None
            raise DiscoveryError(f"GitHub read failed for {route}: {result.stderr.strip()}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise DiscoveryError(f"Invalid GitHub JSON for {route}") from error


def load_files(root):
    config = json.loads((root / ".github/sync-files.json").read_text(encoding="utf-8"))
    if not isinstance(config, dict) or set(config) != {"agents", "workflows"}:
        raise DiscoveryError("File policy must contain exactly agents and workflows groups")
    for group, files in config.items():
        if not isinstance(files, list) or not files:
            raise DiscoveryError(f"File policy group {group} must be a nonempty list")
        for file in files:
            if not isinstance(file, dict) or set(file) != {"source", "dest"}:
                raise DiscoveryError("File policy entries require only source and dest")
            for value in file.values():
                if not isinstance(value, str) or not value:
                    raise DiscoveryError("File paths must be nonempty strings")
                path = PurePosixPath(value)
                if path.is_absolute() or ".." in path.parts:
                    raise DiscoveryError(f"File path must remain inside its repository: {value}")
            if not (root / file["source"]).is_file():
                raise DiscoveryError(f"Canonical source does not exist: {file['source']}")
    return config


def mask_private_repositories(repositories):
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    # Public source-repository logs must not disclose private target names.
    for repository in repositories:
        if repository["visibility"] != "public":
            for value in (repository["full_name"], repository["name"]):
                print(f"::add-mask::{value}", flush=True)


def discover(github, files, sync_repositories=""):
    pages = github.read(
        f"orgs/{ORGANIZATION}/repos?type=all&per_page=100", paginate=True
    )
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise DiscoveryError("Repository discovery did not return paginated lists")
    repositories = [repository for page in pages for repository in page]
    if not repositories:
        raise DiscoveryError("Empty organization inventory; refusing to generate configuration")
    seen = set()
    for repository in repositories:
        if not isinstance(repository, dict):
            raise DiscoveryError("Invalid repository inventory entry")
        name = repository.get("name")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", name):
            raise DiscoveryError("Invalid repository name in inventory")
        if repository.get("full_name") != f"{ORGANIZATION}/{name}" or name in seen:
            raise DiscoveryError("Duplicate repository or unexpected organization in inventory")
        seen.add(name)
        if type(repository.get("id")) is not int or repository["id"] <= 0:
            raise DiscoveryError("Repository ID must be a positive integer")
        if any(type(repository.get(key)) is not bool for key in ("fork", "archived")):
            raise DiscoveryError("Repository fork/archive flags must be booleans")
        if repository.get("visibility") not in {"public", "private", "internal"}:
            raise DiscoveryError("Repository visibility is missing or invalid")
        branch = repository.get("default_branch")
        if branch is not None and not isinstance(branch, str):
            raise DiscoveryError("Invalid default branch in repository inventory")
    if SOURCE_REPOSITORY not in {repository["full_name"] for repository in repositories}:
        raise DiscoveryError("Policy repository is missing; verify organization read access")
    mask_private_repositories(repositories)

    inventory = {}
    sync = {}
    requested = {name.strip() for name in sync_repositories.split(",") if name.strip()}
    eligible = set()
    for repository in sorted(repositories, key=lambda item: item["name"]):
        if repository["fork"]:
            continue
        name = repository["name"]
        full_name = repository["full_name"]
        inventory[name] = {"id": repository["id"], "archived": repository["archived"]}
        if repository["archived"] or not repository.get("default_branch"):
            continue
        if full_name == SOURCE_REPOSITORY:
            continue
        eligible.add(full_name)
        if requested and full_name not in requested:
            continue
        # Do not pin a branch name: repo-files-sync resolves the current default.
        mappings = list(files["workflows"])
        directory = github.read(f"repos/{full_name}/contents/.github", missing_ok=True)
        if isinstance(directory, list):
            mappings = [*files["agents"], *mappings]
        elif directory is not None and not isinstance(directory, dict):
            raise DiscoveryError(f"Unexpected .github response for {full_name}")
        sync[full_name] = mappings
    if not inventory:
        raise DiscoveryError("No non-fork repositories found")
    if requested - eligible:
        raise DiscoveryError("Requested sync repositories are not eligible organization targets")
    return {"repositories": inventory}, sync


def write_if_changed(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text(encoding="utf-8") == content:
        path.chmod(0o600)
        return
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as temporary:
        temporary.write(content)
        temporary_path = Path(temporary.name)
    try:
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sync-repositories", default="", help="Comma-separated owner/name pilot targets; empty means all"
    )
    parser.add_argument("--github-output", type=Path, help="GitHub Actions step output file")
    arguments = parser.parse_args()
    try:
        inventory, sync = discover(GitHub(), load_files(ROOT), arguments.sync_repositories)
        write_if_changed(
            ROOT / "tofu/repositories.auto.tfvars.json", json.dumps(inventory, indent=2) + "\n"
        )
        # JSON is valid YAML and avoids a runtime YAML package dependency.
        write_if_changed(
            ROOT / ".github/sync.yml",
            "# /.github/sync.yml\n# Generated by discover.py; MUST NOT be committed.\n"
            + json.dumps(sync, indent=2) + "\n",
        )
        if arguments.github_output:
            names = sorted({".github", *(name.split("/", 1)[1] for name in sync)})
            with arguments.github_output.open("a", encoding="utf-8") as output:
                output.write(f"has_targets={'true' if sync else 'false'}\n")
                output.write(f"token_repositories={','.join(names)}\n")
        print(
            f"Discovered {len(inventory['repositories'])} non-fork repositories; "
            f"generated {len(sync)} file-sync targets."
        )
        return 0
    except (DiscoveryError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
