#!/usr/bin/env python3

import fcntl
import json
import os
import sys
import time
from collections import defaultdict

try:
    import requests
except ImportError:
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
    log_message = f"{now}: {msg}\n"
    print(log_message)
    with open(log_file, "a") as f:
        f.write(log_message)


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


def get_last_read_position():
    """Reads the last file position from the state file."""
    if os.path.exists(state_file):
        try:
            with open(state_file, "r") as f:
                state = json.load(f)
                debug(f"Last read position from the state file: {state.get('last_position', 0)}")
                return state.get("last_position", 0)
        except Exception as e:
            debug(f"Error reading state file: {e}")
            return 0
    return 0


def save_last_read_position(position):
    """Saves the last file position to the state file."""
    try:
        with open(state_file, "w") as f:
            json.dump({"last_position": position}, f)
        debug(f"Saved last read position: {position}")
    except Exception as e:
        debug(f"Error saving state file: {e}")


def read_new_alerts():
    """
    Reads new alerts from alerts.json since the last read position.
    Returns a list of parsed alert JSON objects and the new file position.
    """
    if not os.path.exists(alerts_file):
        debug(f"Alerts file not found: {alerts_file}")
        return [], 0

    last_position = get_last_read_position()
    alerts = []

    # Fix 3: Detect log rotation/truncation by comparing byte sizes, not lines.
    # last_position is a byte offset (from f.tell()); comparing it against a line
    # count was a unit mismatch. If the file is now smaller than our saved offset,
    # the log was rotated/truncated, so restart from the beginning (0).
    file_size = os.path.getsize(alerts_file)
    if file_size < last_position:
        debug(f"Alerts file shrank (size={file_size} < last_position={last_position}); resetting cursor to 0.")
        last_position = 0

    try:
        debug(f"Reading alerts from position {last_position} in file: {alerts_file}")
        with open(alerts_file, "r") as f:
            # Seek to the last read position
            debug("Seeking the last read position...")
            f.seek(last_position)

            # Fix 1: Bound the read to at most BATCH_SIZE alerts per run so a large
            # backlog (e.g. position stalled while alerts.json kept growing) cannot be
            # loaded into memory all at once. new_position is captured right after the
            # last line we accepted, so the next run resumes from exactly there.
            #
            # NOTE: use readline() in a while loop rather than "for line in f:".
            # Iterating a text-mode file with a for-loop enables read-ahead buffering,
            # which disables f.tell() ("telling position disabled by next() call").
            # readline() does not use that buffering, so tell() stays valid.
            new_position = f.tell()
            while True:
                raw_line = f.readline()
                if not raw_line:  # EOF
                    break

                # Offset AFTER this line; only commit it once the line is accepted.
                line_end_position = f.tell()
                line = raw_line.strip()
                if not line:  # Skip empty lines
                    new_position = line_end_position
                    continue

                try:
                    alert_json = json.loads(line)
                    alerts.append(alert_json)
                    new_position = line_end_position

                except json.JSONDecodeError as e:
                    debug(f"Failed to parse JSON line: {line[:50]}... Error: {e}")
                    new_position = line_end_position
                    continue

                if len(alerts) >= READ_BATCH_SIZE:
                    debug(f"Reached read cap of {READ_BATCH_SIZE} alerts; deferring remainder to next run.")
                    break

            debug(f"New file position after reading: {new_position}")

        debug(f"Read {len(alerts)} new alerts from position {last_position} to {new_position}")
        return alerts, new_position

    except Exception as e:
        debug(f"Error reading alerts file: {e}")
        return [], last_position


def batch_alerts_by_workspace_cloud_accountId(alerts):
    """
    Groups alerts by workspace and cloud_type.
    Returns a dictionary: {(workspace_id, cloud_type, account_identifier): [alerts]}
    """
    batches = defaultdict(list)

    for alert in alerts:
        labels = alert.get("agent", {}).get("labels", {})
        workspace = labels.get("workspace")
        cloud_type = labels.get("cloud_type", "AWS")
        account_identifier = labels.get("account_identifier", "")

        debug(f"Processsing alert labels: workspace: {workspace}, cloud_type: {cloud_type}, account_identifier: {account_identifier}")

        if not workspace:
            debug(f"Alert missing workspace label, skipping: {alert.get('id', 'unknown')}")
            continue

        batches[(workspace, cloud_type, account_identifier)].append(alert)
        debug(f"Added alert to batch for workspace '{workspace}' - Cloud '{cloud_type}' - Account Identifier '{account_identifier}'")

    debug(f"Batched alerts into {len(batches)} workspace-cloud combinations")
    for (workspace, cloud_type, account_identifier), batch in batches.items():
        debug(f"  Workspace '{workspace}' - Cloud '{cloud_type}' - Account Identifier '{account_identifier}': {len(batch)} alerts")

    return batches


def send_events(events: list, workspace: str, account_identifier: str, cloud_type: str):
    """Sends a batch of events to the Cloudanix API for a specific workspace and cloud type."""
    auth_token = get_auth_token_for_workspace(workspace)

    if not auth_token:
        debug(f"Cannot send events: Auth token not found for workspace '{workspace}' even after refresh attempt.")
        return False

    headers = {
        "content-type": "application/json",
        "Authorization": f"Bearer {auth_token}",
        "x-cdx-cloud-type": cloud_type,
        "x-cdx-account-identifier": account_identifier,
        "x-cdx-workspace-identifier": workspace
    }

    alert_payload = json.dumps({"data": events})
    debug(f"Sending {len(events)} events for workspace '{workspace}' (Cloud: {cloud_type})")
    debug(f"Headers: {headers}")

    try:
        response = requests.post(config["CDX_API_URL"], data=alert_payload, headers=headers, timeout=30)
        debug(f"HTTP Status Code: {response.status_code}")
        debug(f"Response Text: {response.text}")
        response.raise_for_status()
        debug(f"API Response for workspace '{workspace}' - Cloud '{cloud_type}': {response.json()}")
        return True
    except requests.exceptions.RequestException as e:
        debug(f"Error sending events for workspace '{workspace}' - Cloud '{cloud_type}': {e}")
        return False


