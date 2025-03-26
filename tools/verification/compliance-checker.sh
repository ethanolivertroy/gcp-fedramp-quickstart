#!/bin/bash
# FedRAMP Quickstart Compliance Checker
# This script checks the deployed infrastructure for FedRAMP compliance

set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}FedRAMP Quickstart Compliance Checker${NC}"
echo "This script checks your deployment against FedRAMP Moderate controls"
echo "--------------------------------------------------------------------------------"

# Array of FedRAMP Moderate Controls to check
declare -A FEDRAMP_CONTROLS=(
    ["AC-2"]="Account Management"
    ["AC-3"]="Access Enforcement"
    ["AC-4"]="Information Flow Enforcement"
    ["AC-5"]="Separation of Duties"
    ["AC-6"]="Least Privilege"
    ["AC-17"]="Remote Access"
    ["AU-2"]="Audit Events"
    ["AU-3"]="Audit Content"
    ["AU-6"]="Audit Review, Analysis, and Reporting"
    ["AU-7"]="Audit Reduction and Report Generation"
    ["AU-9"]="Protection of Audit Information"
    ["CA-7"]="Continuous Monitoring"
    ["CM-6"]="Configuration Settings"
    ["CP-9"]="System Backup"
    ["CP-10"]="System Recovery and Reconstitution"
    ["IA-2"]="Identification and Authentication"
    ["IA-5"]="Authenticator Management"
    ["RA-5"]="Vulnerability Scanning"
    ["SC-7"]="Boundary Protection"
    ["SC-8"]="Transmission Confidentiality and Integrity"
    ["SC-12"]="Cryptographic Key Establishment and Management"
    ["SC-13"]="Cryptographic Protection"
    ["SC-28"]="Protection of Information at Rest"
    ["SI-4"]="Information System Monitoring"
)

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

