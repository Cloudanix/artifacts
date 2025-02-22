#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

# Function to update private RDS security group rules
update_private_rds_security_group() {
    local sg_id=$1
    local requester_cidr=$2
    
    log "Updating Private RDS security group $sg_id..."
    
    # Allow MySQL from requester CIDR
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr "$requester_cidr" 2>/dev/null || \
    log "Failed to add MySQL rule to $sg_id - rule may already exist"
        
    # Allow PostgreSQL from requester CIDR
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 5432 \
        --cidr "$requester_cidr" 2>/dev/null || \
    log "Failed to add PostgreSQL rule to $sg_id - rule may already exist"
}

# Main function to process the configuration
process_private_rds_config() {
    local config_file=$1
    
    # Read and parse JSON configuration
    local config
    config=$(cat "$config_file")
    
    # Process each RDS configuration
    echo "$config" | jq -c '.private_rds_configs[]' | while read -r rds_config; do
        local requester_cidr
        local rds_security_groups
        
        requester_cidr=$(echo "$rds_config" | jq -r '.requester_cidr')
        rds_security_groups=$(echo "$rds_config" | jq -r '.rds_security_groups[]')
        
        # Update each security group
        echo "$rds_security_groups" | while read -r sg_id; do
            if [ -n "$sg_id" ]; then
                update_private_rds_security_group "$sg_id" "$requester_cidr"
            fi
        done
        
        # Log the details
        {
            echo "Private RDS Security Group Updates:"
            echo "Requester CIDR: $requester_cidr"
            echo "Security Groups: $(echo "$rds_security_groups" | tr '\n' ' ')"
            echo "----------------------------------------"
        } >> private-rds-onboard-details.txt
    done
}

# Check for config file argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <config-file.json>" >&2
    exit 1
fi

process_private_rds_config "$1"