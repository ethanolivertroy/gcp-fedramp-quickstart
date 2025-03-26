#!/bin/bash
# FedRAMP Quickstart Drift Detector
# This script detects configuration drift from the secure baseline

set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}FedRAMP Quickstart Drift Detector${NC}"
echo "This script checks for configuration drift from the secure baseline"
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
    
    # Get terraform state file path
    read -p "Enter the path to your Terraform state file or bucket: " TF_STATE
    
    echo -e "${GREEN}Project information verified.${NC}"
}

# Detect IAM drift
detect_iam_drift() {
    echo -e "${YELLOW}Checking for IAM drift...${NC}"
    
    # Export current IAM policy
    gcloud projects get-iam-policy $WORKLOAD_PROJECT_ID --format=json > current_iam.json
    
    # Run terraform plan to get expected state if terraform is available
    if [[ -n "$TF_STATE" && -d "$TF_STATE" ]]; then
        echo "Comparing with Terraform state..."
        cd "$TF_STATE"
        terraform plan -out=tfplan.binary
        terraform show -json tfplan.binary > tfplan.json
        
        # Parse the plan to extract IAM changes
        IAM_CHANGES=$(jq -r '.resource_changes[] | select(.address | contains("google_project_iam")) | .change.actions[]' tfplan.json)
        
        if [[ -n "$IAM_CHANGES" ]]; then
            echo -e "${RED}❌ IAM drift detected!${NC}"
            echo "The following IAM changes would be applied by Terraform:"
            jq -r '.resource_changes[] | select(.address | contains("google_project_iam")) | {address: .address, actions: .change.actions, before: .change.before, after: .change.after}' tfplan.json
            
            DRIFT_DETECTED=true
        else
            echo -e "${GREEN}✓ No IAM drift detected against Terraform state${NC}"
        fi
        
        # Clean up
        rm -f tfplan.binary tfplan.json
    else
        echo "Terraform state not available, performing basic checks..."
        
        # Check for basic issues manually
        POLICY=$(cat current_iam.json)
        
        # Look for public access
        if echo "$POLICY" | jq -r '.bindings[].members[]' | grep -q -E 'allUsers|allAuthenticatedUsers'; then
            echo -e "${RED}❌ Public access detected in IAM policy!${NC}"
            PUBLIC_MEMBERS=$(echo "$POLICY" | jq -r '.bindings[] | select(.members[] | test("allUsers|allAuthenticatedUsers")) | {role: .role, members: .members}')
            echo "$PUBLIC_MEMBERS"
            
            DRIFT_DETECTED=true
        else
            echo -e "${GREEN}✓ No public access detected in IAM policy${NC}"
        fi
    fi
    
    # Clean up
    rm -f current_iam.json
}

# Detect network drift
detect_network_drift() {
    echo -e "${YELLOW}Checking for network configuration drift...${NC}"
    
    # Export current firewall rules
    gcloud compute firewall-rules list --project=$WORKLOAD_PROJECT_ID --format=json > current_firewalls.json
    
    # Check for overly permissive rules
    ALLOW_ALL=$(jq -r '.[] | select(.allowed[].IPProtocol == "all") | .name' current_firewalls.json)
    
    if [[ -n "$ALLOW_ALL" ]]; then
        echo -e "${RED}❌ Overly permissive firewall rules detected:${NC}"
        echo "$ALLOW_ALL" | sed 's/^/    /'
        DRIFT_DETECTED=true
    else
        echo -e "${GREEN}✓ No overly permissive firewall rules detected${NC}"
    fi
    
    # Check for public SSH/RDP
    PUBLIC_ACCESS=$(jq -r '.[] | select(
        (.allowed[].ports | if . then any(. | contains("22") or . | contains("3389")) else false end) and 
        (.sourceRanges | if . then any(. | contains("0.0.0.0/0")) else false end)
    ) | .name' current_firewalls.json)
    
    if [[ -n "$PUBLIC_ACCESS" ]]; then
        echo -e "${RED}❌ Public SSH/RDP access detected:${NC}"
        echo "$PUBLIC_ACCESS" | sed 's/^/    /'
        DRIFT_DETECTED=true
    else
        echo -e "${GREEN}✓ No public SSH/RDP access detected${NC}"
    fi
    
    # Clean up
    rm -f current_firewalls.json
}

