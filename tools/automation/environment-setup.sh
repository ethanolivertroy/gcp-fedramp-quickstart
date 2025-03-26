#!/bin/bash
# FedRAMP Quickstart Environment Setup
# This script automates the creation of required GCP resources before deployment

set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}FedRAMP Quickstart Environment Setup${NC}"
echo "This script will prepare your GCP environment for FedRAMP deployment"
echo "--------------------------------------------------------------------------------"

# Collect organization information
collect_org_info() {
    echo -e "${YELLOW}Collecting organization information...${NC}"
    
    read -p "Enter your Google Cloud Organization ID: " ORG_ID
    read -p "Enter your billing account ID: " BILLING_ACCOUNT
    read -p "Enter the parent folder ID (leave blank for organization-level): " PARENT_FOLDER
    
    # Verify organization ID
    if ! gcloud organizations describe $ORG_ID &>/dev/null; then
        echo -e "${RED}Error: Unable to access organization $ORG_ID. Please check the ID and your permissions.${NC}"
        exit 1
    fi
    
    # Verify billing account
    if ! gcloud billing accounts describe $BILLING_ACCOUNT &>/dev/null; then
        echo -e "${RED}Error: Unable to access billing account $BILLING_ACCOUNT. Please check the ID and your permissions.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Organization information verified.${NC}"
}

# Create folders structure
create_folders() {
    echo -e "${YELLOW}Creating folder structure...${NC}"
    
    read -p "Create a dedicated folder for FedRAMP workloads? (y/n): " CREATE_FOLDER
    
    if [[ "$CREATE_FOLDER" == "y" ]]; then
        read -p "Enter a name for the FedRAMP folder: " FEDRAMP_FOLDER_NAME
        
        # Create the main folder
        FOLDER_ID=$(gcloud resource-manager folders create \
            --organization=$ORG_ID \
            --display-name="$FEDRAMP_FOLDER_NAME" \
            --format="value(name)" | sed 's/folders\///')
        
        echo -e "${GREEN}Created FedRAMP folder with ID: $FOLDER_ID${NC}"
        PARENT_FOLDER=$FOLDER_ID
        
        # Optionally create subfolders
        read -p "Create separate subfolders for workload and logging? (y/n): " CREATE_SUBFOLDERS
        
        if [[ "$CREATE_SUBFOLDERS" == "y" ]]; then
            WORKLOAD_FOLDER_ID=$(gcloud resource-manager folders create \
                --folder=$FOLDER_ID \
                --display-name="FedRAMP-Workloads" \
                --format="value(name)" | sed 's/folders\///')
            
            LOGGING_FOLDER_ID=$(gcloud resource-manager folders create \
                --folder=$FOLDER_ID \
                --display-name="FedRAMP-Logging" \
                --format="value(name)" | sed 's/folders\///')
            
            echo -e "${GREEN}Created workload folder with ID: $WORKLOAD_FOLDER_ID${NC}"
            echo -e "${GREEN}Created logging folder with ID: $LOGGING_FOLDER_ID${NC}"
        fi
    fi
}

# Create or select assured workloads projects
setup_assured_workloads() {
    echo -e "${YELLOW}Setting up Assured Workloads...${NC}"
    
    # Check if Assured Workloads API is enabled on the organization
    if ! gcloud services list --available | grep -q assuredworkloads.googleapis.com; then
        echo -e "${YELLOW}Enabling Assured Workloads API...${NC}"
        gcloud services enable assuredworkloads.googleapis.com
    fi
    
    # Determine the parent resource
    if [[ -n "$PARENT_FOLDER" ]]; then
        PARENT="folders/$PARENT_FOLDER"
    else
        PARENT="organizations/$ORG_ID"
    fi
    
    # Setup workload project
    read -p "Enter a name for the workload project: " WORKLOAD_PROJECT_NAME
    read -p "Enter a project ID for the workload project: " WORKLOAD_PROJECT_ID
    read -p "Select a region for the workload (e.g., us-west1): " WORKLOAD_REGION
    
    echo "Creating Assured Workload for FedRAMP Moderate compliance..."
    gcloud assured workloads create \
        --organization=$ORG_ID \
        --display-name="$WORKLOAD_PROJECT_NAME" \
        --location=$WORKLOAD_REGION \
        --compliance-regime=FEDRAMP_MODERATE
    
    # Setup logging project
    read -p "Enter a name for the logging project: " LOGGING_PROJECT_NAME
    read -p "Enter a project ID for the logging project: " LOGGING_PROJECT_ID
    read -p "Select a region for logging (usually same as workload): " LOGGING_REGION
    
    echo "Creating Assured Workload for FedRAMP Moderate compliance..."
    gcloud assured workloads create \
        --organization=$ORG_ID \
        --display-name="$LOGGING_PROJECT_NAME" \
        --location=$LOGGING_REGION \
        --compliance-regime=FEDRAMP_MODERATE
    
    echo -e "${GREEN}Assured Workloads created successfully.${NC}"
}

