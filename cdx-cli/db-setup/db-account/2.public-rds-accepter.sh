#!/bin/bash
set -e
set -u

# Function to handle errors
handle_error() {
    local exit_code=$?
    echo "An error occurred on line $1, exit code $exit_code" >&2
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

# Function to get all route table IDs for a VPC
get_route_table_ids() {
    local accepter_vpc_id=$1
    
    log "Fetching route table IDs for VPC $accepter_vpc_id..."
    
    # Store the full response for debugging
    local full_response
    full_response=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$accepter_vpc_id" \
        --output json 2>&1)
    
    # Log the full response for debugging
    log "Full AWS response: $full_response"
    
    # Try to get the route table IDs
    local route_table_ids
    route_table_ids=$(echo "$full_response" | \
        jq -r '.RouteTables[].RouteTableId' 2>/dev/null || echo "")
    
    # Log the extracted IDs
    log "Extracted route table IDs: $route_table_ids"
    
    if [ -z "$route_table_ids" ]; then
        log "No route tables found in the response"
        return 1
    fi
    
    echo "$route_table_ids"
}

# Function to wait for peering connection to be active
wait_for_peering_active() {
    local requester_peering_id=$1
    local max_attempts=20
    local wait_time=30
    local attempt=1

    log "Waiting for VPC peering connection $requester_peering_id to become active..."
    while [ $attempt -le $max_attempts ]; do
        status=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$requester_peering_id" \
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

# Function to accept VPC peering request
accept_vpc_peering() {
    local requester_peering_id=$1
    
    log "Accepting VPC peering connection $requester_peering_id..."
    aws ec2 accept-vpc-peering-connection \
        --vpc-peering-connection-id "$requester_peering_id" 2>/dev/null || {
        log "Failed to accept peering connection - it may be in an invalid state"
        return 1
    }
}

# Function to update route tables
update_accepter_routes() {
    local accepter_vpc_id=$1
    local destination_cidr=$2
    local requester_peering_id=$3
    
    log "Updating route tables for VPC $accepter_vpc_id..."
    local rt_ids
    rt_ids=$(get_route_table_ids "$accepter_vpc_id")
    
    if [ -z "$rt_ids" ]; then
        log "No route tables found for VPC $accepter_vpc_id"
        return 1
    fi
    
    echo "$rt_ids" | while IFS= read -r rt_id; do
        if [ -n "$rt_id" ]; then
            log "Adding route to route table $rt_id..."
            aws ec2 create-route \
                --route-table-id "$rt_id" \
                --destination-cidr-block "$destination_cidr" \
                --vpc-peering-connection-id "$requester_peering_id" 2>/dev/null || \
            log "Failed to add route to $rt_id - route may already exist"
        fi
    done
}

# Function to update RDS security group rules
update_rds_security_group() {
    local sg_id=$1
    local requester_cidr=$2
    local requester_nat_gateway_ip=$3
    
    log "Updating RDS security group $sg_id..."
    
    # Allow MySQL from requester CIDR and NAT Gateway IP
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr "$requester_cidr" 2>/dev/null || \
    log "Failed to add MySQL CIDR rule to $sg_id - rule may already exist"
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr "${requester_nat_gateway_ip}/32" 2>/dev/null || \
    log "Failed to add MySQL NAT Gateway IP rule to $sg_id - rule may already exist"
        
    # Allow PostgreSQL from requester CIDR and NAT Gateway IP
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 5432 \
        --cidr "$requester_cidr" 2>/dev/null || \
    log "Failed to add PostgreSQL CIDR rule to $sg_id - rule may already exist"
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 5432 \
        --cidr "${requester_nat_gateway_ip}/32" 2>/dev/null || \
    log "Failed to add PostgreSQL NAT Gateway IP rule to $sg_id - rule may already exist"
}

# Main function to process the accepter configuration
process_accepter_config() {
    local config_file=$1
    
    # Read and parse JSON configuration
    local config
    config=$(cat "$config_file")
    
    # Process each VPC peering configuration
    echo "$config" | jq -c '.vpc_peerings[]' | while read -r peering; do
        local requester_peering_id
        local accepter_vpc_id
        local requester_cidr
        local requester_nat_gateway_ip
        local rds_security_groups
        
        requester_peering_id=$(echo "$peering" | jq -r '.requester_peering_id')
        accepter_vpc_id=$(echo "$peering" | jq -r '.accepter_vpc_id')
        requester_cidr=$(echo "$peering" | jq -r '.requester_cidr')
        requester_nat_gateway_ip=$(echo "$peering" | jq -r '.requester_nat_gateway_ip')
        rds_security_groups=$(echo "$peering" | jq -r '.rds_security_groups[]')
        
        # Accept the peering connection
        if ! accept_vpc_peering "$requester_peering_id"; then
            log "Failed to accept peering connection $requester_peering_id"
            continue
        fi
        
        # Wait for peering connection to be active
        if ! wait_for_peering_active "$requester_peering_id"; then
            log "Peering connection $requester_peering_id did not become active"
            continue
        fi
        
        # Update route tables
        update_accepter_routes "$accepter_vpc_id" "$requester_cidr" "$requester_peering_id"
        
        # Update RDS security groups from config
        echo "$rds_security_groups" | while read -r sg_id; do
            if [ -n "$sg_id" ]; then
                update_rds_security_group "$sg_id" "$requester_cidr" "$requester_nat_gateway_ip"
            fi
        done
        
        # Save acceptance details to file
        {
            echo "Accepted Peering Details:"
            echo "Peering ID: $requester_peering_id"
            echo "VPC ID: $accepter_vpc_id"
            echo "Requester CIDR: $requester_cidr"
            echo "Requester NAT Gateway IP: $requester_nat_gateway_ip"
            echo "----------------------------------------"
        } >> accepter-details.txt
    done
}

# Check for config file argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <config-file.json>" >&2
    exit 1
fi

process_accepter_config "$1"