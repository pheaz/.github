<!-- /README.md -->

# pheaz organization policy

OpenTofu manages persistent GitHub settings. `raven-actions/repo-files-sync`
propagates canonical contents through pull requests. Custom maintenance remains
responsible for branch garbage collection.

This is a staged migration. Merging the scaffold does not apply OpenTofu or
enable automatic file synchronization. Legacy scripts remain available until
their replacements pass the acceptance gates below.

## Ownership

| Concern | Replacement | Initial behavior |
| --- | --- | --- |
| Squash commit title | `tofu/` | `squash_merge_commit_title = PR_TITLE` on active non-fork repositories |
| Branch deletion after merging | `tofu/` | `delete_branch_on_merge = true` on active non-fork repositories |
| Other repository settings | Future OpenTofu adoption | Preserved through `ignore_changes` |
| Archived repositories | OpenTofu read-only adoption | Imported without setting changes |
| Three nested agent files | File-sync PRs | Active non-fork targets with an existing `.github` directory |
| `lint-pr.yml` | File-sync PRs | Every active non-fork target with a default branch |
| Organization rulesets | Existing configuration until compatible adoption | Enforcement and bypass actors remain unchanged |
| Branch garbage collection | Existing cleanup script | Predicate and SHA rechecks remain unchanged |

`delete_branch_on_merge` and `allow_auto_merge` are independent settings.
OpenTofu initially owns only the former and the squash title. The baseline
ruleset currently limits PR merging to squash; this migration does not change
repository-level merge-method switches.

## Canonical contents and discovery

`.github/sync-files.json` is the authoritative source/destination mapping.
Existing `.github/AGENTS.md`, `.github/actions/AGENTS.md`,
`.github/workflows/AGENTS.md`, and `.github/workflows/lint-pr.yml` remain their
canonical sources. The workflow is copied byte-for-byte and MUST NOT be edited
as part of this migration. Root `AGENTS.md` is deliberately excluded: the existing
agent-sync script does not propagate it. Adding it requires an explicit policy
change.

The layout deliberately keeps existing sources in place instead of duplicating
them under `canonical/`. Discovery generates `.github/sync.yml` and
`tofu/repositories.auto.tfvars.json`. Both are ignored by Git because the public
policy repository must not publish private target names. The generated sync
document uses JSON syntax, which is valid YAML.

Run from the repository root with Python 3.11+ and an authenticated GitHub CLI:

```bash
python3 .github/scripts/discover.py
```

Discovery uses only GET requests, paginates repository inventory, excludes forks,
records stable repository IDs, and checks `.github` directories. Permission,
authentication, and rate-limit failures stop generation. The credential MUST see
every organization repository; an installation restricted to selected
repositories MUST NOT be used for complete adoption. The sync app SHOULD be
installed on all repositories, including future repositories.

Generated inventory MUST be reviewed before each OpenTofu plan. Private target
names are masked before public Actions logs. Generated inventory, sync
configuration, plans, and state MUST NOT be uploaded as public artifacts.
Discovery adopts existing repositories; it does not create them.

## OpenTofu cutover

See [tofu/README.md](tofu/README.md) for bootstrap, state, imports, and plan review.

1. Discover and review the full organization inventory.
2. Generate and commit the provider lockfile using OpenTofu, then validate.
3. Review an adoption plan. It MUST import existing repositories and MUST NOT
   create, delete, rename, or change unrelated repository settings. Updates MUST
   be limited to the two owned settings.
4. Apply the reviewed saved plan; a fresh plan MUST show no changes.
5. Retire `set-pheaz-squash-commit-title-to-pr-title.sh` and
   `set-pheaz-delete-branch-on-merge.sh` in a follow-up PR. Operators MUST NOT run
   these legacy writers concurrently with OpenTofu after cutover.

The old squash-title script attempts archived repositories; delete-on-merge
skips them. Archived repositories do not expose these settings in the inspected
API response and are frozen by this migration. This is an intentional difference
from attempting archived writes. They MUST NOT be unarchived to make adoption pass.

## File-sync cutover

