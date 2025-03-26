#!/bin/bash
# FedRAMP Quickstart Prerequisites Check
# This script verifies all prerequisites are met before deployment

set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}FedRAMP Quickstart Prerequisites Check${NC}"
echo "This script will verify that all prerequisites are met for deployment"
echo "--------------------------------------------------------------------------------"

# Check software requirements
check_software() {
    echo -e "${YELLOW}Checking required software...${NC}"
    
    # Define required tools and minimum versions
    declare -A REQUIRED_TOOLS=(
        ["Go"]="1.20"
        ["Terraform"]="1.7"
        ["gcloud"]="400.0.0"
        ["git"]="2.25.0"
    )
    
    # Check for Go
    if command -v go >/dev/null 2>&1; then
        GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
        if [[ "$(printf '%s\n' "${REQUIRED_TOOLS["Go"]}" "$GO_VERSION" | sort -V | head -n1)" != "${REQUIRED_TOOLS["Go"]}" ]]; then
            echo -e "${RED}❌ Go version ${REQUIRED_TOOLS["Go"]}+ is required. Found: $GO_VERSION${NC}"
            PREREQ_FAILED=true
        else
            echo -e "${GREEN}✓ Go $GO_VERSION installed${NC}"
        fi
    else
        echo -e "${RED}❌ Go is not installed${NC}"
        PREREQ_FAILED=true
    fi
    
    # Check for Terraform
    if command -v terraform >/dev/null 2>&1; then
        TF_VERSION=$(terraform version -json | jq -r '.terraform_version')
        if [[ "$(printf '%s\n' "${REQUIRED_TOOLS["Terraform"]}" "$TF_VERSION" | sort -V | head -n1)" != "${REQUIRED_TOOLS["Terraform"]}" ]]; then
            echo -e "${RED}❌ Terraform version ${REQUIRED_TOOLS["Terraform"]}+ is required. Found: $TF_VERSION${NC}"
            PREREQ_FAILED=true
        else
            echo -e "${GREEN}✓ Terraform $TF_VERSION installed${NC}"
        fi
    else
        echo -e "${RED}❌ Terraform is not installed${NC}"
        PREREQ_FAILED=true
    fi
    
    # Check for gcloud
    if command -v gcloud >/dev/null 2>&1; then
        GCLOUD_VERSION=$(gcloud version | head -n 1 | awk '{print $4}')
        if [[ "$(printf '%s\n' "${REQUIRED_TOOLS["gcloud"]}" "$GCLOUD_VERSION" | sort -V | head -n1)" != "${REQUIRED_TOOLS["gcloud"]}" ]]; then
            echo -e "${YELLOW}⚠️ gcloud version ${REQUIRED_TOOLS["gcloud"]}+ is recommended. Found: $GCLOUD_VERSION${NC}"
        else
            echo -e "${GREEN}✓ gcloud $GCLOUD_VERSION installed${NC}"
        fi
    else
        echo -e "${RED}❌ gcloud is not installed${NC}"
        PREREQ_FAILED=true
    fi
    
    # Check for git
    if command -v git >/dev/null 2>&1; then
        GIT_VERSION=$(git --version | awk '{print $3}')
        if [[ "$(printf '%s\n' "${REQUIRED_TOOLS["git"]}" "$GIT_VERSION" | sort -V | head -n1)" != "${REQUIRED_TOOLS["git"]}" ]]; then
            echo -e "${YELLOW}⚠️ git version ${REQUIRED_TOOLS["git"]}+ is recommended. Found: $GIT_VERSION${NC}"
        else
            echo -e "${GREEN}✓ git $GIT_VERSION installed${NC}"
        fi
    else
        echo -e "${RED}❌ git is not installed${NC}"
        PREREQ_FAILED=true
    fi
    
    # Check for jq
    if command -v jq >/dev/null 2>&1; then
        JQ_VERSION=$(jq --version | awk -F- '{print $2}')
        echo -e "${GREEN}✓ jq $JQ_VERSION installed${NC}"
    else
        echo -e "${RED}❌ jq is not installed${NC}"
        PREREQ_FAILED=true
    fi
    
    if [[ "$PREREQ_FAILED" == "true" ]]; then
        echo -e "${RED}Software prerequisites check failed. Please install or update the missing tools.${NC}"
    else
        echo -e "${GREEN}All required software is installed.${NC}"
    fi
}

