#!/bin/bash

echo "================================================"
echo "Cloud SQL IAM Authentication Setup Script"
echo "================================================"
echo ""
echo "Please provide the following information:"
echo ""

# Prompt for all inputs
read -p "Enter SQL Instance Name: " SQL_INSTANCE_NAME
read -p "Enter Database Type (postgresql/mysql): " DB_TYPE
read -p "Enter DB User Project ID: " DB_USER_PROJECT_ID
read -p "Enter GKE Project ID (press Enter to use same as DB User Project): " GKE_PROJECT_ID
GKE_PROJECT_ID=${GKE_PROJECT_ID:-$DB_USER_PROJECT_ID}

echo ""
echo "Default GKE Service Account pattern: cdx-jit-workload-sa@${GKE_PROJECT_ID}.iam.gserviceaccount.com"
read -p "Enter GKE Service Account (press Enter to use default): " GKE_SERVICE_ACCOUNT
GKE_SERVICE_ACCOUNT=${GKE_SERVICE_ACCOUNT:-"cdx-jit-workload-sa@${GKE_PROJECT_ID}.iam.gserviceaccount.com"}

read -p "Enter IAM DB User Name(s) (space-separated for multiple): " IAM_DB_USER_NAMES

echo ""
echo "================================================"
echo "Configuration Summary:"
echo "================================================"
echo "SQL Instance: $SQL_INSTANCE_NAME"
echo "Database Type: $DB_TYPE"
echo "DB User Project ID: $DB_USER_PROJECT_ID"
echo "GKE Project ID: $GKE_PROJECT_ID"
echo "GKE Service Account: $GKE_SERVICE_ACCOUNT"
echo "DB Username(s): $IAM_DB_USER_NAMES"
echo "================================================"
echo ""
read -p "Continue with this configuration? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Setup cancelled."
    exit 0
fi
echo ""

# Step 0: Validate DB_TYPE
if [[ "$DB_TYPE" != "postgresql" && "$DB_TYPE" != "mysql" ]]; then
    echo "Error: DB_TYPE must be either 'postgresql' or 'mysql'"
    exit 1
fi

# Step 1: Enable IAM Authentication on Cloud SQL Instance
echo "Step 1: Enabling IAM Authentication on Cloud SQL Instance: $SQL_INSTANCE_NAME..."

# Get existing database flags in JSON format
echo "  Fetching existing database flags..."
EXISTING_FLAGS_JSON=$(gcloud sql instances describe "$SQL_INSTANCE_NAME" \
    --project="$DB_USER_PROJECT_ID" \
    --format="json" 2>/dev/null | jq -r '.settings.databaseFlags // [] | map("\(.name)=\(.value)") | join(",")' 2>/dev/null)

# Check if the command succeeded
if [ ${PIPESTATUS[0]} -ne 0 ] || [ ${PIPESTATUS[1]} -ne 0 ]; then
    echo "  ✗ Error: Failed to fetch database flags. Please check:"
    echo "    - Instance name is correct"
    echo "    - Project ID is correct"
    echo "    - You have proper permissions"
    echo "    - jq is installed"
    exit 1
fi

# Build the IAM flag
if [ "$DB_TYPE" == "postgresql" ]; then
    IAM_FLAG_NAME="cloudsql.iam_authentication"
elif [ "$DB_TYPE" == "mysql" ]; then
    IAM_FLAG_NAME="cloudsql_iam_authentication"
fi

# Check if IAM flag already exists
if echo "$EXISTING_FLAGS_JSON" | grep -qE "(^|,)${IAM_FLAG_NAME}=on(,|$)"; then
    echo "  ✓ IAM Authentication is already enabled on $SQL_INSTANCE_NAME"
