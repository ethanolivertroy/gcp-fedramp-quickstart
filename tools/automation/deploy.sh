#!/bin/bash
# FedRAMP Quickstart Deployment Script
# This script automates the deployment of the FedRAMP aligned three-tier architecture

set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}FedRAMP Quickstart Deployment Tool${NC}"
echo "This script will automate the deployment of your FedRAMP-aligned environment"
echo "--------------------------------------------------------------------------------"

# Check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check for required tools
    command -v go >/dev/null 2>&1 || { echo -e "${RED}Error: Go is required but not installed.${NC}" >&2; exit 1; }
    command -v terraform >/dev/null 2>&1 || { echo -e "${RED}Error: Terraform is required but not installed.${NC}" >&2; exit 1; }
    command -v gcloud >/dev/null 2>&1 || { echo -e "${RED}Error: Google Cloud SDK is required but not installed.${NC}" >&2; exit 1; }
    command -v git >/dev/null 2>&1 || { echo -e "${RED}Error: Git is required but not installed.${NC}" >&2; exit 1; }
    
    # Check versions
    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    TF_VERSION=$(terraform version -json | jq -r '.terraform_version')
    
    if [[ "$(printf '%s\n' "1.20" "$GO_VERSION" | sort -V | head -n1)" != "1.20" ]]; then
        echo -e "${RED}Error: Go version 1.20+ is required. Found: $GO_VERSION${NC}"
        exit 1
    fi
    
    if [[ "$(printf '%s\n' "1.7" "$TF_VERSION" | sort -V | head -n1)" != "1.7" ]]; then
        echo -e "${RED}Error: Terraform version 1.7+ is required. Found: $TF_VERSION${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}All prerequisites satisfied.${NC}"
}

# Collect required information
collect_information() {
    echo -e "${YELLOW}Collecting deployment information...${NC}"
    
    # Org information
    read -p "Enter your Google Cloud Organization ID: " ORG_ID
    read -p "Enter your billing account ID: " BILLING_ACCOUNT
    read -p "Enter the parent folder ID (or leave blank for organization-level): " PARENT_FOLDER
    
    # Project information
    read -p "Enter the workload project ID: " WORKLOAD_PROJECT_ID
    read -p "Enter the logging project ID: " LOGGING_PROJECT_ID
    read -p "Enter the region (e.g., us-west1): " REGION
    read -p "Enter the Google Workspace/Cloud Identity group for cloud users: " CLOUD_USERS_GROUP
    
    # Check if projects exist or need to be created
    echo "Checking if projects exist..."
    WORKLOAD_EXISTS=$(gcloud projects describe $WORKLOAD_PROJECT_ID 2>/dev/null && echo "true" || echo "false")
    LOGGING_EXISTS=$(gcloud projects describe $LOGGING_PROJECT_ID 2>/dev/null && echo "true" || echo "false")
    
    if [[ "$WORKLOAD_EXISTS" == "false" ]]; then
        echo "Workload project does not exist. It will be created for you."
        read -p "Enter a display name for the workload project: " WORKLOAD_PROJECT_NAME
    fi
    
    if [[ "$LOGGING_EXISTS" == "false" ]]; then
        echo "Logging project does not exist. It will be created for you."
        read -p "Enter a display name for the logging project: " LOGGING_PROJECT_NAME
    fi
    
    echo -e "${GREEN}Information collected.${NC}"
}

# Validate Google Cloud authentication
validate_authentication() {
    echo -e "${YELLOW}Validating Google Cloud authentication...${NC}"
    
    # Check auth status
    ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
    if [[ -z "$ACCOUNT" ]]; then
        echo -e "${RED}Not logged in to Google Cloud. Initiating login...${NC}"
        gcloud auth login
    else
        echo -e "${GREEN}Already authenticated as $ACCOUNT${NC}"
        read -p "Continue with this account? (y/n): " CONTINUE
        if [[ "$CONTINUE" != "y" ]]; then
            echo "Initiating new login..."
            gcloud auth login
        fi
    fi
    
    # Verify permissions
    echo "Verifying permissions..."
    gcloud organizations get-iam-policy $ORG_ID --format=json > /tmp/org_policy.json 2>/dev/null || {
        echo -e "${RED}Error: Unable to get organization IAM policy. Check permissions or organization ID.${NC}"
        exit 1
    }
    
    echo -e "${GREEN}Authentication validated.${NC}"
}