# Enable required APIs
enable_apis() {
    echo -e "${YELLOW}Enabling required APIs...${NC}"
    
    # Common APIs needed for both projects
    COMMON_APIS=(
        "cloudresourcemanager.googleapis.com"
        "iam.googleapis.com"
        "compute.googleapis.com"
        "logging.googleapis.com"
        "monitoring.googleapis.com"
        "stackdriver.googleapis.com"
        "serviceusage.googleapis.com"
        "cloudbilling.googleapis.com"
    )
    
    # Workload project specific APIs
    WORKLOAD_APIS=(
        "container.googleapis.com"
        "sql-component.googleapis.com"
        "sqladmin.googleapis.com"
        "cloudkms.googleapis.com"
        "secretmanager.googleapis.com"
        "binaryauthorization.googleapis.com"
        "artifactregistry.googleapis.com"
        "gkehub.googleapis.com"
        "anthosconfigmanagement.googleapis.com"
    )
    
    # Logging project specific APIs
    LOGGING_APIS=(
        "pubsub.googleapis.com"
        "bigquery.googleapis.com"
        "storage-component.googleapis.com"
        "storage-api.googleapis.com"
    )
    
    echo "Enabling APIs for workload project..."
    for api in "${COMMON_APIS[@]}" "${WORKLOAD_APIS[@]}"; do
        echo "Enabling $api..."
        gcloud services enable $api --project=$WORKLOAD_PROJECT_ID
    done
    
    echo "Enabling APIs for logging project..."
    for api in "${COMMON_APIS[@]}" "${LOGGING_APIS[@]}"; do
        echo "Enabling $api..."
        gcloud services enable $api --project=$LOGGING_PROJECT_ID
    done
    
    echo -e "${GREEN}All required APIs enabled.${NC}"
}

# Create service accounts
create_service_accounts() {
    echo -e "${YELLOW}Creating service accounts...${NC}"
    
    # Create terraform service account for deployment
    echo "Creating Terraform service account..."
    gcloud iam service-accounts create terraform-deployer \
        --display-name="Terraform Deployment Service Account" \
        --project=$WORKLOAD_PROJECT_ID
    
    # Grant necessary permissions
    echo "Granting permissions to Terraform service account..."
    
    # Workload project permissions
    gcloud projects add-iam-policy-binding $WORKLOAD_PROJECT_ID \
        --member="serviceAccount:terraform-deployer@$WORKLOAD_PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/owner"
    
    # Logging project permissions
    gcloud projects add-iam-policy-binding $LOGGING_PROJECT_ID \
        --member="serviceAccount:terraform-deployer@$WORKLOAD_PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/owner"
    
    # Organization permissions if needed
    if [[ -n "$PARENT_FOLDER" ]]; then
        gcloud resource-manager folders add-iam-policy-binding $PARENT_FOLDER \
            --member="serviceAccount:terraform-deployer@$WORKLOAD_PROJECT_ID.iam.gserviceaccount.com" \
            --role="roles/resourcemanager.folderViewer"
    else
        gcloud organizations add-iam-policy-binding $ORG_ID \
            --member="serviceAccount:terraform-deployer@$WORKLOAD_PROJECT_ID.iam.gserviceaccount.com" \
            --role="roles/resourcemanager.organizationViewer"
    fi
    
    # Create GKE service account
    echo "Creating GKE service account..."
    gcloud iam service-accounts create gke-node-sa \
        --display-name="GKE Node Service Account" \
        --project=$WORKLOAD_PROJECT_ID
    
    gcloud projects add-iam-policy-binding $WORKLOAD_PROJECT_ID \
        --member="serviceAccount:gke-node-sa@$WORKLOAD_PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/container.nodeServiceAccount"
    
    echo -e "${GREEN}Service accounts created and configured.${NC}"
}

# Create storage bucket for Terraform state
create_state_bucket() {
    echo -e "${YELLOW}Creating Terraform state bucket...${NC}"
    
    STATE_BUCKET="${WORKLOAD_PROJECT_ID}-terraform-state"
    
    gcloud storage buckets create gs://$STATE_BUCKET \
        --project=$WORKLOAD_PROJECT_ID \
        --location=$WORKLOAD_REGION \
        --uniform-bucket-level-access
    
    echo -e "${GREEN}Terraform state bucket created: gs://$STATE_BUCKET${NC}"
    
    # Create a variables file with the generated information
    cat > environment-config.hcl << EOF
# FedRAMP Quickstart Environment Configuration
# Generated by environment-setup.sh

parent_type = "${PARENT_FOLDER:+folder}"
parent_id = "${PARENT_FOLDER:-$ORG_ID}"
billing_account = "$BILLING_ACCOUNT"
terraform_state_storage_bucket = "$STATE_BUCKET"

# Project IDs
ttw_project_id = "$WORKLOAD_PROJECT_ID"
logging_project_id = "$LOGGING_PROJECT_ID"

# Regions
ttw_region = "$WORKLOAD_REGION"
logging_region = "$LOGGING_REGION"

# Service accounts
terraform_service_account = "terraform-deployer@$WORKLOAD_PROJECT_ID.iam.gserviceaccount.com"
gke_service_account = "gke-node-sa@$WORKLOAD_PROJECT_ID.iam.gserviceaccount.com"
EOF
    
    echo -e "${GREEN}Configuration saved to environment-config.hcl${NC}"
}

# Main execution
main() {
    collect_org_info
    create_folders
    setup_assured_workloads
    enable_apis
    create_service_accounts
    create_state_bucket
    
    echo -e "${GREEN}Environment setup complete!${NC}"
    echo "Next steps:"
    echo "1. Review the generated environment-config.hcl file"
    echo "2. Use deploy.sh script to deploy the FedRAMP infrastructure"
}

main "$@"