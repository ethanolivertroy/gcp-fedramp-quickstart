#!/bin/bash
# FedRAMP Quickstart Security Validator
# This script checks the deployed infrastructure for security compliance

set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}FedRAMP Quickstart Security Validator${NC}"
echo "This script validates the security configuration of your FedRAMP deployment"
echo "--------------------------------------------------------------------------------"

# Get project information
get_project_info() {
    echo -e "${YELLOW}Getting project information...${NC}"
    
    read -p "Enter the workload project ID: " WORKLOAD_PROJECT_ID
    read -p "Enter the logging project ID: " LOGGING_PROJECT_ID
    
    if ! gcloud projects describe $WORKLOAD_PROJECT_ID &>/dev/null; then
        echo -e "${RED}Error: Unable to access workload project $WORKLOAD_PROJECT_ID${NC}"
        exit 1
    fi
    
    if ! gcloud projects describe $LOGGING_PROJECT_ID &>/dev/null; then
        echo -e "${RED}Error: Unable to access logging project $LOGGING_PROJECT_ID${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Project information verified.${NC}"
}

# Validate IAM configuration
validate_iam() {
    echo -e "${YELLOW}Validating IAM configuration...${NC}"
    
    # Check for overly permissive IAM roles
    POLICY=$(gcloud projects get-iam-policy $WORKLOAD_PROJECT_ID --format=json)
    
    # Check for allUsers or allAuthenticatedUsers
    if echo "$POLICY" | jq -r '.bindings[].members[]' | grep -q -E 'allUsers|allAuthenticatedUsers'; then
        echo -e "${RED}❌ Public access detected in workload project IAM policy!${NC}"
        PUBLIC_MEMBERS=$(echo "$POLICY" | jq -r '.bindings[] | select(.members[] | test("allUsers|allAuthenticatedUsers")) | {role: .role, members: .members}')
        echo "$PUBLIC_MEMBERS"
        SECURITY_FAILED=true
    else
        echo -e "${GREEN}✓ No public access detected in workload project${NC}"
    fi
    
    # Check for owner role restrictions
    OWNER_COUNT=$(echo "$POLICY" | jq -r '.bindings[] | select(.role=="roles/owner") | .members | length')
    if [[ $OWNER_COUNT -gt 3 ]]; then
        echo -e "${YELLOW}⚠️ More than 3 owners found in workload project. Review for compliance.${NC}"
        OWNER_MEMBERS=$(echo "$POLICY" | jq -r '.bindings[] | select(.role=="roles/owner") | .members[]')
        echo "$OWNER_MEMBERS" | sed 's/^/    /'
    else
        echo -e "${GREEN}✓ Owner roles properly restricted${NC}"
    fi
    
    # Check service account keys
    SERVICE_ACCOUNTS=$(gcloud iam service-accounts list --project=$WORKLOAD_PROJECT_ID --format="value(email)")
    
    echo "Checking service account keys..."
    for SA in $SERVICE_ACCOUNTS; do
        KEY_COUNT=$(gcloud iam service-accounts keys list --iam-account=$SA --project=$WORKLOAD_PROJECT_ID | grep -v SYSTEM | wc -l)
        if [[ $KEY_COUNT -gt 0 ]]; then
            echo -e "${YELLOW}⚠️ User-managed keys detected for service account $SA${NC}"
            SECURITY_FAILED=true
        else
            echo -e "${GREEN}✓ No user-managed keys for $SA${NC}"
        fi
    done
}

# Validate network security
validate_network() {
    echo -e "${YELLOW}Validating network security...${NC}"
    
    # Check firewall rules
    echo "Checking firewall rules..."
    ALLOW_ALL=$(gcloud compute firewall-rules list --project=$WORKLOAD_PROJECT_ID --filter="(direction=INGRESS) AND (allowed.IPProtocol=all)" --format="value(name)")
    
    if [[ -n "$ALLOW_ALL" ]]; then
        echo -e "${RED}❌ Overly permissive firewall rules detected:${NC}"
        echo "$ALLOW_ALL" | sed 's/^/    /'
        SECURITY_FAILED=true
    else
        echo -e "${GREEN}✓ No overly permissive firewall rules detected${NC}"
    fi
    
    # Check VPC Service Controls
    echo "Checking VPC Service Controls..."
    PERIMETERS=$(gcloud access-context-manager perimeters list --policy=$ACCESS_POLICY --format="value(name)")
    
    if [[ -z "$PERIMETERS" ]]; then
        echo -e "${YELLOW}⚠️ No VPC Service Controls perimeters detected${NC}"
    else
        echo -e "${GREEN}✓ VPC Service Controls configured with perimeters:${NC}"
        echo "$PERIMETERS" | sed 's/^/    /'
    fi
    
    # Check private Google access
    echo "Checking Private Google Access..."
    SUBNETS=$(gcloud compute networks subnets list --project=$WORKLOAD_PROJECT_ID --format="json")
    
    if echo "$SUBNETS" | jq -r '.[].privateIpGoogleAccess' | grep -q "false"; then
        echo -e "${YELLOW}⚠️ Some subnets have Private Google Access disabled${NC}"
        echo "$SUBNETS" | jq -r 'map(select(.privateIpGoogleAccess == false)) | .[].name'
    else
        echo -e "${GREEN}✓ Private Google Access enabled on all subnets${NC}"
    fi
}

