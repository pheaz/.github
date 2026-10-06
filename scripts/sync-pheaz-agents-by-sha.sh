#!/usr/bin/env bash
# /scripts/sync-pheaz-agents-by-sha.sh

ORG="pheaz"
SOURCE_REPO="$ORG/.github"
RULESET_NAME="ruleset-baseline"
API_VERSION="2026-03-10"
COMMIT_MESSAGE="chore: sync AGENTS.md from $SOURCE_REPO"

SOURCE_PATHS=(
  ".github/AGENTS.md"
  ".github/actions/AGENTS.md"
  ".github/workflows/AGENTS.md"
)

RULESET_ID=""
RULESET_ENFORCEMENT=""
RULESET_CHANGED=0

api() {
  gh api -H "X-GitHub-Api-Version: $API_VERSION" "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    return 2
  }
}

load_ruleset() {
  local ids
  local count

  ids="$(
    api --paginate "orgs/$ORG/rulesets?per_page=100" \
      --jq ".[] | select(.name == \"$RULESET_NAME\") | .id"
  )" || return 2

  count="$(printf '%s\n' "$ids" | awk 'NF { n++ } END { print n + 0 }')"

  if [ "$count" -ne 1 ]; then
    printf 'Expected exactly one ruleset named %s; found %s\n' \
      "$RULESET_NAME" "$count" >&2
    return 2
  fi

  RULESET_ID="$ids"
  RULESET_ENFORCEMENT="$(
    api "orgs/$ORG/rulesets/$RULESET_ID" --jq '.enforcement'
  )" || return 2

  printf 'Ruleset:\n'
  printf '  name: %s\n' "$RULESET_NAME"
  printf '  id: %s\n' "$RULESET_ID"
  printf '  enforcement: %s\n\n' "$RULESET_ENFORCEMENT"
}

disable_ruleset() {
  local actual

  if [ "$RULESET_ENFORCEMENT" = "disabled" ]; then
    printf 'Ruleset already disabled: %s\n\n' "$RULESET_NAME"
    return 0
  fi

  printf 'Temporarily disabling ruleset: %s\n' "$RULESET_NAME"

  api --method PUT "orgs/$ORG/rulesets/$RULESET_ID" \
    -f enforcement=disabled >/dev/null || return 2

  RULESET_CHANGED=1

  actual="$(api "orgs/$ORG/rulesets/$RULESET_ID" --jq '.enforcement')" ||
    return 2

  if [ "$actual" != "disabled" ]; then
    printf 'Ruleset disable verification failed: %s\n' "$actual" >&2
    return 2
  fi

  printf 'Ruleset disabled.\n\n'
}

restore_ruleset() {
  local actual

  if [ "$RULESET_CHANGED" -ne 1 ]; then
    return 0
  fi

  printf '\nRestoring ruleset: %s\n' "$RULESET_NAME"
  printf '  enforcement: %s\n' "$RULESET_ENFORCEMENT"

  api --method PUT "orgs/$ORG/rulesets/$RULESET_ID" \
    -f "enforcement=$RULESET_ENFORCEMENT" >/dev/null || return 4

  actual="$(api "orgs/$ORG/rulesets/$RULESET_ID" --jq '.enforcement')" ||
    return 4

  if [ "$actual" != "$RULESET_ENFORCEMENT" ]; then
    printf 'Ruleset restore verification failed: expected %s, got %s\n' \
      "$RULESET_ENFORCEMENT" "$actual" >&2
    return 4
  fi

  RULESET_CHANGED=0
  printf 'Ruleset restored.\n'
}

cleanup() {
  restore_ruleset
}

write_file() {
  local repo="$1"
  local branch="$2"
  local path="$3"
  local source_content="$4"
  local destination_sha="$5"

  if [ -n "$destination_sha" ]; then
    api --method PUT "repos/$repo/contents/$path" \
      -f "message=$COMMIT_MESSAGE" \
      -f "content=$source_content" \
      -f "sha=$destination_sha" \
      -f "branch=$branch"
    return $?
  fi

  api --method PUT "repos/$repo/contents/$path" \
    -f "message=$COMMIT_MESSAGE" \
    -f "content=$source_content" \
    -f "branch=$branch"
}

