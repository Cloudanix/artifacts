#!/usr/bin/env python3

import fcntl
import json
import sys
import os
import time
import sqlite3
from collections import defaultdict
from sqlite3 import Error

try:
    import requests
except Exception as e:
    print("No module 'requests' found. Install: pip install requests")
    sys.exit(1)

try:
    import boto3
except ImportError:
    print("No module 'boto3' found. Install: pip install boto3")
    sys.exit(1)

# Global variable to hold all customer secrets
customer_secrets = {}
secrets_last_loaded_time = 0
SECRETS_REFRESH_INTERVAL = 3 * 60 * 60  # 3 hours in seconds


def debug(msg):
    if not debug_enabled:
        return

    now = time.strftime("%a %b %d %H:%M:%S %Z %Y")
    msg = "{0}: {1}\n".format(now, msg)
    print(msg)

    f = open(log_file, "a")
    f.write(msg)
    f.close()


def should_refresh_secrets():
    """
    Checks if secrets should be refreshed based on time elapsed.
    Returns True if more than SECRETS_REFRESH_INTERVAL has passed since last load.
    """
    current_time = time.time()
    time_elapsed = current_time - secrets_last_loaded_time
    return time_elapsed >= SECRETS_REFRESH_INTERVAL


def get_all_secrets_from_manager(force_refresh=False):
    """
    Fetches the entire secret object from AWS Secrets Manager.
    The secret is expected to be a JSON object where keys are workspace identifiers.
    Expected format: {"workspace_<workspace_id>": "jwt_token"}

    Args:
        force_refresh: If True, refresh even if time interval hasn't elapsed
    """
    global customer_secrets, secrets_last_loaded_time

    # Check if we should refresh based on time
    if not force_refresh and not should_refresh_secrets() and customer_secrets:
        debug("Secrets are still fresh, skipping refresh.")
        return

    client = boto3.client('secretsmanager', region_name=AWS_REGION)
    try:
        response = client.get_secret_value(SecretId=SECRET_NAME)

        # Clear existing secrets before loading new ones
        customer_secrets.clear()
        customer_secrets.update(json.loads(response['SecretString']))

        # Update the last loaded time
        secrets_last_loaded_time = time.time()

        debug(f"Successfully loaded/refreshed {len(customer_secrets)} customer secrets.")
    except Exception as e:
        debug(f"Error fetching secrets: {e}")
        raise e


def get_auth_token_for_workspace(workspace: str) -> str:
    """
    Retrieves the auth token for a given workspace.
    If the token is not found, it will attempt to refresh secrets once and retry.

    Args:
        workspace: The workspace identifier

    Returns:
        The auth token string, or empty string if not found
    """
    workspace_key = f"workspace_{workspace}"

    # First, check if periodic refresh is needed
    if should_refresh_secrets():
        debug(f"Secrets have expired (>3 hours old), refreshing...")
        try:
            get_all_secrets_from_manager()
        except Exception as e:
            debug(f"Failed to refresh expired secrets: {e}")

    # Try to get the token
    auth_token = customer_secrets.get(workspace_key)

    # If not found, try refreshing secrets once (lazy load for new workspaces)
    if not auth_token:
        debug(f"Token not found for workspace '{workspace}', attempting to refresh secrets...")
        try:
            get_all_secrets_from_manager(force_refresh=True)
            auth_token = customer_secrets.get(workspace_key)

            if auth_token:
                debug(f"Successfully retrieved token for workspace '{workspace}' after refresh.")
            else:
                debug(f"Token still not found for workspace '{workspace}' after refresh.")
        except Exception as e:
            debug(f"Failed to refresh secrets for missing workspace '{workspace}': {e}")

    return auth_token or ""


def get_events():
    """
    Fetches up to MAX_ROWS_PER_RUN events from the database, ordered by id.

    Returns:
        Tuple of (events_by_workspace, latest_id)
        events_by_workspace: Dict of {workspace_key: [events]}
        latest_id: Highest row id read in this batch (0 if none)
    """
    events_by_workspace = defaultdict(list)
    latest_id = 0

    conn = sqlite3.connect(alerts_db)
    cursor = conn.cursor()

    try:
        cursor.execute(
            "SELECT event, id FROM vulnerability_alerts ORDER BY id ASC LIMIT ?;",
            (MAX_ROWS_PER_RUN,),
        )
        records = cursor.fetchall()

        for record in records:
            event = json.loads(record[0])
            # Rows are id-ordered, so the last row seen carries the max id.
            latest_id = record[1]

            # Extract workspace info from event
            labels = event.get("agent", {}).get("labels", {})
            workspace = labels.get("workspace")
            cloud_type = labels.get("cloud_type", "AWS")
            account_identifier = labels.get("account_identifier", "")

            if not workspace:
                debug(f"Event missing workspace label, skipping: {event.get('id', 'unknown')}")
                continue

            # Create a unique key for this workspace-cloud-account combination
            workspace_key = f"{workspace}_{cloud_type}_{account_identifier}"
            events_by_workspace[workspace_key].append(event)

    except Error as e:
        debug(f"Database error: {e}")

    finally:
        cursor.close()
        conn.close()

    return events_by_workspace, latest_id


def delete_events(latest_id):
    """
    Deletes all events up to and including latest_id.

    Args:
        latest_id: Highest row id to delete
    """
    if not latest_id:
        return

    with sqlite3.connect(alerts_db) as conn:
        conn.execute("DELETE FROM vulnerability_alerts WHERE id <= ?", (latest_id,))
    debug(f"Deleted events with id <= {latest_id}")


