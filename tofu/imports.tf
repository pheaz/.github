# /tofu/imports.tf

# Discovery enumerates existing objects. Missing repositories fail import;
# adoption never falls back to creating replacement repositories.
import {
  for_each = local.active_repositories
  to       = github_repository.active[each.key]
  id       = each.key
}

import {
  for_each = local.archived_repositories
  to       = github_repository.archived[each.key]
  id       = each.key
}