# Check a specific control
check_control() {
    local control_id=$1
    local control_name=${FEDRAMP_CONTROLS[$control_id]}
    local check_result="NOT_CHECKED"
    local check_details=""
    
    echo -e "${YELLOW}Checking control $control_id: $control_name${NC}"
    
    case $control_id in
        "AC-2") # Account Management
            # Check IAM policies for proper account management
            POLICY=$(gcloud projects get-iam-policy $WORKLOAD_PROJECT_ID --format=json)
            SERVICE_ACCOUNTS=$(gcloud iam service-accounts list --project=$WORKLOAD_PROJECT_ID --format="value(email)")
            
            # Check for group-based access instead of individual accounts
            GROUP_COUNT=$(echo "$POLICY" | jq -r '.bindings[].members[] | select(startswith("group:")) | length' | wc -l)
            USER_COUNT=$(echo "$POLICY" | jq -r '.bindings[].members[] | select(startswith("user:")) | length' | wc -l)
            
            if [[ $GROUP_COUNT -gt 0 && $USER_COUNT -lt 5 ]]; then
                check_result="COMPLIANT"
                check_details="Group-based access control implemented. Limited direct user accounts."
            else
                check_result="ATTENTION_NEEDED"
                check_details="Direct user account assignments might exceed recommended limits."
            fi
            ;;
            
        "AC-3") # Access Enforcement
            # Check for appropriate IAM roles and bindings
            POLICY=$(gcloud projects get-iam-policy $WORKLOAD_PROJECT_ID --format=json)
            PRIMITIVE_ROLES=$(echo "$POLICY" | jq -r '.bindings[] | select(.role=="roles/owner" or .role=="roles/editor" or .role=="roles/viewer") | .role')
            
            if [[ -z "$PRIMITIVE_ROLES" ]]; then
                check_result="COMPLIANT"
                check_details="Using fine-grained IAM roles instead of primitive roles."
            else
                check_result="ATTENTION_NEEDED"
                check_details="Primitive roles (owner, editor, viewer) detected. Should use fine-grained roles."
            fi
            ;;
            
        "AC-4") # Information Flow Enforcement
            # Check for VPC Service Controls and firewall rules
            FIREWALL_RULES=$(gcloud compute firewall-rules list --project=$WORKLOAD_PROJECT_ID --format="json")
            INGRESS_RULES=$(echo "$FIREWALL_RULES" | jq -r '. | length')
            
            if [[ $INGRESS_RULES -gt 0 ]]; then
                check_result="COMPLIANT"
                check_details="Firewall rules implemented for network flow control."
            else
                check_result="ATTENTION_NEEDED"
                check_details="No firewall rules detected. Information flow enforcement may be inadequate."
            fi
            ;;
            
        "AC-6") # Least Privilege
            # Check for overly permissive IAM roles
            POLICY=$(gcloud projects get-iam-policy $WORKLOAD_PROJECT_ID --format=json)
            OWNER_COUNT=$(echo "$POLICY" | jq -r '.bindings[] | select(.role=="roles/owner") | .members | length')
            
            if [[ $OWNER_COUNT -le 3 ]]; then
                check_result="COMPLIANT"
                check_details="Limited number of owner role assignments."
            else
                check_result="ATTENTION_NEEDED"
                check_details="Excessive owner role assignments ($OWNER_COUNT). Review for least privilege."
            fi
            ;;
            
        "AU-2"|"AU-3"|"AU-6"|"AU-7"|"AU-9") # Audit Controls
            # Check for logging configuration
            LOG_SINKS=$(gcloud logging sinks list --project=$WORKLOAD_PROJECT_ID --format="json")
            
            if [[ -n "$LOG_SINKS" && "$LOG_SINKS" != "[]" ]]; then
                LOG_DEST=$(echo "$LOG_SINKS" | jq -r '.[].destination')
                
                if [[ "$LOG_DEST" == *"$LOGGING_PROJECT_ID"* ]]; then
                    check_result="COMPLIANT"
                    check_details="Logs are properly routed to centralized logging project."
                else
                    check_result="ATTENTION_NEEDED"
                    check_details="Logs do not appear to be routed to the designated logging project."
                fi
            else
                check_result="NOT_COMPLIANT"
                check_details="No logging sinks configured in workload project."
            fi
            ;;
            
        "CP-9"|"CP-10") # Backup and Recovery
            # Check Cloud SQL backup configuration
            SQL_INSTANCES=$(gcloud sql instances list --project=$WORKLOAD_PROJECT_ID --format="json")
            
            if [[ -n "$SQL_INSTANCES" && "$SQL_INSTANCES" != "[]" ]]; then
                BACKUP_ENABLED=$(echo "$SQL_INSTANCES" | jq -r '.[].settings.backupConfiguration.enabled')
                
                if [[ "$BACKUP_ENABLED" == "true" ]]; then
                    check_result="COMPLIANT"
                    check_details="Database backups are configured."
                else
                    check_result="NOT_COMPLIANT"
                    check_details="Database backups are not enabled."
                fi
            else
                check_result="NOT_APPLICABLE"
                check_details="No Cloud SQL instances found."
            fi
            ;;
            
        "SC-7") # Boundary Protection
            # Check for private GKE cluster and bastion hosts
            GKE_CLUSTERS=$(gcloud container clusters list --project=$WORKLOAD_PROJECT_ID --format="json")
            
            if [[ -n "$GKE_CLUSTERS" && "$GKE_CLUSTERS" != "[]" ]]; then
                PRIVATE_CHECK=$(echo "$GKE_CLUSTERS" | jq -r '.[].privateClusterConfig != null')
                
                if [[ "$PRIVATE_CHECK" == "true" ]]; then
                    check_result="COMPLIANT"
                    check_details="GKE cluster is configured as private."
                else
                    check_result="NOT_COMPLIANT"
                    check_details="GKE cluster is not configured as private."
                fi
            else
                check_result="NOT_APPLICABLE"
                check_details="No GKE clusters found."
            fi
            ;;
            
        "SC-8"|"SC-13") # Transmission Protection
            # Check for TLS configuration
            LB_RESOURCES=$(gcloud compute ssl-certificates list --project=$WORKLOAD_PROJECT_ID --format="json")
            
            if [[ -n "$LB_RESOURCES" && "$LB_RESOURCES" != "[]" ]]; then
                check_result="COMPLIANT"
                check_details="SSL certificates configured for encrypted transmission."
            else
                check_result="ATTENTION_NEEDED"
                check_details="No SSL certificates detected. Verify encryption in transit."
            fi
            ;;
            
        "SC-12"|"SC-28") # Encryption and Key Management
            # Check for CMEK usage
            KMS_KEYS=$(gcloud kms keys list --project=$WORKLOAD_PROJECT_ID --location=global --format="json" 2>/dev/null || echo "[]")
            
            if [[ "$KMS_KEYS" != "[]" ]]; then
                check_result="COMPLIANT"
                check_details="Customer-managed encryption keys are configured."
            else
                check_result="ATTENTION_NEEDED"
                check_details="No customer-managed encryption keys found."
            fi
            ;;
            
        *)
            check_result="NOT_CHECKED"
            check_details="This control check is not implemented in the script."
            ;;
    esac
    
    echo -e "  Result: ${result_color[$check_result]}$check_result${NC}"
    echo -e "  Details: $check_details"
    
    # Add result to summary
    CONTROL_RESULTS["$control_id"]="$check_result"
    CONTROL_DETAILS["$control_id"]="$check_details"
}