def send_events(events, workspace, account_identifier, cloud_type):
    """
    Sends a batch of events to the Cloudanix API for a specific workspace and cloud type.

    Args:
        events: List of events to send
        workspace: Workspace identifier
        account_identifier: Account identifier
        cloud_type: Cloud type (AWS, AZURE, GCP, etc.)

    Returns:
        Boolean indicating success
    """
    auth_token = get_auth_token_for_workspace(workspace)

    if not auth_token:
        debug(f"Cannot send events: Auth token not found for workspace '{workspace}'")
        return False

    # Handle VMWARE cloud type special case
    api_cloud_type = "AWS" if cloud_type == "VMWARE" else cloud_type

    headers = {
        "content-type": "application/json",
        "Authorization": f"Bearer {auth_token}",
        "x-cdx-cloud-type": api_cloud_type,
        "x-cdx-account-identifier": account_identifier,
        "x-cdx-workspace-identifier": workspace
    }

    alert_payload = json.dumps({"data": events})
    debug(f"Sending {len(events)} events for workspace '{workspace}' (Cloud: {cloud_type}, Account: {account_identifier})")

    try:
        response = requests.post(config["CDX_API_URL"], data=alert_payload, headers=headers, timeout=30)
        response.raise_for_status()
        debug(f"API Response for workspace '{workspace}': {response.json()}")
        return True
    except requests.exceptions.RequestException as e:
        debug(f"Error sending events for workspace '{workspace}': {e}")
        return False


# Set paths
pwd = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
log_file = f"{pwd}/logs/cloudanix-push-vuln-alerts.log"
config_path = f"{pwd}/integrations/cloudanix-config.json"
alerts_db = f"{pwd}/integrations/cloudanix-alerts.db"
lock_file_path = f"{pwd}/integrations/cloudanix-push-vuln-alerts.lock"

config = {}
with open(config_path, "r") as config_file:
    config = json.loads(config_file.read())
    config_file.close()

debug_enabled = config.get("CDX_DEBUG_ENABLED", False)
SECRET_NAME = config.get("CDX_SECRET_NAME")
AWS_REGION = config.get("AWS_REGION", "us-east-1")
BATCH_SIZE = 500              # Max events per POST request
MAX_ROWS_PER_RUN = 50000      # Max rows drained from the DB per invocation
SEND_MAX_RETRIES = 3          # Send attempts per batch before giving up
SEND_RETRY_SLEEP = 10         # Seconds between send retries

# Prevent overlapping runs: if a previous invocation (triggered by the
# */5 * * * * cron entry) is still running - e.g. because CDX_API_URL is
# slow/unresponsive - exit immediately instead of stacking a new process
# on top of it. Stacked processes were driving the worker container OOM.
lock_fd = open(lock_file_path, "w")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except (IOError, OSError):
    print("Another instance of cloudanix-push-vuln-alerts.py is already running. Exiting.")
    sys.exit(0)

debug(sys.argv)

# Initialize secrets from GCP Secret Manager
try:
    get_all_secrets_from_manager()
except Exception as e:
    debug(f"Failed to initialize secrets: {e}. Exiting.")
    sys.exit(1)


def send_batch_with_retry(batch, workspace, account_identifier, cloud_type):
    """
    Sends a single batch, retrying up to SEND_MAX_RETRIES times with a
    SEND_RETRY_SLEEP-second pause between failures.

    Returns:
        Boolean indicating whether the batch was delivered.
    """
    for attempt in range(1, SEND_MAX_RETRIES + 1):
        if send_events(batch, workspace, account_identifier, cloud_type):
            return True
        debug(f"Send attempt {attempt}/{SEND_MAX_RETRIES} failed for workspace '{workspace}'")
        if attempt < SEND_MAX_RETRIES:
            time.sleep(SEND_RETRY_SLEEP)
    return False


def main():
    # Fetch a bounded batch of events grouped by workspace.
    events_by_workspace, latest_id = get_events()

    total_events = sum(len(events) for events in events_by_workspace.values())
    debug(f"Total events fetched: {total_events} across {len(events_by_workspace)} workspace combinations (up to id {latest_id})")

    if not latest_id:
        debug("No new events to process.")
        return

    # Process each workspace separately, retrying failed sends.
    for workspace_key, events in events_by_workspace.items():
        # Parse the workspace key
        parts = workspace_key.split('_', 2)
        if len(parts) < 3:
            debug(f"Invalid workspace key format: {workspace_key}")
            continue

        workspace = parts[0]
        cloud_type = parts[1]
        account_identifier = parts[2]

        debug(f"Processing workspace: {workspace}, cloud_type: {cloud_type}, account: {account_identifier}")

        # Send events in chunks, retrying each chunk up to SEND_MAX_RETRIES times.
        for i in range(0, len(events), BATCH_SIZE):
            batch = events[i:i + BATCH_SIZE]
            if send_batch_with_retry(batch, workspace, account_identifier, cloud_type):
                debug(f"Sent batch of {len(batch)} events for {workspace_key}")
            else:
                # Give up on this batch after retries; it will be force-deleted
                # below to keep the DB bounded (see delete_events call).
                debug(f"Giving up on batch for {workspace_key} after {SEND_MAX_RETRIES} attempts; events will be dropped")

    # Force-delete everything we read this run, regardless of send outcome.
    # Batches that failed all retries are intentionally dropped to prevent the
    # alerts DB from growing unbounded when the API is unavailable.
    delete_events(latest_id)
    debug(f"Advanced past id {latest_id}")


if __name__ == "__main__":
    main()
