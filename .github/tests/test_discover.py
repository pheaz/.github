# /.github/tests/test_discover.py

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("discovery", ROOT / ".github/scripts/discover.py")
discovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(discovery)


def repository(name, *, fork=False, archived=False, branch="main", visibility="public"):
    return {
        "name": name,
        "full_name": f"pheaz/{name}",
        "id": 100 + sum(map(ord, name)),
        "fork": fork,
        "archived": archived,
        "default_branch": branch,
        "visibility": visibility,
    }


class FakeGitHub:
    def __init__(self, pages, directories=None):
        self.pages = pages
        self.directories = directories or {}
        self.calls = []

    def read(self, route, *, paginate=False, missing_ok=False):
        self.calls.append((route, paginate, missing_ok))
        if route.startswith("orgs/"):
            return self.pages
        response = self.directories[route.split("/")[2]]
        if isinstance(response, Exception):
            raise response
        return response


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.files = discovery.load_files(ROOT)
        self.source = repository(".github")

    def test_preserves_different_sync_scopes_across_pages(self):
        github = FakeGitHub(
            [
                [self.source, repository("existing"), repository("fork", fork=True)],
                [repository("missing"), repository("file"), repository("archived", archived=True), repository("empty", branch=None)],
            ],
            {"existing": [], "missing": None, "file": {"type": "file"}},
        )
        inventory, sync = discovery.discover(github, self.files)
        self.assertEqual(set(inventory["repositories"]), {".github", "existing", "missing", "file", "archived", "empty"})
        self.assertTrue(inventory["repositories"]["archived"]["archived"])
        self.assertEqual(set(sync), {"pheaz/existing", "pheaz/missing", "pheaz/file"})
        self.assertEqual(
            [file["dest"] for file in sync["pheaz/existing"]],
            [".github/AGENTS.md", ".github/actions/AGENTS.md", ".github/workflows/AGENTS.md", ".github/workflows/lint-pr.yml"],
        )
        self.assertEqual(sync["pheaz/missing"], self.files["workflows"])
        self.assertEqual(sync["pheaz/file"], self.files["workflows"])
        self.assertTrue(github.calls[0][1])

    def test_pilot_filters_only_sync_not_iac_inventory(self):
        github = FakeGitHub([[self.source, repository("first"), repository("second")]], {"first": []})
        inventory, sync = discovery.discover(github, self.files, "pheaz/first")
        self.assertEqual(set(inventory["repositories"]), {".github", "first", "second"})
        self.assertEqual(set(sync), {"pheaz/first"})
        self.assertEqual(len(github.calls), 2)

    def test_unknown_archived_fork_and_source_pilot_targets_are_rejected(self):
        pages = [[self.source, repository("archive", archived=True), repository("fork", fork=True)]]
        for target in ["pheaz/typo", "pheaz/archive", "pheaz/fork", "pheaz/.github"]:
            with self.subTest(target=target), self.assertRaises(discovery.DiscoveryError):
                discovery.discover(FakeGitHub(pages), self.files, target)

    def test_permission_error_is_not_treated_as_a_missing_directory(self):
        github = FakeGitHub([[self.source, repository("restricted")]], {"restricted": discovery.DiscoveryError("HTTP 403")})
        with self.assertRaisesRegex(discovery.DiscoveryError, "403"):
            discovery.discover(github, self.files)

    def test_empty_missing_source_duplicate_and_malformed_inventories_fail(self):
        cases = [[], [[]], [[repository("other")]], [[self.source, self.source]]]
        for key, value in [("id", True), ("fork", None), ("visibility", None), ("full_name", "other/.github")]:
            cases.append([[{**self.source, key: value}]])
        for pages in cases:
            with self.subTest(pages=pages), self.assertRaises(discovery.DiscoveryError):
                discovery.discover(FakeGitHub(pages), self.files)

    def test_private_names_are_masked_before_public_action_logs(self):
        output = io.StringIO()
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), contextlib.redirect_stdout(output):
            discovery.discover(
                FakeGitHub([[self.source, repository("private-target", visibility="private")]], {"private-target": []}),
                self.files,
            )
        self.assertEqual(output.getvalue(), "::add-mask::pheaz/private-target\n::add-mask::private-target\n")

    def test_output_is_idempotent_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested/sync.yml"
            discovery.write_if_changed(path, "first\n")
            timestamp = path.stat().st_mtime_ns
            discovery.write_if_changed(path, "first\n")
            self.assertEqual(path.stat().st_mtime_ns, timestamp)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            discovery.write_if_changed(path, "second\n")
            self.assertEqual(path.read_text(), "second\n")

    def test_invalid_source_paths_fail_before_discovery(self):
        for value in ["../outside", "/outside", "missing"]:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / ".github").mkdir()
                config = {"agents": [{"source": value, "dest": "AGENTS.md"}], "workflows": self.files["workflows"]}
                (root / ".github/sync-files.json").write_text(json.dumps(config))
                with self.assertRaises(discovery.DiscoveryError):
                    discovery.load_files(root)

    def test_cli_reads_use_get_and_slurp_all_pages(self):
        result = subprocess.CompletedProcess([], 0, stdout="[[]]", stderr="")
        with patch.object(discovery.subprocess, "run", return_value=result) as run:
            self.assertEqual(discovery.GitHub().read("orgs/pheaz/repos", paginate=True), [[]])
        self.assertEqual(run.call_args.args[0], ["gh", "api", "--method", "GET", "--paginate", "--slurp", "orgs/pheaz/repos"])

    def test_cli_only_accepts_404_as_a_missing_path(self):
        for status in [401, 403, 404, 429, 500]:
            result = subprocess.CompletedProcess([], 1, stdout="", stderr=f"gh: failed (HTTP {status})")
            with self.subTest(status=status), patch.object(discovery.subprocess, "run", return_value=result):
                if status == 404:
                    self.assertIsNone(discovery.GitHub().read("repos/pheaz/example/contents/.github", missing_ok=True))
                else:
                    with self.assertRaises(discovery.DiscoveryError):
                        discovery.GitHub().read("repos/pheaz/example/contents/.github", missing_ok=True)


if __name__ == "__main__":
    unittest.main()