# Generate compliance report
generate_report() {
    local compliant_count=0
    local attention_count=0
    local non_compliant_count=0
    local not_applicable_count=0
    local not_checked_count=0
    
    echo -e "\n${GREEN}FedRAMP Compliance Summary Report${NC}"
    echo "------------------------------------------------"
    
    for control_id in "${!FEDRAMP_CONTROLS[@]}"; do
        result=${CONTROL_RESULTS["$control_id"]}
        
        case $result in
            "COMPLIANT")
                ((compliant_count++))
                ;;
            "ATTENTION_NEEDED")
                ((attention_count++))
                ;;
            "NOT_COMPLIANT")
                ((non_compliant_count++))
                ;;
            "NOT_APPLICABLE")
                ((not_applicable_count++))
                ;;
            *)
                ((not_checked_count++))
                ;;
        esac
    done
    
    total_checked=$((${#FEDRAMP_CONTROLS[@]} - not_checked_count - not_applicable_count))
    if [[ $total_checked -eq 0 ]]; then
        compliance_percent=0
    else
        compliance_percent=$(( (compliant_count * 100) / total_checked ))
    fi
    
    echo -e "Controls Checked: $total_checked of ${#FEDRAMP_CONTROLS[@]}"
    echo -e "${GREEN}Compliant: $compliant_count${NC}"
    echo -e "${YELLOW}Needs Attention: $attention_count${NC}"
    echo -e "${RED}Non-Compliant: $non_compliant_count${NC}"
    echo -e "Not Applicable: $not_applicable_count"
    echo -e "Not Checked: $not_checked_count"
    echo -e "\nOverall Compliance: $compliance_percent%"
    
    echo -e "\nDetailed Control Results:"
    echo "------------------------------------------------"
    
    for control_id in "${!FEDRAMP_CONTROLS[@]}"; do
        control_name=${FEDRAMP_CONTROLS[$control_id]}
        result=${CONTROL_RESULTS["$control_id"]}
        details=${CONTROL_DETAILS["$control_id"]}
        
        echo -e "$control_id: ${FEDRAMP_CONTROLS[$control_id]}"
        echo -e "  Result: ${result_color[$result]}$result${NC}"
        echo -e "  Details: $details"
        echo ""
    done
    
    # Create JSON output file
    cat > fedramp-compliance-report.json << EOF
{
  "report_date": "$(date +'%Y-%m-%d')",
  "report_time": "$(date +'%H:%M:%S')",
  "projects": {
    "workload": "$WORKLOAD_PROJECT_ID",
    "logging": "$LOGGING_PROJECT_ID"
  },
  "summary": {
    "total_controls": ${#FEDRAMP_CONTROLS[@]},
    "compliant": $compliant_count,
    "attention_needed": $attention_count,
    "non_compliant": $non_compliant_count,
    "not_applicable": $not_applicable_count,
    "not_checked": $not_checked_count,
    "compliance_percent": $compliance_percent
  },
  "controls": [
EOF

    first=true
    for control_id in "${!FEDRAMP_CONTROLS[@]}"; do
        if [[ "$first" != "true" ]]; then
            echo "," >> fedramp-compliance-report.json
        fi
        first=false
        
        control_name=${FEDRAMP_CONTROLS[$control_id]}
        result=${CONTROL_RESULTS["$control_id"]}
        details=${CONTROL_DETAILS["$control_id"]}
        
        cat >> fedramp-compliance-report.json << EOF
    {
      "id": "$control_id",
      "name": "$control_name",
      "result": "$result",
      "details": "$details"
    }
EOF
    done

    cat >> fedramp-compliance-report.json << EOF
  ]
}
EOF

    echo -e "${GREEN}Compliance report saved to fedramp-compliance-report.json${NC}"
}

# Main execution
main() {
    # Colors for results
    declare -A result_color=(
        ["COMPLIANT"]="${GREEN}"
        ["ATTENTION_NEEDED"]="${YELLOW}"
        ["NOT_COMPLIANT"]="${RED}"
        ["NOT_APPLICABLE"]="${NC}"
        ["NOT_CHECKED"]="${NC}"
    )
    
    # Arrays to store results
    declare -A CONTROL_RESULTS
    declare -A CONTROL_DETAILS
    
    get_project_info
    
    # Check each FedRAMP control
    for control_id in "${!FEDRAMP_CONTROLS[@]}"; do
        check_control "$control_id"
    done
    
    generate_report
}

main "$@"