The workflow pins published `v0.1.0-rc.17` commit
`bb4d579be65a4086050c7e5441fb6f69a382db07`. As checked on 2026-10-06, stable
`v0.1.0` does not exist. The release candidate includes `dist/index.mjs`; `main`
does not. A release candidate is a deliberate pilot dependency; a stable release
SHOULD replace it after validation.

Configure a dedicated GitHub App installed on the policy and target repositories:

| Configuration | Value |
| --- | --- |
| Repository permissions | Metadata read; Contents write; Pull requests write; Workflows write |
| Variable `FILE_SYNC_APP_ID` | App ID |
| Secret `FILE_SYNC_APP_PRIVATE_KEY` | App private key |
| Variable `FILE_SYNC_ENABLED` | Unset during bootstrap; `true` after acceptance |

The app does not need ruleset administration or bypass permissions. The workflow
uses a read token for discovery, then a write token scoped to selected targets.
`GITHUB_TOKEN` is used for source checkout; cross-repository synchronization uses
the installation token so required target PR checks can run.

1. Merge the scaffold through normal review.
2. Dispatch **Sync canonical files** on `main`, select one `pheaz/repo`, and keep
   `dry_run = true`. Review differences.
3. Dispatch that pilot with `dry_run = false`. Review and merge its sync PR
   through the existing baseline ruleset. Validate its Conventional Commits title
   and required `validate-pr-title` check.
4. Repeat the pilot. It MUST produce no content change after merge; subsequent
   changes while a PR is open MUST reuse the existing sync PR.
5. Dispatch across all targets and review their PRs. After acceptance, set
   `FILE_SYNC_ENABLED = true`. Canonical changes then sync on push; weekly runs
   discover newly eligible repositories.
6. Retire `sync-pheaz-agents-by-sha.sh` and `sync.sh` in a follow-up PR.
   Operators MUST NOT use their ruleset-disabling path after cutover.

Sync preserves target-specific files, disables orphan deletion, and uses the
stable `repo-sync/pheaz-policy/main` branch. This policy repository is excluded
from targets because its source files are already canonical. The app MUST NOT
disable `ruleset-baseline`. Operators SHOULD treat sync branches as bot-owned
and MUST inspect any pre-existing branch with the same name before the pilot.
Archived repositories are skipped instead of reported as agent-write failures.

## Ruleset adoption gate

| Inspected organization ruleset | ID | Constraint in provider 6.13.0 |
| --- | --- | --- |
| `ruleset-baseline` | `24536027` | Does not represent `require_extra_approval_for_unattributed_changes = true` |
| Repository lifecycle guardrails | `24525606` | Does not support target `repository` |

Inherited repository responses do not expose complete organization repository
selectors. Before adoption, operators MUST export the full organization ruleset
with an organization-admin credential, including selectors, bypass actors,
enforcement, and every rule parameter. The provider MUST round-trip the complete
definition. Importing a partial approximation MUST NOT be used as a workaround.

There are no speculative `rulesets.tf` or `teams.tf` placeholders. Add those
resources when complete definitions and ownership are known. Secrets SHOULD be
adopted only after accounting for sensitive values in state; the sync app private
key remains outside initial OpenTofu ownership.

## Procedural maintenance

`scripts/delete-pheaz-behind-branches.sh` remains unchanged. It excludes forks,
archived repositories, and default branches; deletes only when
`ahead_by == 0 && behind_by > 0`; and rechecks the default branch name and both
SHAs before deletion. Identical, ahead, diverged, and changed-during-scan branches
are preserved. The rechecks reduce races; REST ref deletion is not an atomic
compare-and-delete operation. This migration does not schedule or execute it.

## Verification

```bash
python3 -m unittest discover -s .github/tests -v
python3 .github/scripts/discover.py --help
tofu -chdir=tofu fmt -check -recursive
tofu -chdir=tofu init -lockfile=readonly
tofu -chdir=tofu validate
```

Tests cover pagination, different target scopes, exclusions, pilot selection,
read failures, private-name masking, malformed inventory, and idempotent output.
Live OpenTofu plans and file-sync pilots require organization credentials and
the selected state backend.