# Create the required HCL variable files
create_hcl_files() {
    echo -e "${YELLOW}Generating HCL variable files...${NC}"
    
    # Copy the template HCL files
    cp -r /workspaces/gcp-fedramp-quickstart/Infrastructure .
    
    # Update the variables.hcl file
    cat > variables.hcl << EOF
parent_type = "${PARENT_FOLDER:+folder}"
parent_id = "${PARENT_FOLDER:-$ORG_ID}"
billing_account = "$BILLING_ACCOUNT"
terraform_state_storage_bucket = "${WORKLOAD_PROJECT_ID}-tf-state"
EOF
    
    # Update commonVariables.hcl file
    sed -i "s/{{.ttw_project_id}}/$WORKLOAD_PROJECT_ID/g" commonVariables.hcl
    sed -i "s/{{.logging_project_id}}/$LOGGING_PROJECT_ID/g" commonVariables.hcl
    sed -i "s/{{.ttw_region}}/$REGION/g" commonVariables.hcl
    sed -i "s/{{.cloud_users_group}}/$CLOUD_USERS_GROUP/g" commonVariables.hcl
    
    echo -e "${GREEN}HCL files generated.${NC}"
}

# Deploy the FedRAMP infrastructure
deploy_infrastructure() {
    echo -e "${YELLOW}Starting infrastructure deployment...${NC}"
    
    # Clone Data Protection Toolkit if not already present
    if [[ ! -d "healthcare-data-protection-suite" ]]; then
        echo "Cloning Data Protection Toolkit..."
        git clone https://github.com/GoogleCloudPlatform/healthcare-data-protection-suite.git
        cd healthcare-data-protection-suite
        go install ./cmd/tfengine
    fi
    
    # Generate terraform configurations
    echo "Generating Terraform configurations..."
    tfengine --config=variables.hcl
    
    # Create Assured Workloads if they don't exist
    if [[ "$WORKLOAD_EXISTS" == "false" ]]; then
        echo "Creating Assured Workload for FedRAMP Moderate compliance..."
        gcloud assured workloads create --organization=$ORG_ID \
            --display-name="$WORKLOAD_PROJECT_NAME" \
            --location=us-central1 \
            --compliance-regime=FEDRAMP_MODERATE
    fi
    
    if [[ "$LOGGING_EXISTS" == "false" ]]; then
        echo "Creating Assured Workload for FedRAMP Moderate compliance..."
        gcloud assured workloads create --organization=$ORG_ID \
            --display-name="$LOGGING_PROJECT_NAME" \
            --location=us-central1 \
            --compliance-regime=FEDRAMP_MODERATE
    fi
    
    # Deploy terraform configurations
    echo "Deploying Terraform configurations..."
    
    # Check if the generated directories exist
    if [[ ! -d "terraform" ]]; then
        echo -e "${RED}Error: Terraform configurations were not properly generated. Check the tfengine output.${NC}"
        exit 1
    fi
    
    # Deploy each module in the correct order
    for module in network logging devops loadbalancer-mig gke-sql; do
        echo "Deploying $module module..."
        cd "terraform/$module"
        terraform init
        terraform plan -out=plan.tfplan
        terraform apply plan.tfplan
        cd ../..
    done
    
    echo -e "${GREEN}Infrastructure deployment completed.${NC}"
}

# Main execution flow
main() {
    check_prerequisites
    collect_information
    validate_authentication
    create_hcl_files
    deploy_infrastructure
    
    echo -e "${GREEN}FedRAMP-aligned environment deployed successfully!${NC}"
    echo "Next steps:"
    echo "1. Run the verification scripts to validate your deployment"
    echo "2. Document your architecture in your System Security Plan (SSP)"
    echo "3. Configure your application following FedRAMP best practices"
}

main "$@"