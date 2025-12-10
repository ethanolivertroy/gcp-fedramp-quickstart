# Google Cloud FedRAMP Quickstart (2025 Edition)

An automated, secure-by-default blueprint for deploying FedRAMP Moderate aligned workloads on Google Cloud.

![Status](https://img.shields.io/badge/Status-Modernized-green)
![Terraform](https://img.shields.io/badge/Terraform-1.5+-purple)
![Security](https://img.shields.io/badge/Security-FedRAMP_Moderate-blue)

## Overview
This repository provides a production-ready, auditable Infrastructure-as-Code (IaC) foundation for building FedRAMP-compliant applications.

**Key Features (2025 Modernization):**
*   **Native Terraform**: Moved from legacy `tfengine` generators to standard [Cloud Foundation Toolkit](https://cloud.google.com/foundation/docs/toolkit) modules.
*   **Zero-Trust Security**:
    *   **Workload Identity Federation**: No long-lived Service Account keys for CI/CD.
    *   **Private GKE**: Control Plane and Nodes are isolated from the public internet.
    *   **Private Cloud SQL**: Database traffic stays within Google's private GCP network.
    *   **Binary Authorization**: Enforces trusted container images.
*   **Confidential Computing**: Uses N2D instances (AMD SEV) by default for data-in-use encryption.
*   **Automated CI/CD**: Includes GitHub Actions for OIDC-authenticated `plan` and `apply`.

---

## Directory Structure

```bash
.
├── .github/workflows/      # Automated CI/CD Pipelines
├── terraform/
│   ├── envs/
│   │   ├── dev/            # Development Environment
│   │   └── prod/           # Production Environment (Placeholder)
│   └── modules/
│       └── github-oidc/    # Identity Federation Setup
├── legacy_HCL/             # Archived legacy templates (Reference only)
└── README.md
```

---

## Quickstart Guide

### 1. Bootstrap Identity (One-time Setup)
To enable the automated pipeline, you must first create the Workload Identity infrastructure manually (or via local Terraform).

1.  **Authenticate Locally**:
    ```bash
    gcloud auth application-default login
    ```
2.  **Configure Dev Environment**:
    Navigate to `terraform/envs/dev` and create a `terraform.tfvars` file:
    ```hcl
    project_id  = "your-gcp-project-id"
    github_repo = "your-org/your-repo"  # e.g. "acme-corp/fedramp-app"
    ```
3.  **Apply Identity Config**:
    ```bash
    cd terraform/envs/dev
    terraform init
    terraform apply -target=module.github_oidc
    ```
4.  **Note Outputs**:
    Copy the `wif_provider_name` and `wif_service_account` from the output.

### 2. Configure GitHub Secrets
Go to your Repository Settings > Secrets > Actions and add:

| Secret Name | Value |
|-------------|-------|
| `GCP_PROJECT_ID` | Your Google Cloud Project ID |
| `TF_STATE_BUCKET` | Name of your GCS bucket for Terraform state |
| `WIF_PROVIDER` | The `wif_provider_name` output from Step 1 |
| `WIF_SERVICE_ACCOUNT` | The `wif_service_account` output from Step 1 |

### 3. Deploy
Simply push to the `dev` branch. The GitHub Action will:
1.  Authenticate via OIDC (Passwordless).
2.  Run `terraform plan`.
3.  Run `terraform apply` (on push).

---

## Architecture Decisions

### Why Native Terraform?
We deprecated the previous `tfengine` tool to improve auditability and developer experience. Native Terraform allows usage of standard tools (`tflint`, `checkov`, VS Code extensions) and removes the "black box" of code generation.

### Security Controls Implemented
*   **Network**:
    *   Default VPC with Private Service Access.
    *   No public IPs on GKE Nodes or SQL instances.
*   **Containers**:
    *   **Artifact Registry** with Immutable Tags.
    *   **GKE Dataplane V2** (eBPF) for deep network visibility.
*   **Database**:
    *   PostgreSQL 15 with SSL enforcement.
    *   FedRAMP-compliant logging flags (`log_connections`, `log_disconnections`).

---

## Modernization History
*   **Dec 2025**: Complete rewrite to remove `tfengine` dependency. Adopted Modular Architecture, OIDC Authentication, and Confidential Computing defaults.

## License
Apache 2.0