pwd = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
log_file = f"{pwd}/logs/cloudanix-push-alerts.log"
config_path = f"{pwd}/integrations/cloudanix-config.json"
alerts_file = f"{pwd}/logs/alerts/alerts.json"
state_file = f"{pwd}/integrations/cloudanix-state.json"
lock_file_path = f"{pwd}/integrations/cloudanix-push-alerts.lock"

# Prevent overlapping runs: if a previous invocation (triggered by the
# */1 * * * * cron entry) is still running - e.g. because CDX_API_URL is
# slow/unresponsive - exit immediately instead of stacking a new process
# on top of it. Each stacked process holds its own set of secrets/HTTP
# buffers in memory, which is what previously drove the container OOM.
lock_fd = open(lock_file_path, "w")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except (IOError, OSError):
    print("Another instance of cloudanix-push-alerts.py is already running. Exiting.")
    sys.exit(0)
sent_batches_file = f"{pwd}/integrations/cloudanix-sent-batches.json"

with open(config_path, "r") as f:
    config = json.load(f)

debug_enabled = config.get("CDX_DEBUG_ENABLED", False)

SECRET_NAME = config.get("CDX_SECRET_NAME")
AWS_REGION = config.get("AWS_REGION", "us-east-1")
BATCH_SIZE = 500          # max events per outbound API request (send chunk size)
READ_BATCH_SIZE = 1000    # max alerts read from alerts.json per run (Fix 1 read cap)

try:
    get_all_secrets_from_manager()
except Exception as e:
    debug(f"Failed to initialize secrets: {e}. Exiting.")
    sys.exit(1)


def get_sent_batch_keys():
    """Reads the set of batch keys already delivered for the current (un-advanced) window."""
    if os.path.exists(sent_batches_file):
        try:
            with open(sent_batches_file, "r") as f:
                return set(tuple(k) for k in json.load(f).get("sent_keys", []))
        except Exception as e:
            debug(f"Error reading sent-batches file: {e}")
    return set()


def save_sent_batch_keys(sent_keys):
    """Persists the set of batch keys already delivered for the current window."""
    try:
        with open(sent_batches_file, "w") as f:
            json.dump({"sent_keys": [list(k) for k in sent_keys]}, f)
    except Exception as e:
        debug(f"Error saving sent-batches file: {e}")


def clear_sent_batch_keys():
    """Clears the per-window dedupe state once the window is fully committed."""
    try:
        if os.path.exists(sent_batches_file):
            os.remove(sent_batches_file)
    except Exception as e:
        debug(f"Error clearing sent-batches file: {e}")


def main():
    # Read new alerts from the file (bounded to BATCH_SIZE by read_new_alerts, Fix 1)
    alerts, new_position = read_new_alerts()

    if not alerts:
        debug("No new alerts to process.")
        return

    # Batch alerts by workspace and cloud_type
    batches = batch_alerts_by_workspace_cloud_accountId(alerts)

    if not batches:
        debug("No valid batches to process.")
        # Still save the position since we read the file
        save_last_read_position(new_position)
        clear_sent_batch_keys()
        return

    # Fix 2: Advance progress per successful batch instead of all-or-nothing.
    # The byte cursor is a single monotonic offset covering the whole read window,
    # so it can only advance once EVERY batch in the window has been delivered.
    # To make per-batch progress durable across retries of the same window, we
    # persist the set of already-delivered batch keys and skip them on retry, so a
    # single failing workspace no longer forces re-sending the batches that succeeded.
    already_sent = get_sent_batch_keys()
    all_sent_successfully = True

    for (workspace, cloud_type, account_identifier), events in batches.items():
        batch_key = (workspace, cloud_type, account_identifier)

        if batch_key in already_sent:
            debug(f"Skipping already-delivered batch for workspace '{workspace}' - Cloud '{cloud_type}'")
            continue

        debug(f"Processing workspace: {workspace}, cloud_type: {cloud_type}")

        batch_ok = True
        if len(events) <= BATCH_SIZE:
            # Directly sending all the events for a customer if the size is less than BATCH_SIZE
            batch_ok = send_events(events, workspace, account_identifier, cloud_type)
        else:
            # Making a chunk of BATCH_SIZE and sending them to the backend
            for i in range(0, len(events), BATCH_SIZE):
                chunk = events[i:i + BATCH_SIZE]
                if not send_events(chunk, workspace, account_identifier, cloud_type):
                    batch_ok = False

        if batch_ok:
            # Record this batch as delivered so a retry of this window skips it.
            already_sent.add(batch_key)
            save_sent_batch_keys(already_sent)
        else:
            all_sent_successfully = False
            debug(f"Failed to send alerts for workspace '{workspace}' - Cloud '{cloud_type}'")

    # Only advance the byte cursor once the entire window is delivered.
    if all_sent_successfully:
        save_last_read_position(new_position)
        clear_sent_batch_keys()
        debug("All alerts sent successfully. Updated read position.")
    else:
        debug("Some alerts failed to send. Position held; delivered batches recorded for skip on retry.")


if __name__ == "__main__":
    main()