# Detect GKE drift
detect_gke_drift() {
    echo -e "${YELLOW}Checking for GKE configuration drift...${NC}"
    
    # Export current GKE configuration
    CLUSTERS=$(gcloud container clusters list --project=$WORKLOAD_PROJECT_ID --format="json")
    
    if [[ -z "$CLUSTERS" || "$CLUSTERS" == "[]" ]]; then
        echo -e "${YELLOW}⚠️ No GKE clusters found in workload project${NC}"
        return
    fi
    
    echo "$CLUSTERS" > current_gke.json
    
    # Check for critical security features
    CRITICAL_FEATURES=(
        ".privateClusterConfig == null:GKE cluster is not private!"
        ".masterAuthorizedNetworksConfig == null:Master authorized networks not configured"
        ".networkPolicy.enabled != true:Network policy is not enabled"
        ".binaryAuthorization.enabled != true:Binary Authorization is not enabled"
    )
    
    for feature in "${CRITICAL_FEATURES[@]}"; do
        CONDITION=$(echo "$feature" | cut -d':' -f1)
        MESSAGE=$(echo "$feature" | cut -d':' -f2)
        
        if jq -r ".[0] | $CONDITION" current_gke.json | grep -q "true"; then
            echo -e "${RED}❌ $MESSAGE${NC}"
            DRIFT_DETECTED=true
        fi
    done
    
    # Check for node auto-upgrade
    NODE_AUTO_UPGRADE=$(jq -r '.[0].nodePools[].management.autoUpgrade' current_gke.json | grep -q "false" && echo "false" || echo "true")
    
    if [[ "$NODE_AUTO_UPGRADE" == "false" ]]; then
        echo -e "${RED}❌ Node auto-upgrade is disabled on some node pools${NC}"
        DRIFT_DETECTED=true
    else
        echo -e "${GREEN}✓ Node auto-upgrade is enabled on all node pools${NC}"
    fi
    
    # Check for workload identity
    if jq -r '.[0].workloadIdentityConfig' current_gke.json | grep -q "null"; then
        echo -e "${RED}❌ Workload Identity is not configured${NC}"
        DRIFT_DETECTED=true
    else
        echo -e "${GREEN}✓ Workload Identity is configured${NC}"
    fi
    
    # Clean up
    rm -f current_gke.json
}

# Detect Cloud SQL drift
detect_cloud_sql_drift() {
    echo -e "${YELLOW}Checking for Cloud SQL configuration drift...${NC}"
    
    # Export current Cloud SQL configuration
    INSTANCES=$(gcloud sql instances list --project=$WORKLOAD_PROJECT_ID --format="json")
    
    if [[ -z "$INSTANCES" || "$INSTANCES" == "[]" ]]; then
        echo -e "${YELLOW}⚠️ No Cloud SQL instances found in workload project${NC}"
        return
    fi
    
    echo "$INSTANCES" > current_sql.json
    
    # Check for critical security features
    CRITICAL_FEATURES=(
        ".ipAddresses[] | select(.type == \"PRIMARY\") | .ipAddress != null:Instance has public IP!"
        ".settings.ipConfiguration.requireSsl != true:SSL is not required for connections"
        ".settings.backupConfiguration.enabled != true:Automated backups are not enabled"
    )
    
    for feature in "${CRITICAL_FEATURES[@]}"; do
        CONDITION=$(echo "$feature" | cut -d':' -f1)
        MESSAGE=$(echo "$feature" | cut -d':' -f2)
        
        if jq -r ".[0] | $CONDITION" current_sql.json | grep -q "true"; then
            echo -e "${RED}❌ $MESSAGE${NC}"
            DRIFT_DETECTED=true
        fi
    done
    
    # Check for high availability
    if jq -r '.[0].settings.availabilityType != "REGIONAL"' current_sql.json | grep -q "true"; then
        echo -e "${YELLOW}⚠️ High availability is not enabled${NC}"
    else
        echo -e "${GREEN}✓ High availability is enabled${NC}"
    fi
    
    # Clean up
    rm -f current_sql.json
}