# Check GCP authentication and permissions
check_gcp_auth() {
    echo -e "${YELLOW}Checking GCP authentication and permissions...${NC}"
    
    # Check if logged in
    ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
    if [[ -z "$ACCOUNT" ]]; then
        echo -e "${RED}❌ Not logged in to Google Cloud. Please run 'gcloud auth login'${NC}"
        PREREQ_FAILED=true
    else
        echo -e "${GREEN}✓ Authenticated as $ACCOUNT${NC}"
        
        # Check org admin role
        read -p "Enter your Google Cloud Organization ID: " ORG_ID
        if [[ -n "$ORG_ID" ]]; then
            ORG_ROLES=$(gcloud organizations get-iam-policy $ORG_ID --format=json 2>/dev/null | \
                         jq -r ".bindings[] | select(.members[] | contains(\"$ACCOUNT\")) | .role")
            
            if [[ -n "$ORG_ROLES" ]]; then
                echo -e "${GREEN}✓ User has the following roles at organization level:${NC}"
                echo "$ORG_ROLES" | sed 's/^/    /'
                
                # Check for necessary roles
                if echo "$ORG_ROLES" | grep -q "roles/resourcemanager.organizationAdmin"; then
                    echo -e "${GREEN}✓ User has Organization Admin role${NC}"
                else
                    echo -e "${YELLOW}⚠️ User does not have Organization Admin role which may be required${NC}"
                fi
                
                if echo "$ORG_ROLES" | grep -q "roles/billing.admin"; then
                    echo -e "${GREEN}✓ User has Billing Admin role${NC}"
                else
                    echo -e "${YELLOW}⚠️ User does not have Billing Admin role which may be required${NC}"
                fi
            else
                echo -e "${RED}❌ User does not have any roles at organization level${NC}"
                PREREQ_FAILED=true
            fi
        else
            echo -e "${YELLOW}⚠️ Organization ID not provided. Skipping organization permissions check.${NC}"
        fi
    fi
}

# Check network requirements
check_network() {
    echo -e "${YELLOW}Checking network requirements...${NC}"
    
    # Check internet connectivity
    if ping -c 1 google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Internet connectivity available${NC}"
    else
        echo -e "${RED}❌ Internet connectivity check failed${NC}"
        PREREQ_FAILED=true
    fi
    
    # Check Google API connectivity
    if curl -s https://cloudresourcemanager.googleapis.com >/dev/null; then
        echo -e "${GREEN}✓ Google Cloud API connectivity available${NC}"
    else
        echo -e "${RED}❌ Google Cloud API connectivity check failed${NC}"
        PREREQ_FAILED=true
    fi
    
    # Check GitHub connectivity for Data Protection Toolkit
    if curl -s https://github.com >/dev/null; then
        echo -e "${GREEN}✓ GitHub connectivity available${NC}"
    else
        echo -e "${RED}❌ GitHub connectivity check failed - required for Data Protection Toolkit${NC}"
        PREREQ_FAILED=true
    fi
}

# Verify billing account
verify_billing() {
    echo -e "${YELLOW}Verifying billing account...${NC}"
    
    read -p "Enter your billing account ID: " BILLING_ACCOUNT
    if [[ -n "$BILLING_ACCOUNT" ]]; then
        BILLING_INFO=$(gcloud billing accounts describe $BILLING_ACCOUNT --format=json 2>/dev/null || echo "")
        
        if [[ -n "$BILLING_INFO" ]]; then
            BILLING_NAME=$(echo $BILLING_INFO | jq -r '.name')
            BILLING_OPEN=$(echo $BILLING_INFO | jq -r '.open')
            
            echo -e "${GREEN}✓ Billing account exists: $BILLING_NAME${NC}"
            
            if [[ "$BILLING_OPEN" == "true" ]]; then
                echo -e "${GREEN}✓ Billing account is open and active${NC}"
            else
                echo -e "${RED}❌ Billing account is not open${NC}"
                PREREQ_FAILED=true
            fi
        else
            echo -e "${RED}❌ Unable to access billing account or account does not exist${NC}"
            PREREQ_FAILED=true
        fi
    else
        echo -e "${YELLOW}⚠️ Billing account ID not provided. Skipping billing verification.${NC}"
    fi
}

# Main execution
main() {
    PREREQ_FAILED=false
    
    check_software
    check_gcp_auth
    check_network
    verify_billing
    
    echo "--------------------------------------------------------------------------------"
    if [[ "$PREREQ_FAILED" == "true" ]]; then
        echo -e "${RED}Prerequisites check failed. Please address the issues above before proceeding.${NC}"
        exit 1
    else
        echo -e "${GREEN}All prerequisites checks passed. You're ready to deploy!${NC}"
    fi
}

main "$@"