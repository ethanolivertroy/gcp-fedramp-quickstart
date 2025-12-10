# Terraform Infrastructure

This directory contains the modernized Terraform configuration for the FedRAMP Quickstart (2025 Edition).

## Structure

*   `envs/dev`: Development environment configuration.
*   `modules/`: Shared modules.
    *   `github-oidc`: Vends Workload Identity Federation for CI/CD.

## Setup Guide

### 1. Bootstrap
To get the automated pipeline working, you first need to run Terraform **locally** once to create the Identity infrastructure.

1.  Navigate to `envs/dev`.
2.  Create `terraform.tfvars`:
    ```hcl
    project_id  = "your-project-id"
    github_repo = "your-org/your-repo"
    ```
3.  Authenticate locally: `gcloud auth application-default login`
4.  Run:
    ```bash
    terraform init
    terraform apply
    ```
5.  **Note the Outputs**:
    *   `wif_provider_name`
    *   `wif_service_account`

### 2. Configure GitHub
Go to your GitHub Repository Settings > Secrets and Variables > Actions. Add:
*   `GCP_PROJECT_ID`: Your Project ID
*   `TF_STATE_BUCKET`: Name of a GCS bucket to store state (must create manually first)
*   `WIF_PROVIDER`: The `wif_provider_name` output from above.
*   `WIF_SERVICE_ACCOUNT`: The `wif_service_account` output from above.

### 3. Push Code
Pushing to the `dev` branch will now automatically plan and apply changes.

## Prerequisites
*   Terraform >= 1.5
*   Google Cloud SDK configured
*   A GCS Bucket for Terraform State