# Validate GKE security
validate_gke() {
    echo -e "${YELLOW}Validating GKE security...${NC}"
    
    # Check for GKE clusters
    CLUSTERS=$(gcloud container clusters list --project=$WORKLOAD_PROJECT_ID --format="json")
    
    if [[ -z "$CLUSTERS" || "$CLUSTERS" == "[]" ]]; then
        echo -e "${YELLOW}⚠️ No GKE clusters found in workload project${NC}"
        return
    fi
    
    # Check private cluster configuration
    PRIVATE_CHECK=$(echo "$CLUSTERS" | jq -r '.[].privateClusterConfig != null')
    if [[ "$PRIVATE_CHECK" != "true" ]]; then
        echo -e "${RED}❌ GKE cluster is not private!${NC}"
        SECURITY_FAILED=true
    else
        echo -e "${GREEN}✓ GKE cluster is configured as private${NC}"
    fi
    
    # Check network policy
    NETWORK_POLICY=$(echo "$CLUSTERS" | jq -r '.[].networkPolicy.enabled')
    if [[ "$NETWORK_POLICY" != "true" ]]; then
        echo -e "${YELLOW}⚠️ GKE Network Policy is not enabled${NC}"
    else
        echo -e "${GREEN}✓ GKE Network Policy is enabled${NC}"
    fi
    
    # Check Workload Identity
    WORKLOAD_IDENTITY=$(echo "$CLUSTERS" | jq -r '.[].workloadIdentityConfig != null')
    if [[ "$WORKLOAD_IDENTITY" != "true" ]]; then
        echo -e "${YELLOW}⚠️ GKE Workload Identity is not configured${NC}"
    else
        echo -e "${GREEN}✓ GKE Workload Identity is configured${NC}"
    fi
    
    # Check Binary Authorization
    BINARY_AUTH=$(echo "$CLUSTERS" | jq -r '.[].binaryAuthorization.enabled')
    if [[ "$BINARY_AUTH" != "true" ]]; then
        echo -e "${YELLOW}⚠️ Binary Authorization is not enabled on GKE cluster${NC}"
    else
        echo -e "${GREEN}✓ Binary Authorization is enabled on GKE cluster${NC}"
    fi
    
    # Check node auto-upgrade
    NODE_POOLS=$(echo "$CLUSTERS" | jq -r '.[].nodePools')
    AUTO_UPGRADE=$(echo "$NODE_POOLS" | jq -r '.[].management.autoUpgrade')
    if [[ "$AUTO_UPGRADE" != "true" ]]; then
        echo -e "${YELLOW}⚠️ Node auto-upgrade is not enabled for all node pools${NC}"
    else
        echo -e "${GREEN}✓ Node auto-upgrade is enabled for all node pools${NC}"
    fi
}

# Validate Cloud SQL security
validate_cloud_sql() {
    echo -e "${YELLOW}Validating Cloud SQL security...${NC}"
    
    # List SQL instances
    INSTANCES=$(gcloud sql instances list --project=$WORKLOAD_PROJECT_ID --format="json")
    
    if [[ -z "$INSTANCES" || "$INSTANCES" == "[]" ]]; then
        echo -e "${YELLOW}⚠️ No Cloud SQL instances found in workload project${NC}"
        return
    fi
    
    # Check public IP
    PUBLIC_IP=$(echo "$INSTANCES" | jq -r '.[].ipAddresses[] | select(.type == "PRIMARY").ipAddress')
    if [[ -n "$PUBLIC_IP" ]]; then
        echo -e "${RED}❌ Cloud SQL instance has public IP address: $PUBLIC_IP${NC}"
        SECURITY_FAILED=true
    else
        echo -e "${GREEN}✓ Cloud SQL instance does not have public IP${NC}"
    fi
    
    # Check SSL requirement
    SSL_REQUIRED=$(echo "$INSTANCES" | jq -r '.[].settings.ipConfiguration.requireSsl')
    if [[ "$SSL_REQUIRED" != "true" ]]; then
        echo -e "${YELLOW}⚠️ SSL is not required for Cloud SQL connections${NC}"
    else
        echo -e "${GREEN}✓ SSL is required for Cloud SQL connections${NC}"
    fi
    
    # Check automated backups
    BACKUP_ENABLED=$(echo "$INSTANCES" | jq -r '.[].settings.backupConfiguration.enabled')
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        echo -e "${YELLOW}⚠️ Automated backups are not enabled for Cloud SQL${NC}"
    else
        echo -e "${GREEN}✓ Automated backups are enabled for Cloud SQL${NC}"
    fi
    
    # Check high availability
    HA_ENABLED=$(echo "$INSTANCES" | jq -r '.[].settings.availabilityType == "REGIONAL"')
    if [[ "$HA_ENABLED" != "true" ]]; then
        echo -e "${YELLOW}⚠️ High availability is not enabled for Cloud SQL${NC}"
    else
        echo -e "${GREEN}✓ High availability is enabled for Cloud SQL${NC}"
    fi
}