else
    echo "  Current flags: $EXISTING_FLAGS_JSON"
    echo "  Adding IAM authentication flag..."
    
    # Remove the IAM flag if it exists (regardless of value) to avoid duplicates
    # This handles the case where the flag might be set to "off"
    CLEANED_FLAGS=$(echo "$EXISTING_FLAGS_JSON" | sed -E "s/(^|,)${IAM_FLAG_NAME}=[^,]*(,|$)/\1/g" | sed 's/^,//;s/,$//')
    
    # Build new flags string
    if [ -n "$CLEANED_FLAGS" ] && [ "$CLEANED_FLAGS" != "null" ]; then
        NEW_FLAGS="${CLEANED_FLAGS},${IAM_FLAG_NAME}=on"
    else
        NEW_FLAGS="${IAM_FLAG_NAME}=on"
    fi
    
    echo "  New flags to apply: $NEW_FLAGS"
    
    gcloud sql instances patch "$SQL_INSTANCE_NAME" \
        --project="$DB_USER_PROJECT_ID" \
        --database-flags "$NEW_FLAGS"
    
    if [ $? -ne 0 ]; then
        echo "  ✗ Error: Failed to enable IAM authentication on $SQL_INSTANCE_NAME"
        exit 1
    fi
    echo "  ✓ IAM Authentication enabled successfully on $SQL_INSTANCE_NAME"
fi
echo ""

# Convert space-separated string to array
IFS=' ' read -ra SA_NAMES_ARRAY <<< "$IAM_DB_USER_NAMES"

echo "================================================"
echo "Processing ${#SA_NAMES_ARRAY[@]} service account(s)..."
echo "================================================"
echo ""

# Arrays to store results
CREATED_ACCOUNTS=()
DB_USERNAMES=()