# Detect logging drift
detect_logging_drift() {
    echo -e "${YELLOW}Checking for logging configuration drift...${NC}"
    
    # Export current logging configuration
    gcloud logging sinks list --project=$WORKLOAD_PROJECT_ID --format="json" > current_sinks.json
    
    # Check if any sinks exist
    if [[ $(jq -r '. | length' current_sinks.json) -eq 0 ]]; then
        echo -e "${RED}❌ No logging sinks configured!${NC}"
        DRIFT_DETECTED=true
    else
        echo -e "${GREEN}✓ Logging sinks configured${NC}"
        
        # Check if sinks target the logging project
        LOGGING_SINKS=$(jq -r ".[].destination | select(. | contains(\"$LOGGING_PROJECT_ID\"))" current_sinks.json)
        
        if [[ -z "$LOGGING_SINKS" ]]; then
            echo -e "${RED}❌ No sinks targeting the logging project!${NC}"
            DRIFT_DETECTED=true
        else
            echo -e "${GREEN}✓ Logs are being sent to the logging project${NC}"
        fi
    fi
    
    # Clean up
    rm -f current_sinks.json
}

# Detect API drift
detect_api_drift() {
    echo -e "${YELLOW}Checking for API enablement drift...${NC}"
    
    # List of required APIs for FedRAMP compliance
    REQUIRED_APIS=(
        "cloudkms.googleapis.com"
        "container.googleapis.com"
        "logging.googleapis.com"
        "monitoring.googleapis.com"
        "compute.googleapis.com"
        "sql-component.googleapis.com"
        "sqladmin.googleapis.com"
        "stackdriver.googleapis.com"
        "storage-component.googleapis.com"
        "binaryauthorization.googleapis.com"
    )
    
    # Get enabled APIs
    gcloud services list --project=$WORKLOAD_PROJECT_ID --format="value(config.name)" > enabled_apis.txt
    
    # Check each required API
    for api in "${REQUIRED_APIS[@]}"; do
        if ! grep -q "$api" enabled_apis.txt; then
            echo -e "${RED}❌ Required API not enabled: $api${NC}"
            DRIFT_DETECTED=true
        fi
    done
    
    if [[ "$DRIFT_DETECTED" != "true" ]]; then
        echo -e "${GREEN}✓ All required APIs are enabled${NC}"
    fi
    
    # Clean up
    rm -f enabled_apis.txt
}

# Generate drift report
generate_report() {
    echo -e "\n${GREEN}Configuration Drift Summary Report${NC}"
    echo "------------------------------------------------"
    
    if [[ "$DRIFT_DETECTED" == "true" ]]; then
        echo -e "${RED}⚠️ Configuration drift detected!${NC}"
        echo "Your environment has drifted from the secure FedRAMP baseline."
        echo "Review the details above and take corrective action."
        
        if [[ -n "$TF_STATE" ]]; then
            echo -e "\nRecommended action: Run 'terraform apply' to realign with the secure baseline"
        else
            echo -e "\nRecommended action: Run the deployment scripts to realign with the secure baseline"
        fi
    else
        echo -e "${GREEN}✓ No configuration drift detected${NC}"
        echo "Your environment remains aligned with the secure FedRAMP baseline."
    fi
    
    # Create a timestamp for the report
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    
    # Create a report file
    cat > drift-report-$TIMESTAMP.txt << EOF
FedRAMP Quickstart Drift Detection Report
Generated: $(date)

Workload Project: $WORKLOAD_PROJECT_ID
Logging Project: $LOGGING_PROJECT_ID

Overall Result: $(if [[ "$DRIFT_DETECTED" == "true" ]]; then echo "DRIFT DETECTED"; else echo "NO DRIFT DETECTED"; fi)

This report provides a point-in-time assessment of configuration drift
from the FedRAMP security baseline. For detailed findings, refer to
the script output above.

To remediate drift:
1. Run Terraform with the original configuration
2. Review manual changes that may have been applied
3. Update the baseline if the changes were approved through change management

For questions or assistance, contact your security team.
EOF
    
    echo -e "\nReport saved to: drift-report-$TIMESTAMP.txt"
}

# Main execution
main() {
    DRIFT_DETECTED=false
    
    get_project_info
    detect_iam_drift
    detect_network_drift
    detect_gke_drift
    detect_cloud_sql_drift
    detect_logging_drift
    detect_api_drift
    generate_report
}

main "$@"