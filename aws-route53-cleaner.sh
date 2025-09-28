#!/bin/bash

# Route53 Zone Cleaner Script
# This script pulls all Route53 zones and extracts cluster IDs from zones matching the pattern:
# *.origin-ci-int-aws.dev.rhcloud.com
# 
# Usage:
#   ./route53-cleaner.sh                    - List all active clusters
#   ./route53-cleaner.sh <zone-id>          - Clean up records in specified zone (dry run)
#   ./route53-cleaner.sh <zone-id> --delete - Actually delete orphaned records

set -euo pipefail

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Global variables
ZONE_ID=""
DELETE_MODE=false

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --delete|-d)
                DELETE_MODE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "$ZONE_ID" ]]; then
                    ZONE_ID="$1"
                else
                    echo -e "${RED}Error: Unexpected argument: $1${NC}"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

show_help() {
    echo "Route53 Zone Cleaner Script"
    echo ""
    echo "Usage:"
    echo "  $0                    - List all active clusters"
    echo "  $0 <zone-id>          - Clean up records in specified zone (dry run)"
    echo "  $0 <zone-id> --delete - Actually delete orphaned records"
    echo ""
    echo "Options:"
    echo "  -d, --delete    Actually delete records (default is dry run)"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 Z2GYOLTZHS5VK"
    echo "  $0 Z2GYOLTZHS5VK --delete"
}

# Function to get all active cluster IDs
get_active_clusters() {
    local temp_file=$(mktemp)
    trap "rm -f $temp_file" RETURN
    
    echo -e "${YELLOW}Building list of active clusters...${NC}"
    
    # Get all hosted zones and extract zone names
    aws route53 list-hosted-zones --query 'HostedZones[].Name' --output text | tr '\t' '\n' > "$temp_file"
    
    # Pattern to match: anything.origin-ci-int-aws.dev.rhcloud.com
    local pattern="origin-ci-int-aws.dev.rhcloud.com"
    
    # Array to store cluster IDs
    declare -a cluster_ids=()
    
    # Process each zone
    while IFS= read -r zone; do
        # Remove trailing dot if present
        zone=$(echo "$zone" | sed 's/\.$//')
        
        # Check if zone matches our pattern
        if [[ "$zone" == *"$pattern" ]]; then
            # Extract the cluster ID using regex
            if [[ "$zone" =~ ^([^.]+)\.origin-ci-int-aws\.dev\.rhcloud\.com$ ]]; then
                cluster_ids+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$temp_file"
    
    # Return unique cluster IDs
    printf '%s\n' "${cluster_ids[@]}" | sort -u
}

