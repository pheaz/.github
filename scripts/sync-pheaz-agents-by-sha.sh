#!/usr/bin/env bash
# /scripts/sync-pheaz-agents-by-sha.sh

ORG="pheaz"
SOURCE_REPO="${ORG}/.github"

SOURCE_PATHS=(
  ".github/AGENTS.md"
  ".github/actions/AGENTS.md"
  ".github/workflows/AGENTS.md"
)

COMMIT_MESSAGE="chore: sync AGENTS.md from ${SOURCE_REPO}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    return 2
  fi
}

main() {
  require_command gh || return 2
  require_command jq || return 2

  if ! gh auth status >/dev/null 2>&1; then
    printf 'GitHub CLI is not authenticated. Run: gh auth login\n' >&2
    return 2
  fi

  local source_branch
  source_branch="$(
    gh api "repos/${SOURCE_REPO}" --jq '.default_branch' 2>/dev/null
  )"

  if [ -z "$source_branch" ]; then
    printf 'Could not determine the default branch for %s\n' "$SOURCE_REPO" >&2
    return 2
  fi

  local source_shas=()
  local source_contents=()
  local path
  local source_json
  local source_sha
  local source_content

  printf 'Source: %s@%s\n' "$SOURCE_REPO" "$source_branch"

  for path in "${SOURCE_PATHS[@]}"; do
    if ! source_json="$(
      gh api --method GET \
        "repos/${SOURCE_REPO}/contents/${path}" \
        -f "ref=${source_branch}" 2>/dev/null
    )"; then
      printf 'Could not read source file: %s\n' "$path" >&2
      return 2
    fi

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

  local scanned=0
  local eligible=0
  local unchanged=0
  local created=0
  local updated=0
  local failed=0

  local repo
  local archived
  local default_branch
  local github_dir_json
  local i
  local dest_json
  local dest_sha
  local src_sha
  local src_content
  local write_output

  while IFS=$'\t' read -r repo archived default_branch; do
    [ -n "$repo" ] || continue
    scanned=$((scanned + 1))

    if ! github_dir_json="$(
      gh api --method GET \
        "repos/${ORG}/${repo}/contents/.github" \
        -f "ref=${default_branch}" 2>/dev/null
    )"; then
      printf '[SKIP] %-40s no .github directory\n' "${ORG}/${repo}"
      continue
    fi

    if ! printf '%s' "$github_dir_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      printf '[SKIP] %-40s .github exists but is not a directory\n' "${ORG}/${repo}"
      continue
    fi

    eligible=$((eligible + 1))
    printf '\n[REPO] %s/%s (%s)\n' "$ORG" "$repo" "$default_branch"

    i=0
    while [ "$i" -lt "${#SOURCE_PATHS[@]}" ]; do
      path="${SOURCE_PATHS[$i]}"
      src_sha="${source_shas[$i]}"
      src_content="${source_contents[$i]}"
      dest_sha=""

      if dest_json="$(
        gh api --method GET \
          "repos/${ORG}/${repo}/contents/${path}" \
          -f "ref=${default_branch}" 2>/dev/null
      )"; then
        dest_sha="$(printf '%s' "$dest_json" | jq -r '.sha // empty')"
      fi

      if [ "$dest_sha" = "$src_sha" ]; then
        unchanged=$((unchanged + 1))
        printf '  [SAME]   %s  %s\n' "$src_sha" "$path"
        i=$((i + 1))
        continue
      fi

      if [ "$archived" = "true" ]; then
        failed=$((failed + 1))
        if [ -n "$dest_sha" ]; then
          printf '  [BLOCK]  %s  archived repo; SHA differs (%s -> %s)\n' \
            "$path" "$dest_sha" "$src_sha" >&2
        else
          printf '  [BLOCK]  %s  archived repo; file is missing\n' "$path" >&2
        fi
        i=$((i + 1))
        continue
      fi

      if [ -n "$dest_sha" ]; then
        if write_output="$(
          gh api --method PUT \
            "repos/${ORG}/${repo}/contents/${path}" \
            -f "message=${COMMIT_MESSAGE}" \
            -f "content=${src_content}" \
            -f "sha=${dest_sha}" \
            -f "branch=${default_branch}" 2>&1
        )"; then
          updated=$((updated + 1))
          printf '  [UPDATE] %s  %s -> %s\n' "$path" "$dest_sha" "$src_sha"
        else
          failed=$((failed + 1))
          printf '  [FAIL]   %s\n%s\n' "$path" "$write_output" >&2
        fi
      else
        if write_output="$(
          gh api --method PUT \
            "repos/${ORG}/${repo}/contents/${path}" \
            -f "message=${COMMIT_MESSAGE}" \
            -f "content=${src_content}" \
            -f "branch=${default_branch}" 2>&1
        )"; then
          created=$((created + 1))
          printf '  [CREATE] %s  %s\n' "$path" "$src_sha"
        else
          failed=$((failed + 1))
          printf '  [FAIL]   %s\n%s\n' "$path" "$write_output" >&2
        fi
      fi

      i=$((i + 1))
    done
  done < <(
    gh api --paginate --method GET \
      "orgs/${ORG}/repos" \
      -f per_page=100 \
      -f type=all \
      --jq '.[] | select(.fork == false) | [.name, (.archived | tostring), .default_branch] | @tsv'
  )

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
}

main "$@"
