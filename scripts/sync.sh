#!/usr/bin/env bash

ORG="${ORG:-pheaz}"
POLICY_REPO="$ORG/.github"

WORKFLOW_PATH=".github/workflows/lint-pr.yml"
SYNC_SCRIPT_PATH="scripts/sync.sh"
REUSABLE_WORKFLOW_PATH=".github/workflows/reusable-lint-pr.yml"

RULESET_NAME="Lint PR"
REQUIRED_CHECK="Validate PR title"
RUNNER_VAR="LINUX_SERVER"

API_VERSION="2026-03-10"


put_encoded_file() {
  local repo="$1"
  local branch="$2"
  local file_path="$3"
  local message="$4"
  local content="$5"
  local current
  local current_sha
  local current_content

  current="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$repo/contents/$file_path?ref=$branch" \
      2>/dev/null
  )"

  current_sha="$(
    printf '%s' "$current" |
      jq -r '.sha // empty'
  )"

  current_content="$(
    printf '%s' "$current" |
      jq -r '.content // empty' |
      tr -d '
'
  )"

  if [ "$current_content" = "$content" ]; then
    echo "Unchanged: $repo/$file_path"
    return 0
  fi

  if [ -n "$current_sha" ]; then
    gh api \
      --method PUT \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$repo/contents/$file_path" \
      -f message="$message" \
      -f content="$content" \
      -f branch="$branch" \
      -f sha="$current_sha" \
      >/dev/null

    return
  fi

  gh api \
    --method PUT \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repo/contents/$file_path" \
    -f message="$message" \
    -f content="$content" \
    -f branch="$branch" \
    >/dev/null
}


delete_file() {
  local repo="$1"
  local branch="$2"
  local file_path="$3"
  local message="$4"
  local sha

  sha="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$repo/contents/$file_path?ref=$branch" \
      --jq '.sha' \
      2>/dev/null
  )"

  if [ -z "$sha" ]; then
    return 0
  fi

  echo "Removing: $repo/$file_path"

  gh api \
    --method DELETE \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repo/contents/$file_path" \
    -f message="$message" \
    -f branch="$branch" \
    -f sha="$sha" \
    >/dev/null
}


ensure_canonical_workflow() {
  SOURCE="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$POLICY_REPO/contents/$WORKFLOW_PATH?ref=$POLICY_BRANCH" \
      2>/dev/null
  )"

  if [ -n "$SOURCE" ]; then
    return 0
  fi

  echo "Creating canonical workflow..."

  WORKFLOW_CONTENT="$(cat <<'YAML'
name: 'Lint PR'

on:
  pull_request_target:
    types:
      - opened
      - reopened
      - edited
      - synchronize

jobs:
  main:
    name: Validate PR title
    runs-on: ${{ vars.LINUX_SERVER }}
    permissions:
      pull-requests: read
    steps:
      - uses: amannn/action-semantic-pull-request@v6
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
YAML
)"

  ENCODED="$(
    printf '%s' "$WORKFLOW_CONTENT" |
      base64 |
      tr -d '\n'
  )"

  put_encoded_file \
    "$POLICY_REPO" \
    "$POLICY_BRANCH" \
    "$WORKFLOW_PATH" \
    "ci: configure Lint PR" \
    "$ENCODED"
}


install_sync_script() {
  SCRIPT_FILE="${BASH_SOURCE[0]}"

  if [ ! -f "$SCRIPT_FILE" ]; then
    echo "Cannot install $SYNC_SCRIPT_PATH because this script was not run from a file."
    return 1
  fi

  CONTENT="$(
    base64 < "$SCRIPT_FILE" |
      tr -d '\n'
  )"

  put_encoded_file \
    "$POLICY_REPO" \
    "$POLICY_BRANCH" \
    "$SYNC_SCRIPT_PATH" \
    "chore: add workflow sync script" \
    "$CONTENT"
}


