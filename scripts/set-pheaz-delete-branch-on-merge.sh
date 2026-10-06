#!/usr/bin/env bash
# /scripts/set-pheaz-delete-branch-on-merge.sh

ORG="pheaz"
DESIRED_VALUE="true"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    return 2
  fi
}

main() {
  require_command gh || return 2

  if ! gh auth status >/dev/null 2>&1; then
    printf 'GitHub CLI is not authenticated. Run: gh auth login\n' >&2
    return 2
  fi

  local scanned=0
  local skipped=0
  local unchanged=0
  local updated=0
  local failed=0

  local repo
  local archived
  local current_value
  local update_output

  printf 'Organization: %s\n' "$ORG"
  printf 'Desired delete_branch_on_merge: %s\n\n' "$DESIRED_VALUE"

  while IFS=$'\t' read -r repo archived; do
    [ -n "$repo" ] || continue
    scanned=$((scanned + 1))

    if [ "$archived" = "true" ]; then
      skipped=$((skipped + 1))
      printf '[SKIP] %-40s archived repository\n' "${ORG}/${repo}"
      continue
    fi

    if ! current_value="$(
      gh api --method GET \
        "repos/${ORG}/${repo}" \
        --jq '.delete_branch_on_merge' 2>/dev/null
    )"; then
      failed=$((failed + 1))
      printf '[FAIL] %-40s could not read repository settings\n' \
        "${ORG}/${repo}" >&2
      continue
    fi

    if [ "$current_value" = "$DESIRED_VALUE" ]; then
      unchanged=$((unchanged + 1))
      printf '[SAME] %-40s %s\n' "${ORG}/${repo}" "$DESIRED_VALUE"
      continue
    fi

    if update_output="$(
      gh api --method PATCH \
        "repos/${ORG}/${repo}" \
        -F delete_branch_on_merge=true \
        --silent 2>&1
    )"; then
      updated=$((updated + 1))
      printf '[UPDATE] %-38s %s -> %s\n' \
        "${ORG}/${repo}" "$current_value" "$DESIRED_VALUE"
    else
      failed=$((failed + 1))
      printf '[FAIL] %-40s\n%s\n' \
        "${ORG}/${repo}" "$update_output" >&2
    fi
  done < <(
    gh api --paginate --method GET \
      "orgs/${ORG}/repos" \
      -f per_page=100 \
      -f type=all \
      --jq '.[] | select(.fork == false) | [.name, (.archived | tostring)] | @tsv'
  )

  printf '\nSummary\n'
  printf '  Non-fork repos scanned: %d\n' "$scanned"
  printf '  Archived repos skipped: %d\n' "$skipped"
  printf '  Already configured:     %d\n' "$unchanged"
  printf '  Updated:                %d\n' "$updated"
  printf '  Failed:                 %d\n' "$failed"

  if [ "$failed" -gt 0 ]; then
    return 3
  fi

  return 0
}

main "$@"
