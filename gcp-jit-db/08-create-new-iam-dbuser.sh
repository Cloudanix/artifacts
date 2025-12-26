#!/bin/bash

SQL_INSTANCE_NAME=""
DB_TYPE=""
DB_USER_PROJECT_ID=""
GKE_PROJECT_ID=""
GKE_SERVICE_ACCOUNT=""
DATABASE_NAME=""

# NEW_SERVICE_ACCOUNT_NAMES can be:
# Single value: "db-user-1"
# Multiple values (space-separated): "db-user-1 db-user-2 db-user-3"
NEW_SERVICE_ACCOUNT_NAMES=""

echo "================================================"
echo "Cloud SQL IAM Authentication Setup Script"
echo "================================================"
echo ""

# Step 0: Validate DB_TYPE
if [[ "$DB_TYPE" != "postgresql" && "$DB_TYPE" != "mysql" ]]; then
    echo "Error: DB_TYPE must be either 'postgresql' or 'mysql'"
    exit 1
fi

# Step 1: Enable IAM Authentication on Cloud SQL Instance
echo "Step 1: Enabling IAM Authentication on Cloud SQL Instance..."
if [ "$DB_TYPE" == "postgresql" ]; then
    gcloud sql instances patch "$SQL_INSTANCE_NAME" \
        --database-flags cloudsql.iam_authentication=on
    if [ $? -ne 0 ]; then
        echo "Error: Failed to enable IAM authentication"
        exit 1
    fi
elif [ "$DB_TYPE" == "mysql" ]; then
    gcloud sql instances patch "$SQL_INSTANCE_NAME" \
        --database-flags cloudsql_iam_authentication=on
    if [ $? -ne 0 ]; then
        echo "Error: Failed to enable IAM authentication"
        exit 1
    fi
fi
echo "IAM Authentication enabled successfully."
echo ""

# Convert space-separated string to array
IFS=' ' read -ra SA_NAMES_ARRAY <<< "$NEW_SERVICE_ACCOUNT_NAMES"

echo "================================================"
echo "Processing ${#SA_NAMES_ARRAY[@]} service account(s)..."
echo "================================================"
echo ""

# Arrays to store results
CREATED_ACCOUNTS=()
DB_USERNAMES=()

# Process each service account
for NEW_SERVICE_ACCOUNT_NAME in "${SA_NAMES_ARRAY[@]}"; do
    echo "----------------------------------------"
    echo "Processing: $NEW_SERVICE_ACCOUNT_NAME"
    echo "----------------------------------------"
    
    # Derived variables for this service account
    CREATED_SERVICE_ACCOUNT="${NEW_SERVICE_ACCOUNT_NAME}@${DB_USER_PROJECT_ID}.iam.gserviceaccount.com"
    
    # Database username format differs by DB type
    if [ "$DB_TYPE" == "postgresql" ]; then
        DB_USERNAME="${NEW_SERVICE_ACCOUNT_NAME}@${DB_USER_PROJECT_ID}.iam"
    elif [ "$DB_TYPE" == "mysql" ]; then
        DB_USERNAME="$NEW_SERVICE_ACCOUNT_NAME"
    fi
    
    # Step 2: Create a service account (check if exists first)
    echo "Step 2: Creating service account..."
    if gcloud iam service-accounts describe "$CREATED_SERVICE_ACCOUNT" --project="$DB_USER_PROJECT_ID" &>/dev/null; then
        echo "  ✓ Service account already exists: $CREATED_SERVICE_ACCOUNT"
        echo "  Skipping creation..."
    else
        gcloud iam service-accounts create "$NEW_SERVICE_ACCOUNT_NAME" \
            --project="$DB_USER_PROJECT_ID" \
            --display-name="Cloud SQL IAM User Service Account"
        if [ $? -ne 0 ]; then
            echo "  ✗ Error: Failed to create service account"
            exit 1
        fi
        echo "  ✓ Service account created: $CREATED_SERVICE_ACCOUNT"
    fi
    echo ""
    
    # Step 3: Create a Cloud IAM user for Cloud SQL Instance
    echo "Step 3: Creating Cloud IAM user for Cloud SQL Instance..."
    if gcloud sql users list --instance="$SQL_INSTANCE_NAME" --format="value(name)" | grep -q "^${DB_USERNAME}$"; then
        echo "  ✓ Cloud IAM user already exists: $DB_USERNAME"
        echo "  Skipping creation..."
    else
        if [ "$DB_TYPE" == "postgresql" ]; then
            gcloud sql users create "$DB_USERNAME" \
                --instance="$SQL_INSTANCE_NAME" \
                --type=CLOUD_IAM_SERVICE_ACCOUNT
        elif [ "$DB_TYPE" == "mysql" ]; then
            gcloud sql users create "$CREATED_SERVICE_ACCOUNT" \
                --instance="$SQL_INSTANCE_NAME" \
                --type=CLOUD_IAM_SERVICE_ACCOUNT
        fi
        if [ $? -ne 0 ]; then
            echo "  ✗ Error: Failed to create Cloud IAM user"
            exit 1
        fi
        echo "  ✓ Cloud IAM user created successfully: $DB_USERNAME"
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
    
    echo "✓ Completed processing: $NEW_SERVICE_ACCOUNT_NAME"
    echo ""
done

# Step 7: Grant DB permissions summary
echo "================================================"
echo "Step 7: Database Permissions Grant Summary"
echo "================================================"
echo ""
echo "Grant permissions for the following user(s) on required databases:"
echo ""

for i in "${!DB_USERNAMES[@]}"; do
    echo "  $((i+1)). Database Username: ${DB_USERNAMES[$i]}"
    echo "     Service Account: ${CREATED_ACCOUNTS[$i]}"
    echo ""
done

echo "✓ Setup completed successfully!"
echo "================================================"
echo "Total service accounts created/configured: ${#CREATED_ACCOUNTS[@]}"
echo "================================================"