# Validate logging and monitoring
validate_logging() {
    echo -e "${YELLOW}Validating logging and monitoring...${NC}"
    
    # Check log sinks
    LOG_SINKS=$(gcloud logging sinks list --project=$WORKLOAD_PROJECT_ID --format="json")
    
    if [[ -z "$LOG_SINKS" || "$LOG_SINKS" == "[]" ]]; then
        echo -e "${RED}❌ No logging sinks configured in workload project${NC}"
        SECURITY_FAILED=true
    else
        echo -e "${GREEN}✓ Logging sinks configured:${NC}"
        echo "$LOG_SINKS" | jq -r '.[].destination' | sed 's/^/    /'
    fi
    
    # Check logging for audit events
    AUDIT_LOGS=$(gcloud logging sinks list --project=$WORKLOAD_PROJECT_ID --format="json" | jq -r '.[].filter | select(. | contains("protoPayload.methodName"))')
    
    if [[ -z "$AUDIT_LOGS" ]]; then
        echo -e "${YELLOW}⚠️ No audit logging sinks detected${NC}"
    else
        echo -e "${GREEN}✓ Audit logging configured${NC}"
    fi
    
    # Check log metrics
    LOG_METRICS=$(gcloud logging metrics list --project=$WORKLOAD_PROJECT_ID --format="json")
    
    if [[ -z "$LOG_METRICS" || "$LOG_METRICS" == "[]" ]]; then
        echo -e "${YELLOW}⚠️ No log-based metrics configured${NC}"
    else
        echo -e "${GREEN}✓ Log-based metrics configured${NC}"
    fi
}

# Validate encryption
validate_encryption() {
    echo -e "${YELLOW}Validating encryption configurations...${NC}"
    
    # Check CMEK usage
    KMS_KEYS=$(gcloud kms keys list --project=$WORKLOAD_PROJECT_ID --location=global --keyring=ttw-keyring --format="json" 2>/dev/null || echo "[]")
    
    if [[ "$KMS_KEYS" == "[]" ]]; then
        echo -e "${YELLOW}⚠️ No customer-managed encryption keys found${NC}"
    else
        echo -e "${GREEN}✓ Customer-managed encryption keys configured:${NC}"
        echo "$KMS_KEYS" | jq -r '.[].name' | sed 's/^/    /'
        
        # Check key rotation
        ROTATION_PERIOD=$(echo "$KMS_KEYS" | jq -r '.[].rotationPeriod')
        if [[ -z "$ROTATION_PERIOD" ]]; then
            echo -e "${YELLOW}⚠️ Key rotation not configured${NC}"
        else
            echo -e "${GREEN}✓ Key rotation configured: $ROTATION_PERIOD${NC}"
        fi
    fi
    
    # Check Cloud Storage bucket encryption
    BUCKETS=$(gcloud storage ls --project=$WORKLOAD_PROJECT_ID --json)
    
    if [[ -n "$BUCKETS" ]]; then
        CMEK_BUCKETS=0
        TOTAL_BUCKETS=$(echo "$BUCKETS" | jq -r '. | length')
        
        for BUCKET in $(echo "$BUCKETS" | jq -r '.[].name'); do
            ENCRYPTION=$(gcloud storage buckets describe $BUCKET --format="json" | jq -r '.encryption.defaultKmsKeyName')
            if [[ -n "$ENCRYPTION" && "$ENCRYPTION" != "null" ]]; then
                ((CMEK_BUCKETS++))
            fi
        done
        
        if [[ $CMEK_BUCKETS -eq 0 ]]; then
            echo -e "${YELLOW}⚠️ No Cloud Storage buckets use CMEK encryption${NC}"
        else
            echo -e "${GREEN}✓ $CMEK_BUCKETS of $TOTAL_BUCKETS Cloud Storage buckets use CMEK encryption${NC}"
        fi
    fi
}

# Main execution
main() {
    SECURITY_FAILED=false
    ACCESS_POLICY=""
    
    get_project_info
    validate_iam
    validate_network
    validate_gke
    validate_cloud_sql
    validate_logging
    validate_encryption
    
    echo "--------------------------------------------------------------------------------"
    if [[ "$SECURITY_FAILED" == "true" ]]; then
        echo -e "${RED}Security validation failed. Please address the critical issues above.${NC}"
        exit 1
    else
        echo -e "${GREEN}Security validation passed with no critical issues.${NC}"
        echo "Review any warnings and consider addressing them for full FedRAMP compliance."
    fi
}

main "$@"