get_ruleset() {
  RULESET_ID="$(
    gh api \
      --paginate \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets?per_page=100" |
      jq -r --arg name "$RULESET_NAME" '
        .[]
        | select(.name == $name)
        | .id
      ' |
      head -n1
  )"

  if [ -z "$RULESET_ID" ]; then
    ORIGINAL_RULESET=""
    ORIGINAL_ENFORCEMENT=""
    return 0
  fi

  ORIGINAL_RULESET="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets/$RULESET_ID"
  )" || return 1

  ORIGINAL_ENFORCEMENT="$(
    printf '%s' "$ORIGINAL_RULESET" |
      jq -r '.enforcement'
  )"
}


disable_ruleset() {
  if [ -z "$RULESET_ID" ]; then
    return 0
  fi

  echo "Temporarily disabling ruleset $RULESET_ID..."

  gh api \
    --method PUT \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "orgs/$ORG/rulesets/$RULESET_ID" \
    -f enforcement=disabled \
    >/dev/null
}


restore_ruleset() {
  if [ -z "$RULESET_ID" ]; then
    return 0
  fi

  if [ -z "$ORIGINAL_ENFORCEMENT" ]; then
    return 0
  fi

  echo "Restoring ruleset enforcement..."

  gh api \
    --method PUT \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "orgs/$ORG/rulesets/$RULESET_ID" \
    -f enforcement="$ORIGINAL_ENFORCEMENT" \
    >/dev/null
}


sync_repositories() {
  SOURCE_CONTENT="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$POLICY_REPO/contents/$WORKFLOW_PATH?ref=$POLICY_BRANCH" \
      --jq '.content' |
      tr -d '\n'
  )" || return 1

  if [ -z "$SOURCE_CONTENT" ]; then
    echo "Canonical workflow is empty."
    return 1
  fi

  REPOSITORIES="$(
    gh api \
      --paginate \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/repos?type=all&per_page=100" \
      --jq '
        .[]
        | select(.archived == false)
        | [.full_name, .default_branch]
        | @tsv
      '
  )" || return 1

  FAILED_REPOS=""

  while IFS=$'\t' read -r REPO BRANCH; do
    if [ -z "$REPO" ]; then
      continue
    fi

    if [ "$REPO" = "$POLICY_REPO" ]; then
      continue
    fi

    if [ -z "$BRANCH" ] || [ "$BRANCH" = "null" ]; then
      echo "Skipping $REPO: no default branch"
      continue
    fi

    echo "Syncing: $REPO"

    put_encoded_file \
      "$REPO" \
      "$BRANCH" \
      "$WORKFLOW_PATH" \
      "ci: sync Lint PR workflow" \
      "$SOURCE_CONTENT"

    if [ "$?" -ne 0 ]; then
      FAILED_REPOS="$FAILED_REPOS
$REPO"
    fi
  done <<< "$REPOSITORIES"

  if [ -n "$FAILED_REPOS" ]; then
    echo
    echo "Failed repositories:$FAILED_REPOS"
    return 1
  fi
}