# Function to clean up zone records
cleanup_zone() {
    local zone_id="$1"
    local -a active_clusters
    
    echo -e "${BLUE}=== Zone Cleanup Mode ===${NC}"
    echo -e "${BLUE}Target Zone: ${zone_id}${NC}"
    
    if [[ "$DELETE_MODE" == "true" ]]; then
        echo -e "${RED}Mode: DELETE (records will be removed!)${NC}"
    else
        echo -e "${YELLOW}Mode: DRY RUN (no records will be deleted)${NC}"
    fi
    echo ""
    
    # Get active clusters
    echo -e "${YELLOW}Step 1: Getting active cluster list...${NC}"
    mapfile -t active_clusters < <(get_active_clusters)
    
    echo -e "${GREEN}Found ${#active_clusters[@]} active clusters:${NC}"
    for cluster in "${active_clusters[@]}"; do
        echo -e "${BLUE}  ✓ ${cluster}${NC}"
    done
    echo ""
    
    # Get zone information
    echo -e "${YELLOW}Step 2: Getting zone information...${NC}"
    local zone_name
    zone_name=$(aws route53 get-hosted-zone --id "$zone_id" --query 'HostedZone.Name' --output text)
    echo -e "${GREEN}Zone Name: ${zone_name}${NC}"
    echo ""
    
    # Get all records in the zone (paginated)
    echo -e "${YELLOW}Step 3: Fetching all records in zone (this may take a while)...${NC}"
    
    local temp_records=$(mktemp)
    local next_token=""
    local total_records=0
    
    trap "rm -f $temp_records" RETURN
    
    # Fetch records in batches
    while true; do
        local cmd="aws route53 list-resource-record-sets --hosted-zone-id $zone_id --output json"
        if [[ -n "$next_token" ]]; then
            cmd+=" --starting-token $next_token"
        fi
        
        local response=$(eval "$cmd")
        
        # Extract records and append to temp file
        echo "$response" | jq -r '.ResourceRecordSets[] | @json' >> "$temp_records"
        
        # Get next token if exists
        next_token=$(echo "$response" | jq -r '.NextToken // empty')
        
        local batch_count=$(echo "$response" | jq '.ResourceRecordSets | length')
        total_records=$((total_records + batch_count))
        echo -e "${BLUE}  Fetched ${batch_count} records (total: ${total_records})${NC}"
        
        if [[ -z "$next_token" ]]; then
            break
        fi
    done
    
    echo -e "${GREEN}Total records fetched: ${total_records}${NC}"
    echo ""
    
    # Analyze records for cleanup
    echo -e "${YELLOW}Step 4: Analyzing records for cleanup...${NC}"
    
    # Temporarily disable strict error handling for this section
    set +e
    
    local records_to_delete=()
    local pattern="\.apps\.([^.]+)\.origin-ci-int-aws\.dev\.rhcloud\.com\.$"
    local analyzed_count=0
    local orphaned_count=0
    local active_count=0
    local processed_count=0
    local skipped_count=0
    local deleted_count=0
    
    # Check if temp_records file exists and is not empty
    if [[ ! -f "$temp_records" ]]; then
        echo -e "${RED}Error: temp_records file not found!${NC}"
        set -e
        return 1
    fi
    
    local total_lines=$(wc -l < "$temp_records")
    echo -e "${BLUE}Processing ${total_lines} records...${NC}"
    
    # Debug: Show first few lines of the temp file
    echo -e "${PURPLE}Debug: First 3 lines of records file:${NC}"
    head -3 "$temp_records"
    echo -e "${PURPLE}Debug: Last 3 lines of records file:${NC}"
    tail -3 "$temp_records"
    echo ""
    
    while IFS= read -r record_json || [[ -n "$record_json" ]]; do
        ((processed_count++))
        
        # Show progress every 100 records
        if (( processed_count % 100 == 0 )); then
            echo -e "${BLUE}  Progress: ${processed_count}/${total_lines} records processed...${NC}"
        fi
        
        # Skip empty lines
        if [[ -z "$record_json" ]]; then
            echo -e "${PURPLE}Debug: Skipping empty line at ${processed_count}${NC}"
            continue
        fi
        
        # Debug: Show problematic records
        if (( processed_count <= 5 )); then
            echo -e "${PURPLE}Debug: Processing record ${processed_count}: ${record_json:0:100}...${NC}"
        fi
        
        # Parse JSON with error handling
        local record_name=""
        local record_type=""
        
        record_name=$(echo "$record_json" | jq -r '.Name' 2>/dev/null)
        local jq_exit_code=$?
        
        if [[ $jq_exit_code -ne 0 ]] || [[ -z "$record_name" ]] || [[ "$record_name" == "null" ]]; then
            echo -e "${YELLOW}Warning: Failed to parse record name from JSON at line ${processed_count}${NC}"
            echo -e "${YELLOW}  Record content: ${record_json:0:200}${NC}"
            ((skipped_count++))
            continue
        fi
        
        record_type=$(echo "$record_json" | jq -r '.Type' 2>/dev/null)
        jq_exit_code=$?
        
        if [[ $jq_exit_code -ne 0 ]] || [[ -z "$record_type" ]] || [[ "$record_type" == "null" ]]; then
            echo -e "${YELLOW}Warning: Failed to parse record type from JSON at line ${processed_count}${NC}"
            echo -e "${YELLOW}  Record content: ${record_json:0:200}${NC}"
            ((skipped_count++))
            continue
        fi
        
        # Skip NS and SOA records for the zone itself
        if [[ "$record_type" == "NS" || "$record_type" == "SOA" ]]; then
            continue
        fi
        
        # Check if record matches the apps pattern
        if [[ "$record_name" =~ $pattern ]]; then
            ((analyzed_count++))
            local cluster_id="${BASH_REMATCH[1]}"
            
            # Only process A and AAAA records for deletion
            if [[ "$record_type" != "A" && "$record_type" != "AAAA" ]]; then
                echo -e "${BLUE}  ℹ️  SKIPPING: ${record_name} (${record_type}) - only A/AAAA records are deleted${NC}"
                continue
            fi
            
            # Check if this cluster is in our active list
            local is_active=false
            for active_cluster in "${active_clusters[@]}"; do
                if [[ "$cluster_id" == "$active_cluster" ]]; then
                    is_active=true
                    break
                fi
            done
            
            if [[ "$is_active" == "false" ]]; then
                ((orphaned_count++))
                echo -e "${RED}  🗑️  ORPHANED (#${orphaned_count}): ${record_name} (${record_type}) (cluster: ${cluster_id})${NC}"
                
                # Delete immediately if in delete mode
                if [[ "$DELETE_MODE" == "true" ]]; then
                    echo -e "${BLUE}    Deleting now...${NC}"
                    
                    # Create batch delete request
                    local batch_file=$(mktemp)
                    cat > "$batch_file" << EOF
{
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet": $record_json
        }
    ]
}
EOF
                    
                    if aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch file://"$batch_file" &>/dev/null; then
                        echo -e "${GREEN}    ✅ Deleted successfully${NC}"
                        ((deleted_count++))
                    else
                        echo -e "${RED}    ❌ Failed to delete${NC}"
                    fi
                    
                    rm -f "$batch_file"
                else
                    # In dry run mode, just collect for summary
                    records_to_delete+=("$record_json")
                fi
            else
                ((active_count++))
                echo -e "${GREEN}  ✓ ACTIVE (#${active_count}): ${record_name} (${record_type}) (cluster: ${cluster_id})${NC}"
            fi
        fi
        
        # Safety check to prevent infinite loops
        if (( processed_count > 20000 )); then
            echo -e "${RED}Warning: Processed more than 20000 records, stopping to prevent runaway${NC}"
            break
        fi
        
    done < "$temp_records"
    
    # Re-enable strict error handling
    set -e
    
    echo ""
    echo -e "${BLUE}Processing complete:${NC}"
    echo -e "${BLUE}  - Total records processed: ${processed_count}${NC}"
    echo -e "${BLUE}  - Records skipped due to errors: ${skipped_count}${NC}"
    echo -e "${BLUE}Analysis complete:${NC}"
    echo -e "${BLUE}  - Total app records analyzed: ${analyzed_count}${NC}"
    echo -e "${GREEN}  - Active records: ${active_count}${NC}"
    echo -e "${RED}  - Orphaned records found: ${orphaned_count}${NC}"
    
    if [[ "$DELETE_MODE" == "true" ]]; then
        echo -e "${GREEN}  - Records deleted: ${deleted_count}${NC}"
        echo -e "${RED}  - Failed deletions: $((orphaned_count - deleted_count))${NC}"
    fi
    
    echo ""
    
    # Summary and deletion
    if [[ "$DELETE_MODE" == "true" ]]; then
        echo -e "${GREEN}=== DELETION COMPLETE ===${NC}"
        if [[ $deleted_count -eq $orphaned_count ]]; then
            echo -e "${GREEN}✅ Successfully deleted all ${deleted_count} orphaned records!${NC}"
        else
            echo -e "${YELLOW}⚠️  Deleted ${deleted_count} out of ${orphaned_count} orphaned records${NC}"
            echo -e "${RED}${$((orphaned_count - deleted_count))} deletions failed${NC}"
        fi
        return 0
    fi
    
    # Dry run summary
    if [[ ${#records_to_delete[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ No orphaned records found. Zone is clean!${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}=== DRY RUN SUMMARY ===${NC}"
    echo -e "${RED}Found ${#records_to_delete[@]} orphaned record(s) that would be deleted:${NC}"
    
    for record_json in "${records_to_delete[@]}"; do
        local name=$(echo "$record_json" | jq -r '.Name')
        local type=$(echo "$record_json" | jq -r '.Type')
        echo -e "${RED}  - ${name} (${type})${NC}"
    done
    
    echo ""
    echo -e "${YELLOW}This is a DRY RUN. No records were deleted.${NC}"
    echo -e "${YELLOW}To actually delete these records, run with --delete flag${NC}"
}

echo -e "${BLUE}=== Route53 Zone Analyzer ===${NC}"

# Parse command line arguments
parse_arguments "$@"

# If zone ID is provided, run cleanup mode
if [[ -n "$ZONE_ID" ]]; then
    cleanup_zone "$ZONE_ID"
    exit 0
fi

# Otherwise, run discovery mode
echo -e "${BLUE}Fetching all Route53 hosted zones...${NC}\n"

# Check if AWS CLI is installed and configured
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed or not in PATH${NC}"
    exit 1
fi

# Test AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured or invalid${NC}"
    exit 1
fi

# Get current AWS account info
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CURRENT_USER=$(aws sts get-caller-identity --query Arn --output text)

echo -e "${GREEN}Connected to AWS Account: ${ACCOUNT_ID}${NC}"
echo -e "${GREEN}Using credentials: ${CURRENT_USER}${NC}\n"

# Fetch all hosted zones
echo -e "${YELLOW}Retrieving all Route53 hosted zones...${NC}"

# Create temporary file for processing
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Get all hosted zones and extract zone names
aws route53 list-hosted-zones --query 'HostedZones[].Name' --output text | tr '\t' '\n' > "$TEMP_FILE"

TOTAL_ZONES=$(wc -l < "$TEMP_FILE")
echo -e "${BLUE}Total zones found: ${TOTAL_ZONES}${NC}\n"

# Get active clusters using the function
echo -e "${YELLOW}Retrieving active clusters from Route53 zones...${NC}"
mapfile -t CLUSTER_IDS < <(get_active_clusters)

echo ""

# Display results
if [ ${#CLUSTER_IDS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No clusters found matching the pattern *.${PATTERN}${NC}"
else
    echo -e "${GREEN}=== CLUSTER SUMMARY ===${NC}"
    echo -e "${GREEN}Found ${#CLUSTER_IDS[@]} cluster(s) currently in use:${NC}\n"
    
    # Sort and display unique cluster IDs
    printf '%s\n' "${CLUSTER_IDS[@]}" | sort -u | while read -r cluster_id; do
        echo -e "${BLUE}✓ ${cluster_id}${NC} - currently in use"
    done
    
    echo ""
    echo -e "${YELLOW}Total unique clusters: $(printf '%s\n' "${CLUSTER_IDS[@]}" | sort -u | wc -l)${NC}"
fi
