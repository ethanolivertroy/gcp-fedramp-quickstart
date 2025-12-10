output "service_account_email" {
  description = "The email of the Service Account"
  value       = google_service_account.terraform_sa.email
}

output "provider_name" {
  description = "The full resource name of the Workload Identity Provider"
  value       = google_iam_workload_identity_pool_provider.provider.name
}
