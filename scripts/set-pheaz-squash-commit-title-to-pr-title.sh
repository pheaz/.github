#!/usr/bin/env bash
# /scripts/set-pheaz-squash-commit-title-to-pr-title.sh

ORG="pheaz"
DESIRED_TITLE="PR_TITLE"

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
  local unchanged=0
  local updated=0
  local failed=0

  local repo
  local current_title
  local update_output

  printf 'Organization: %s\n' "$ORG"
  printf 'Desired squash commit title: %s\n\n' "$DESIRED_TITLE"

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    scanned=$((scanned + 1))

    if ! current_title="$(
      gh api --method GET \
        "repos/${ORG}/${repo}" \
        --jq '.squash_merge_commit_title // empty' 2>/dev/null
    )"; then
      failed=$((failed + 1))
      printf '[FAIL] %-40s could not read repository settings\n' "${ORG}/${repo}" >&2
      continue
    fi

    if [ "$current_title" = "$DESIRED_TITLE" ]; then
      unchanged=$((unchanged + 1))
      printf '[SAME] %-40s %s\n' "${ORG}/${repo}" "$DESIRED_TITLE"
      continue
    fi

    if update_output="$(
      gh api --method PATCH \
        "repos/${ORG}/${repo}" \
        -f "squash_merge_commit_title=${DESIRED_TITLE}" \
        --silent 2>&1
    )"; then
      updated=$((updated + 1))
      if [ -n "$current_title" ]; then
        printf '[UPDATE] %-38s %s -> %s\n' \
          "${ORG}/${repo}" "$current_title" "$DESIRED_TITLE"
      else
        printf '[UPDATE] %-38s set to %s\n' \
          "${ORG}/${repo}" "$DESIRED_TITLE"
      fi
    else
      failed=$((failed + 1))
      printf '[FAIL] %-40s\n%s\n' "${ORG}/${repo}" "$update_output" >&2
    fi
  done < <(
    gh api --paginate --method GET \
      "orgs/${ORG}/repos" \
      -f per_page=100 \
      -f type=all \
      --jq '.[] | select(.fork == false) | .name'
  )

  printf '\nSummary\n'
  printf '  Non-fork repos scanned: %d\n' "$scanned"
  printf '  Already configured:     %d\n' "$unchanged"
  printf '  Updated:                %d\n' "$updated"
  printf '  Failed:                 %d\n' "$failed"

  if [ "$failed" -gt 0 ]; then
    return 3
  fi
}

main "$@"
