#!/usr/bin/env bash
# /scripts/delete-pheaz-behind-branches.sh

ORG="pheaz"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    return 2
  fi
}

delete_branch() {
  local repo="$1"
  local default_branch="$2"
  local expected_default_sha="$3"
  local branch="$4"
  local expected_branch_sha="$5"

  local current_default_branch
  local current_default_sha
  local current_branch_sha
  local delete_output

  if ! current_default_branch="$(
    gh api --method GET \
      "repos/${repo}" \
      --jq '.default_branch' 2>/dev/null
  )"; then
    printf '  [FAIL]   %-32s could not re-read repository settings\n' \
      "$branch" >&2
    return 1
  fi

  if [ "$current_default_branch" != "$default_branch" ]; then
    printf '  [CHANGED] %-30s default branch changed; preserving\n' \
      "$branch"
    return 10
  fi

  if ! current_default_sha="$(
    gh api --method GET \
      "repos/${repo}/git/ref/heads/${default_branch}" \
      --jq '.object.sha' 2>/dev/null
  )"; then
    printf '  [FAIL]   %-32s could not re-read default branch ref\n' \
      "$branch" >&2
    return 1
  fi

  if [ "$current_default_sha" != "$expected_default_sha" ]; then
    printf '  [CHANGED] %-30s default branch moved; preserving\n' \
      "$branch"
    return 10
  fi

  if ! current_branch_sha="$(
    gh api --method GET \
      "repos/${repo}/git/ref/heads/${branch}" \
      --jq '.object.sha' 2>/dev/null
  )"; then
    printf '  [CHANGED] %-30s branch no longer readable; preserving\n' \
      "$branch"
    return 10
  fi

  if [ "$current_branch_sha" != "$expected_branch_sha" ]; then
    printf '  [CHANGED] %-30s branch moved during scan; preserving\n' \
      "$branch"
    return 10
  fi

  if delete_output="$(
    gh api --method DELETE \
      "repos/${repo}/git/refs/heads/${branch}" \
      --silent 2>&1
  )"; then
    printf '  [DELETE] %-31s %s\n' "$branch" "$expected_branch_sha"
    return 0
  fi

  printf '  [FAIL]   %-32s\n%s\n' "$branch" "$delete_output" >&2
  return 1
}

scan_repository() {
  local repo="$1"
  local default_branch="$2"

  local default_sha
  local branches

  if ! default_sha="$(
    gh api --method GET \
      "repos/${repo}/git/ref/heads/${default_branch}" \
      --jq '.object.sha' 2>/dev/null
  )"; then
    printf '[FAIL] %-40s could not resolve default branch %s\n' \
      "$repo" "$default_branch" >&2
    return 1
  fi

  if ! branches="$(
    gh api --paginate --method GET \
      "repos/${repo}/branches" \
      -f per_page=100 \
      --jq '.[] | [.name, .commit.sha] | @tsv'
  )"; then
    printf '[FAIL] %-40s could not list branches\n' "$repo" >&2
    return 1
  fi

  printf '\n[REPO] %s\n' "$repo"
  printf '  Default: %s (%s)\n' "$default_branch" "$default_sha"

  local branch
  local branch_sha
  local comparison
  local ahead
  local behind
  local delete_status

  local scanned=0
  local preserved=0
  local changed=0
  local deleted=0
  local failed=0

  while IFS=$'\t' read -r branch branch_sha; do
    [ -n "$branch" ] || continue

    if [ "$branch" = "$default_branch" ]; then
      continue
    fi

    scanned=$((scanned + 1))

    if ! comparison="$(
      gh api --method GET \
        "repos/${repo}/compare/${default_sha}...${branch_sha}" \
        --jq '[.ahead_by, .behind_by] | @tsv' 2>/dev/null
    )"; then
      failed=$((failed + 1))
      printf '  [FAIL]   %-32s comparison failed\n' "$branch" >&2
      continue
    fi

    IFS=$'\t' read -r ahead behind <<< "$comparison"

    if [ "$ahead" -ne 0 ]; then
      preserved=$((preserved + 1))
      printf '  [KEEP]   %-32s ahead=%s behind=%s\n' \
        "$branch" "$ahead" "$behind"
      continue
    fi

    if [ "$behind" -eq 0 ]; then
      preserved=$((preserved + 1))
      printf '  [KEEP]   %-32s identical to default\n' "$branch"
      continue
    fi

    delete_branch \
      "$repo" \
      "$default_branch" \
      "$default_sha" \
      "$branch" \
      "$branch_sha"
    delete_status=$?

    if [ "$delete_status" -eq 0 ]; then
      deleted=$((deleted + 1))
    elif [ "$delete_status" -eq 10 ]; then
      changed=$((changed + 1))
    else
      failed=$((failed + 1))
    fi
  done <<< "$branches"

  printf '  Summary\n'
  printf '    Branches scanned:  %d\n' "$scanned"
  printf '    Preserved:         %d\n' "$preserved"
  printf '    Changed mid-scan:  %d\n' "$changed"
  printf '    Deleted:           %d\n' "$deleted"
  printf '    Failed:            %d\n' "$failed"

  if [ "$failed" -gt 0 ]; then
    return 1
  fi

  return 0
}

main() {
  require_command gh || return 2

  if ! gh auth status >/dev/null 2>&1; then
    printf 'GitHub CLI is not authenticated. Run: gh auth login\n' >&2
    return 2
  fi

  local repositories

  if ! repositories="$(
    gh api --paginate --method GET \
      "orgs/${ORG}/repos" \
      -f per_page=100 \
      -f type=all \
      --jq '
        .[]
        | select(.fork == false)
        | [.full_name, (.archived | tostring), .default_branch]
        | @tsv
      '
  )"; then
    printf 'Could not list repositories for organization: %s\n' \
      "$ORG" >&2
    return 2
  fi

  local scanned=0
  local skipped=0
  local completed=0
  local failed=0

  local repo
  local archived
  local default_branch

  printf 'Organization: %s\n' "$ORG"
  printf 'Policy: delete branches with ahead=0 and behind>0\n'

  while IFS=$'\t' read -r repo archived default_branch; do
    [ -n "$repo" ] || continue
    scanned=$((scanned + 1))

    if [ "$archived" = "true" ]; then
      skipped=$((skipped + 1))
      printf '\n[SKIP] %-40s archived repository\n' "$repo"
      continue
    fi

    if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
      skipped=$((skipped + 1))
      printf '\n[SKIP] %-40s no default branch\n' "$repo"
      continue
    fi

    if scan_repository "$repo" "$default_branch"; then
      completed=$((completed + 1))
    else
      failed=$((failed + 1))
    fi
  done <<< "$repositories"

  printf '\nOrganization summary\n'
  printf '  Non-fork repos scanned: %d\n' "$scanned"
  printf '  Repos skipped:          %d\n' "$skipped"
  printf '  Repos completed:        %d\n' "$completed"
  printf '  Repos with failures:    %d\n' "$failed"

  if [ "$failed" -gt 0 ]; then
    return 3
  fi

  return 0
}

main "$@"