main() {
  require_command gh || return 2
  require_command jq || return 2
  require_command awk || return 2

  gh auth status >/dev/null 2>&1 || {
    printf 'GitHub CLI is not authenticated. Run: gh auth login\n' >&2
    return 2
  }

  local source_branch
  source_branch="$(api "repos/$SOURCE_REPO" --jq '.default_branch')" ||
    return 2

  local source_shas=()
  local source_contents=()
  local path
  local source_json
  local source_sha
  local source_content

  printf 'Source: %s@%s\n' "$SOURCE_REPO" "$source_branch"

  for path in "${SOURCE_PATHS[@]}"; do
    source_json="$(
      api --method GET "repos/$SOURCE_REPO/contents/$path" \
        -f "ref=$source_branch"
    )" || return 2

    source_sha="$(printf '%s' "$source_json" | jq -r '.sha // empty')"
    source_content="$(
      printf '%s' "$source_json" |
        jq -r '.content // empty' |
        tr -d '\n'
    )"

    if [ -z "$source_sha" ] || [ -z "$source_content" ]; then
      printf 'Source file has no usable SHA/content: %s\n' "$path" >&2
      return 2
    fi

    source_shas+=("$source_sha")
    source_contents+=("$source_content")
    printf '  %s  %s\n' "$source_sha" "$path"
  done

  local repositories
  repositories="$(
    api --paginate --method GET "orgs/$ORG/repos" \
      -f per_page=100 \
      -f type=all \
      --jq '
        .[]
        | select(.fork == false)
        | [.full_name, (.archived | tostring), .default_branch]
        | @tsv
      '
  )" || return 2

  load_ruleset || return 2
  trap cleanup EXIT
  disable_ruleset || return 2

  local scanned=0
  local eligible=0
  local unchanged=0
  local created=0
  local updated=0
  local failed=0

  local repo
  local archived
  local branch
  local github_dir
  local index
  local destination_json
  local destination_sha
  local output

  while IFS=$'\t' read -r repo archived branch; do
    [ -n "$repo" ] || continue
    scanned=$((scanned + 1))

    if [ -z "$branch" ] || [ "$branch" = "null" ]; then
      printf '[SKIP] %-40s no default branch\n' "$repo"
      continue
    fi

    if ! github_dir="$(
      api --method GET "repos/$repo/contents/.github" -f "ref=$branch" 2>/dev/null
    )"; then
      printf '[SKIP] %-40s no .github directory\n' "$repo"
      continue
    fi

    if ! printf '%s' "$github_dir" | jq -e 'type == "array"' >/dev/null 2>&1; then
      printf '[SKIP] %-40s .github exists but is not a directory\n' "$repo"
      continue
    fi

    eligible=$((eligible + 1))
    printf '\n[REPO] %s (%s)\n' "$repo" "$branch"

    index=0
    while [ "$index" -lt "${#SOURCE_PATHS[@]}" ]; do
      path="${SOURCE_PATHS[$index]}"
      source_sha="${source_shas[$index]}"
      source_content="${source_contents[$index]}"
      destination_sha=""

      if destination_json="$(
        api --method GET "repos/$repo/contents/$path" \
          -f "ref=$branch" 2>/dev/null
      )"; then
        destination_sha="$(
          printf '%s' "$destination_json" | jq -r '.sha // empty'
        )"
      fi

      if [ "$destination_sha" = "$source_sha" ]; then
        unchanged=$((unchanged + 1))
        printf '  [SAME]   %s  %s\n' "$source_sha" "$path"
        index=$((index + 1))
        continue
      fi

      if [ "$archived" = "true" ]; then
        failed=$((failed + 1))
        printf '  [BLOCK]  %s  archived repository\n' "$path" >&2
        index=$((index + 1))
        continue
      fi

      if output="$(
        write_file "$repo" "$branch" "$path" \
          "$source_content" "$destination_sha" 2>&1
      )"; then
        if [ -n "$destination_sha" ]; then
          updated=$((updated + 1))
          printf '  [UPDATE] %s  %s -> %s\n' \
            "$path" "$destination_sha" "$source_sha"
        else
          created=$((created + 1))
          printf '  [CREATE] %s  %s\n' "$path" "$source_sha"
        fi
      else
        failed=$((failed + 1))
        printf '  [FAIL]   %s\n%s\n' "$path" "$output" >&2
      fi

      index=$((index + 1))
    done
  done <<< "$repositories"

  restore_ruleset || return 4
  trap - EXIT

  printf '\nSummary\n'
  printf '  Non-fork repos scanned: %d\n' "$scanned"
  printf '  Repos with .github:     %d\n' "$eligible"
  printf '  Files already matching: %d\n' "$unchanged"
  printf '  Files created:          %d\n' "$created"
  printf '  Files updated:          %d\n' "$updated"
  printf '  Files failed/blocked:   %d\n' "$failed"

  if [ "$failed" -gt 0 ]; then
    return 3
  fi

  return 0
}

main "$@"
