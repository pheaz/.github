#!/usr/bin/env bash

ORG="${ORG:-pheaz}"
POLICY_REPO="$ORG/.github"

WORKFLOW_PATH=".github/workflows/lint-pr.yml"
RULESET_NAME="Lint PR"

API_VERSION="2026-03-10"


get_ruleset() {
  RULESET_ID="$(
    gh api \
      --paginate \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets?per_page=100" \
      --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" |
      head -n1
  )"

  if [ -z "$RULESET_ID" ]; then
    RULESET_ENFORCEMENT=""
    return
  fi

  RULESET_ENFORCEMENT="$(
    gh api \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "orgs/$ORG/rulesets/$RULESET_ID" \
      --jq '.enforcement'
  )"
}


disable_ruleset() {
  if [ -z "$RULESET_ID" ]; then
    return
  fi

  if [ "$RULESET_ENFORCEMENT" = "disabled" ]; then
    return
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
    return
  fi

  if [ -z "$RULESET_ENFORCEMENT" ]; then
    return
  fi

  if [ "$RULESET_ENFORCEMENT" = "disabled" ]; then
    return
  fi

  echo "Restoring ruleset $RULESET_ID..."

  gh api \
    --method PUT \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "orgs/$ORG/rulesets/$RULESET_ID" \
    -f enforcement="$RULESET_ENFORCEMENT" \
    >/dev/null
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
    return
  fi

  if [ -n "$current_sha" ]; then
    echo "Updating: $repo"

    gh api \
      --method PUT \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$repo/contents/$WORKFLOW_PATH" \
      -f message="ci: sync Lint PR workflow" \
      -f content="$CANONICAL_CONTENT" \
      -f branch="$branch" \
      -f sha="$current_sha" \
      >/dev/null

    return
  fi

  echo "Creating: $repo"

  gh api \
    --method PUT \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repo/contents/$WORKFLOW_PATH" \
    -f message="ci: sync Lint PR workflow" \
    -f content="$CANONICAL_CONTENT" \
    -f branch="$branch" \
    >/dev/null
}


main() {
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

  echo "Canonical:"
  echo "  $POLICY_REPO/$WORKFLOW_PATH"
  echo "  blob $CANONICAL_SHA"
  echo

  RULESET_ID=""
  RULESET_ENFORCEMENT=""

  get_ruleset || return 1
  disable_ruleset || return 1

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
  )"

  if [ "$?" -ne 0 ]; then
    restore_ruleset
    return 1
  fi

  FAILED_REPOS=""

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

    sync_repository "$repo" "$branch"

    if [ "$?" -ne 0 ]; then
      FAILED_REPOS="$FAILED_REPOS
$repo"
    fi
  done <<< "$REPOSITORIES"

  restore_ruleset

  if [ "$?" -ne 0 ]; then
    echo "Failed to restore ruleset $RULESET_ID"
    return 1
  fi

  if [ -n "$FAILED_REPOS" ]; then
    echo
    echo "Failed repositories:$FAILED_REPOS"
    return 1
  fi

  echo
  echo "All managed workflows match:"
  echo "  $CANONICAL_SHA"
}


main "$@"
