variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "github_repo" {
  description = "The GitHub repository in 'org/repo' format"
  type        = string
}

variable "pool_id" {
  description = "ID for the Workload Identity Pool"
  type        = string
  default     = "github-actions-pool"
}

variable "provider_id" {
  description = "ID for the Workload Identity Provider"
  type        = string
  default     = "github-actions-provider"
}

variable "sa_name" {
  description = "Name of the Service Account for Terraform"
  type        = string
  default     = "terraform-ci"
}
