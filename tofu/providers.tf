# /tofu/providers.tf

# Authentication comes from GITHUB_TOKEN, outside configuration and state.
provider "github" {
  owner = var.organization
}
