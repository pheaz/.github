# /tofu/repositories.tf

resource "github_repository" "active" {
  for_each = local.active_repositories

  name                      = each.key
  squash_merge_commit_title = "PR_TITLE"
  delete_branch_on_merge    = true

  lifecycle {
    prevent_destroy = true

    # Initial adoption owns only the two settings above. Optional provider
    # defaults must not change unrelated features or merge behavior on import.
    ignore_changes = [
      description,
      homepage_url,
      private,
      visibility,
      fork,
      source_owner,
      source_repo,
      security_and_analysis,
      has_issues,
      has_discussions,
      has_projects,
      has_downloads,
      has_wiki,
      is_template,
      allow_merge_commit,
      allow_squash_merge,
      allow_rebase_merge,
      allow_auto_merge,
      allow_forking,
      allow_update_branch,
      squash_merge_commit_message,
      merge_commit_title,
      merge_commit_message,
      web_commit_signoff_required,
      auto_init,
      default_branch,
      license_template,
      gitignore_template,
      archived,
      archive_on_destroy,
      pages,
      topics,
      vulnerability_alerts,
      ignore_vulnerability_alerts_during_read,
      template,
    ]

    postcondition {
      condition     = self.repo_id == each.value.id
      error_message = "Repository identity changed since discovery. Refresh and review the inventory."
    }
  }
}

# Archived repositories remain tracked without attempting unsupported writes.
resource "github_repository" "archived" {
  for_each = local.archived_repositories

  name = each.key

  lifecycle {
    prevent_destroy = true
    ignore_changes  = all

    postcondition {
      condition     = self.repo_id == each.value.id
      error_message = "Archived repository identity changed since discovery. Refresh the inventory."
    }
  }
}
