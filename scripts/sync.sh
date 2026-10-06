#!/usr/bin/env bash

ORG="${ORG:-pheaz}"
POLICY_REPO="$ORG/.github"

WORKFLOW_PATH=".github/workflows/lint-pr.yml"
RULESET_NAME="${RULESET_NAME:-ruleset-baseline}"

API_VERSION="2026-03-10"

RULESET_ID=""
RULESET_ORIGINAL_ENFORCEMENT=""
RULESET_CHANGED=0


get_ruleset() {
  local matches
  local match_count

  matches="$(
    gh api \
      --paginate \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets?per_page=100" \
      --jq ".[] | select(.name == \"$RULESET_NAME\") | .id"
  )" || return 1

  if [ -z "$matches" ]; then
    echo "Ruleset not found: $RULESET_NAME"
    return 1
  fi

  match_count="$(
    printf '%s\n' "$matches" |
      awk 'NF { count++ } END { print count + 0 }'
  )"

  if [ "$match_count" -ne 1 ]; then
    echo "Expected exactly one ruleset named: $RULESET_NAME"
    echo "Found: $match_count"
    return 1
  fi

  RULESET_ID="$matches"

  RULESET_ORIGINAL_ENFORCEMENT="$(
    gh api \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets/$RULESET_ID" \
      --jq '.enforcement'
  )" || return 1

  echo "Ruleset:"
  echo "  name: $RULESET_NAME"
  echo "  id: $RULESET_ID"
  echo "  enforcement: $RULESET_ORIGINAL_ENFORCEMENT"
  echo
}


disable_ruleset() {
  local enforcement

  if [ -z "$RULESET_ID" ]; then
    echo "Cannot disable ruleset: no ruleset ID"
    return 1
  fi

  if [ "$RULESET_ORIGINAL_ENFORCEMENT" = "disabled" ]; then
    echo "Ruleset already disabled: $RULESET_NAME"
    return 0
  fi

  echo "Temporarily disabling ruleset: $RULESET_NAME"

  gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "orgs/$ORG/rulesets/$RULESET_ID" \
    -f enforcement=disabled \
    >/dev/null || return 1

  RULESET_CHANGED=1

  enforcement="$(
    gh api \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets/$RULESET_ID" \
      --jq '.enforcement'
  )" || return 1

  if [ "$enforcement" != "disabled" ]; then
    echo "Ruleset was not disabled."
    return 1
  fi

  echo "Ruleset disabled."
  echo
}


restore_ruleset() {
  local enforcement

  if [ "$RULESET_CHANGED" -ne 1 ]; then
    return 0
  fi

  if [ -z "$RULESET_ID" ]; then
    return 0
  fi

  if [ -z "$RULESET_ORIGINAL_ENFORCEMENT" ]; then
    return 0
  fi

  echo
  echo "Restoring ruleset: $RULESET_NAME"
  echo "  enforcement: $RULESET_ORIGINAL_ENFORCEMENT"

  gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "orgs/$ORG/rulesets/$RULESET_ID" \
    -f enforcement="$RULESET_ORIGINAL_ENFORCEMENT" \
    >/dev/null || {
      echo "Failed to restore ruleset: $RULESET_NAME"
      return 1
    }

  enforcement="$(
    gh api \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets/$RULESET_ID" \
      --jq '.enforcement'
  )" || return 1

  if [ "$enforcement" != "$RULESET_ORIGINAL_ENFORCEMENT" ]; then
    echo "Ruleset restoration could not be verified."
    echo "Expected: $RULESET_ORIGINAL_ENFORCEMENT"
    echo "Actual:   $enforcement"
    return 1
  fi

  RULESET_CHANGED=0

  echo "Ruleset restored."
}


cleanup() {
  restore_ruleset
}


sync_repository() {
  local repo="$1"
  local branch="$2"
  local current_sha

  current_sha="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$repo/contents/$WORKFLOW_PATH?ref=$branch" \
      --jq '.sha' \
      2>/dev/null
  )"

  if [ "$current_sha" = "$CANONICAL_SHA" ]; then
    echo "Unchanged: $repo"
    return 0
  fi

  if [ -n "$current_sha" ]; then
    echo "Updating: $repo"

    gh api \
      --method PUT \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$repo/contents/$WORKFLOW_PATH" \
      -f message="ci: sync lint-pr workflow" \
      -f content="$CANONICAL_CONTENT" \
      -f branch="$branch" \
      -f sha="$current_sha" \
      >/dev/null

    return $?
  fi

  echo "Creating: $repo"

  gh api \
    --method PUT \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repo/contents/$WORKFLOW_PATH" \
    -f message="ci: sync lint-pr workflow" \
    -f content="$CANONICAL_CONTENT" \
    -f branch="$branch" \
    >/dev/null
}


main() {
  local failed_repos=()
  local repo
  local branch

  command -v gh >/dev/null || {
    echo "gh is required"
    return 1
  }

  gh auth status || return 1

  POLICY_BRANCH="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$POLICY_REPO" \
      --jq '.default_branch'
  )" || return 1

  CANONICAL_SHA="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$POLICY_REPO/contents/$WORKFLOW_PATH?ref=$POLICY_BRANCH" \
      --jq '.sha'
  )" || {
    echo "Canonical workflow not found:"
    echo "  $POLICY_REPO/$WORKFLOW_PATH"
    return 1
  }

  CANONICAL_CONTENT="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$POLICY_REPO/contents/$WORKFLOW_PATH?ref=$POLICY_BRANCH" \
      --jq '.content' |
      tr -d '\n'
  )" || return 1

  REPOSITORIES="$(
    gh api \
      --paginate \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/repos?type=all&per_page=100" \
      --jq '
        .[]
        | select(.archived == false and .fork == false)
        | [.full_name, .default_branch]
        | @tsv
      '
  )" || return 1

  echo "Canonical:"
  echo "  $POLICY_REPO/$WORKFLOW_PATH"
  echo "  blob $CANONICAL_SHA"
  echo

  get_ruleset || return 1

  trap cleanup EXIT

  disable_ruleset || return 1

  while IFS=$'\t' read -r repo branch; do
    if [ -z "$repo" ]; then
      continue
    fi

    if [ "$repo" = "$POLICY_REPO" ]; then
      continue
    fi

    if [ -z "$branch" ] || [ "$branch" = "null" ]; then
      echo "Skipping: $repo has no default branch"
      continue
    fi

    if ! sync_repository "$repo" "$branch"; then
      failed_repos+=("$repo")
    fi
  done <<< "$REPOSITORIES"

  restore_ruleset || return 1

  trap - EXIT

  if [ "${#failed_repos[@]}" -gt 0 ]; then
    echo
    echo "Failed repositories:"
    printf '%s\n' "${failed_repos[@]}"
    return 1
  fi

  echo
  echo "All managed workflows match:"
  echo "  $CANONICAL_SHA"
}


main "$@"
