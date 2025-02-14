#!/bin/bash
set -e
set -u

# Function to handle errors
handle_error() {
    local exit_code=$?
    echo "An error occurred on line $1, exit code $exit_code"
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2  # Send logs to stderr
}

# Function to wait for peering connection to be active
wait_for_peering_active() {
    local peering_id=$1
    local max_attempts=20
    local wait_time=10
    local attempt=1

    log "Waiting for VPC peering connection to become active..."

    while [ $attempt -le $max_attempts ]; do
        # Redirect stderr to avoid mixing with the status output
        status=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$peering_id" \
            --query 'VpcPeeringConnections[0].Status.Code' \
            --output text 2>/dev/null)

        if [ "$status" = "active" ]; then
            log "VPC peering connection is now active"
            return 0
        elif [ "$status" = "failed" ]; then
            log "VPC peering connection failed"
            return 1
        fi
        
        log "Attempt $attempt of $max_attempts, waiting ${wait_time} seconds..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    
    log "Timeout waiting for VPC peering connection"
    return 1
}

create_vpc_peering() {
    local requester_vpc_id=$1
    local accepter_account_id=$2
    local accepter_vpc_id=$3
    local accepter_region=$4
    local peering_name=$5

    log "Creating VPC Peering connection from $requester_vpc_id to $accepter_vpc_id..."
    
    # Redirect stderr to avoid mixing with the peering ID output
    peering_id=$(aws ec2 create-vpc-peering-connection \
        --vpc-id "$requester_vpc_id" \
        --peer-owner-id "$accepter_account_id" \
        --peer-vpc-id "$accepter_vpc_id" \
        --peer-region "$accepter_region" \
        --tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=${peering_name}-peering},{Key=Purpose,Value=database-iam-jit}]" \
        --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
        --output text 2>/dev/null)

    if [ -z "$peering_id" ]; then
        log "Failed to create VPC peering connection. Please check the parameters."
        exit 1
    fi

    log "Created peering connection: $peering_id"
    echo "$peering_id"
}

# Function to get all route table IDs for a VPC
get_route_table_ids() {
    local vpc_id=$1
    
    log "Fetching route table IDs for VPC $vpc_id..."
    aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[*].RouteTableId' \
        --output text 2>/dev/null
}

# Function to update route tables for the requester VPC
update_requester_routes() {
    local vpc_id=$1
    local destination_cidr=$2
    local peering_id=$3
    log "Updating route tables for VPC $vpc_id..."
    local rt_ids=$(get_route_table_ids "$vpc_id")

    for rt_id in $rt_ids; do
        log "Adding route to route table $rt_id..."
        aws ec2 create-route \
            --route-table-id "$rt_id" \
            --destination-cidr-block "$destination_cidr" \
            --vpc-peering-connection-id "$peering_id" 2>/dev/null
    done
}

# Function to update security group rules
update_security_group() {
    local sg_id=$1
    local destination_cidr=$2
    
    log "Updating security group $sg_id..."
    
    # Allow MySQL
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr "$destination_cidr" 2>/dev/null
        
    # Allow PostgreSQL
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 5432 \
        --cidr "$destination_cidr" 2>/dev/null
}

# Main function to process the peering configuration
process_peering_config() {
    local config_file=$1
    
    # Read and parse JSON configuration
    local config=$(cat "$config_file")
    
    # Process each VPC peering configuration
    for peering in $(echo "$config" | jq -c '.vpc_peerings[]'); do
        local requester_vpc_id=$(echo "$peering" | jq -r '.requester_vpc_id')
        local accepter_account_id=$(echo "$peering" | jq -r '.accepter_account_id')
        local accepter_vpc_id=$(echo "$peering" | jq -r '.accepter_vpc_id')
        local accepter_region=$(echo "$peering" | jq -r '.accepter_region')
        local peering_name=$(echo "$peering" | jq -r '.peering_name')
        local accepter_cidr=$(echo "$peering" | jq -r '.accepter_cidr')
        local ecs_security_group_id=$(echo "$peering" | jq -r '.ecs_security_group_id')
        
        # Create peering connection and capture only the ID
        peering_id=$(create_vpc_peering "$requester_vpc_id" "$accepter_account_id" \
            "$accepter_vpc_id" "$accepter_region" "$peering_name")
            
        # Wait for peering connection to be accepted and active
        if ! wait_for_peering_active "$peering_id"; then
            log "Failed to establish peering connection"
            exit 1
        fi
        
        # Update route tables
        update_requester_routes "$requester_vpc_id" "$accepter_cidr" "$peering_id"
        
        # Update security group
        update_security_group "$ecs_security_group_id" "$accepter_cidr"
        
        # Save peering details to file
        {
            echo "Peering Details for $peering_name:"
            echo "Peering ID: $peering_id"
            echo "Requester VPC: $requester_vpc_id"
            echo "Accepter VPC: $accepter_vpc_id"
            echo "Accepter CIDR: $accepter_cidr"
            echo "----------------------------------------"
        } >> peering-details.txt
    done
}

# Check for config file argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <config-file.json>"
    exit 1
fi

process_peering_config "$1"