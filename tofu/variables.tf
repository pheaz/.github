# /tofu/variables.tf

variable "organization" {
  description = "The GitHub organization whose repositories are adopted."
  type        = string
  default     = "pheaz"

  validation {
    condition     = var.organization == "pheaz"
    error_message = "This policy configuration manages only the pheaz organization."
  }
}

variable "repositories" {
  description = "Non-fork repositories discovered by .github/scripts/discover.py."
  type = map(object({
    id       = number
    archived = bool
  }))

  # No default: missing inventory must fail instead of proposing removals.
  validation {
    condition = length(var.repositories) > 0 && alltrue([
      for name, repository in var.repositories :
      can(regex("^[A-Za-z0-9_.-]{1,100}$", name)) && repository.id > 0
    ])
    error_message = "A nonempty repository inventory with valid names and IDs is required."
  }
}

locals {
  active_repositories = {
    for name, repository in var.repositories : name => repository
    if !repository.archived
  }
  archived_repositories = {
    for name, repository in var.repositories : name => repository
    if repository.archived
  }
}