configure_ruleset() {
  if [ -n "$RULESET_ID" ]; then
    FINAL_ENFORCEMENT="${ENFORCEMENT:-$ORIGINAL_ENFORCEMENT}"

    RULESET_PAYLOAD="$(
      printf '%s' "$ORIGINAL_RULESET" |
        jq \
          --arg check "$REQUIRED_CHECK" \
          --arg enforcement "$FINAL_ENFORCEMENT" \
          '{
            name: .name,
            target: .target,
            enforcement: $enforcement,
            bypass_actors: (.bypass_actors // []),

            conditions: (
              .conditions
              | .repository_name.exclude = (
                  (
                    (.repository_name.exclude // [])
                    + [".github"]
                  )
                  | unique
                )
            ),

            rules: (
              [
                (.rules // [])[]
                | select(
                    .type != "workflows"
                    and
                    .type != "required_status_checks"
                  )
              ]
              +
              [
                {
                  type: "required_status_checks",
                  parameters: {
                    do_not_enforce_on_create: true,
                    required_status_checks: [
                      {
                        context: $check
                      }
                    ],
                    strict_required_status_checks_policy: false
                  }
                }
              ]
            )
          }'
    )" || return 1

    echo "Configuring required check: $REQUIRED_CHECK"

    printf '%s' "$RULESET_PAYLOAD" |
      gh api \
        --method PUT \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "orgs/$ORG/rulesets/$RULESET_ID" \
        --input - \
        >/dev/null

    return
  fi


  FINAL_ENFORCEMENT="${ENFORCEMENT:-active}"

  RULESET_PAYLOAD="$(
    jq -n \
      --arg name "$RULESET_NAME" \
      --arg check "$REQUIRED_CHECK" \
      --arg enforcement "$FINAL_ENFORCEMENT" \
      '{
        name: $name,
        target: "branch",
        enforcement: $enforcement,

        conditions: {
          repository_name: {
            include: ["~ALL"],
            exclude: [".github"],
            protected: false
          },

          ref_name: {
            include: ["~DEFAULT_BRANCH"],
            exclude: []
          }
        },

        rules: [
          {
            type: "required_status_checks",
            parameters: {
              do_not_enforce_on_create: true,
              required_status_checks: [
                {
                  context: $check
                }
              ],
              strict_required_status_checks_policy: false
            }
          }
        ]
      }'
  )" || return 1

  echo "Creating ruleset..."

  RULESET_ID="$(
    printf '%s' "$RULESET_PAYLOAD" |
      gh api \
        --method POST \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "orgs/$ORG/rulesets" \
        --input - \
        --jq '.id'
  )"
}


cleanup_old_design() {
  delete_file \
    "$POLICY_REPO" \
    "$POLICY_BRANCH" \
    "$REUSABLE_WORKFLOW_PATH" \
    "ci: remove reusable Lint PR workflow"
}


main() {
  command -v gh >/dev/null || {
    echo "gh is required"
    return 1
  }

  command -v jq >/dev/null || {
    echo "jq is required"
    return 1
  }

  command -v base64 >/dev/null || {
    echo "base64 is required"
    return 1
  }

  gh auth status || return 1


  VARIABLE="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/actions/variables/$RUNNER_VAR" \
      2>/dev/null
  )"

  if [ -z "$VARIABLE" ]; then
    echo "Organization variable $RUNNER_VAR was not found."
    return 1
  fi

  VARIABLE_VISIBILITY="$(
    printf '%s' "$VARIABLE" |
      jq -r '.visibility'
  )"

  if [ "$VARIABLE_VISIBILITY" != "all" ]; then
    echo "Organization variable $RUNNER_VAR must be visible to all repositories."
    return 1
  fi


  POLICY_BRANCH="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$POLICY_REPO" \
      --jq '.default_branch'
  )" || return 1


  ensure_canonical_workflow || return 1
  install_sync_script || return 1

  get_ruleset || return 1
  disable_ruleset || return 1


  sync_repositories

  if [ "$?" -ne 0 ]; then
    restore_ruleset
    return 1
  fi


  configure_ruleset

  if [ "$?" -ne 0 ]; then
    echo "Ruleset update failed."
    restore_ruleset
    return 1
  fi


  cleanup_old_design


  echo
  echo "Configured:"
  echo
  echo "  Canonical workflow:"
  echo "    https://github.com/$POLICY_REPO/blob/$POLICY_BRANCH/$WORKFLOW_PATH"
  echo
  echo "  Sync script:"
  echo "    https://github.com/$POLICY_REPO/blob/$POLICY_BRANCH/$SYNC_SCRIPT_PATH"
  echo
  echo "  Managed path:"
  echo "    $WORKFLOW_PATH"
  echo
  echo "  Required check:"
  echo "    $REQUIRED_CHECK"
  echo
  echo "  Ruleset:"
  echo "    https://github.com/organizations/$ORG/settings/rules/$RULESET_ID"
}


main "$@"