# Process each service account
for IAM_DB_SERVICE_ACCOUNT_NAME in "${SA_NAMES_ARRAY[@]}"; do
    echo "----------------------------------------"
    echo "Processing: $IAM_DB_SERVICE_ACCOUNT_NAME"
    echo "----------------------------------------"
    
    # Derived variables for this service account
    CREATED_SERVICE_ACCOUNT="${IAM_DB_SERVICE_ACCOUNT_NAME}@${DB_USER_PROJECT_ID}.iam.gserviceaccount.com"
    
    # Database username format differs by DB type
    if [ "$DB_TYPE" == "postgresql" ]; then
        # PostgreSQL: username format is service-account-name@project-id.iam
        DB_USERNAME="${IAM_DB_SERVICE_ACCOUNT_NAME}@${DB_USER_PROJECT_ID}.iam"
    elif [ "$DB_TYPE" == "mysql" ]; then
        # MySQL: username is the full service account email
        DB_USERNAME="$CREATED_SERVICE_ACCOUNT"
    fi
    
    # Step 2: Create a service account (check if exists first)
    echo "Step 2: Creating service account..."
    if gcloud iam service-accounts describe "$CREATED_SERVICE_ACCOUNT" --project="$DB_USER_PROJECT_ID" &>/dev/null; then
        echo "  ✓ Service account already exists: $CREATED_SERVICE_ACCOUNT"
        echo "  Skipping creation..."
    else
        gcloud iam service-accounts create "$IAM_DB_SERVICE_ACCOUNT_NAME" \
            --project="$DB_USER_PROJECT_ID" \
            --display-name="Cloud SQL IAM User Service Account"
        if [ $? -ne 0 ]; then
            echo "  ✗ Error: Failed to create service account"
            exit 1
        fi
        echo "  ✓ Service account created: $CREATED_SERVICE_ACCOUNT"
    fi
    echo ""
    
    # Step 3: Create Cloud IAM user for the Cloud SQL Instance
    echo "Step 3: Creating Cloud IAM user for Cloud SQL Instance: $SQL_INSTANCE_NAME..."
    
    # Check if user already exists
    if [ "$DB_TYPE" == "postgresql" ]; then
        EXISTING_USER=$(gcloud sql users list --instance="$SQL_INSTANCE_NAME" --project="$DB_USER_PROJECT_ID" --format="value(name)" 2>/dev/null | grep -x "${DB_USERNAME}")
    elif [ "$DB_TYPE" == "mysql" ]; then
        EXISTING_USER=$(gcloud sql users list --instance="$SQL_INSTANCE_NAME" --project="$DB_USER_PROJECT_ID" --format="value(name)" 2>/dev/null | grep -x "${CREATED_SERVICE_ACCOUNT}")
    fi
    
    if [ -n "$EXISTING_USER" ]; then
        echo "  ✓ Cloud IAM user already exists on $SQL_INSTANCE_NAME: $DB_USERNAME"
        echo "  Skipping creation..."
    else
        if [ "$DB_TYPE" == "postgresql" ]; then
            # PostgreSQL: create user with the username format
            gcloud sql users create "$DB_USERNAME" \
                --instance="$SQL_INSTANCE_NAME" \
                --project="$DB_USER_PROJECT_ID" \
                --type=CLOUD_IAM_SERVICE_ACCOUNT
        elif [ "$DB_TYPE" == "mysql" ]; then
            # MySQL: create user with the full service account email
            gcloud sql users create "$CREATED_SERVICE_ACCOUNT" \
                --instance="$SQL_INSTANCE_NAME" \
                --project="$DB_USER_PROJECT_ID" \
                --type=CLOUD_IAM_SERVICE_ACCOUNT
        fi
        if [ $? -ne 0 ]; then
            echo "  ✗ Error: Failed to create Cloud IAM user on $SQL_INSTANCE_NAME"
            exit 1
        fi
        echo "  ✓ Cloud IAM user created successfully on $SQL_INSTANCE_NAME: $DB_USERNAME"
    fi
    echo ""
    
    # Step 4: Add Cloud SQL Instance User Role
    echo "Step 4: Adding Cloud SQL Instance User role..."
    gcloud projects add-iam-policy-binding "$DB_USER_PROJECT_ID" \
        --member="serviceAccount:$CREATED_SERVICE_ACCOUNT" \
        --role="roles/cloudsql.instanceUser" \
        --condition=None 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "  ⚠ Warning: Failed to add Cloud SQL Instance User role (may already exist)"
    else
        echo "  ✓ Cloud SQL Instance User role added successfully."
    fi
    echo ""
    
    # Step 5: Add Service Account Token Creator role to GKE Service Account
    echo "Step 5: Adding Service Account Token Creator role to GKE SA..."
    gcloud iam service-accounts add-iam-policy-binding "$CREATED_SERVICE_ACCOUNT" \
        --project="$DB_USER_PROJECT_ID" \
        --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
        --role="roles/iam.serviceAccountTokenCreator"
    if [ $? -ne 0 ]; then
        echo "  ✗ Error: Failed to add Service Account Token Creator role"
        exit 1
    fi
    echo "  ✓ Service Account Token Creator role added successfully."
    echo ""
    
    # Step 6: Add Service Account User role for impersonation
    echo "Step 6: Adding Service Account User role for GKE SA impersonation..."
    gcloud iam service-accounts add-iam-policy-binding "$CREATED_SERVICE_ACCOUNT" \
        --project="$DB_USER_PROJECT_ID" \
        --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
        --role="roles/iam.serviceAccountUser"
    if [ $? -ne 0 ]; then
        echo "  ✗ Error: Failed to add Service Account User role"
        exit 1
    fi
    echo "  ✓ Service Account User role added successfully for impersonation."
    echo ""
    
    # Store results
    CREATED_ACCOUNTS+=("$CREATED_SERVICE_ACCOUNT")
    DB_USERNAMES+=("$DB_USERNAME")
    
    echo "✓ Completed processing: $IAM_DB_SERVICE_ACCOUNT_NAME"
    echo ""
done

echo "✓ Setup completed successfully!"
echo "================================================"
echo "SQL Instance: $SQL_INSTANCE_NAME"
echo "Total service accounts created/configured: ${#CREATED_ACCOUNTS[@]}"
echo "================================================"