#!/usr/bin/env python3

import json
import sys
import time
import os
import sqlite3
from sqlite3 import Error
import socket

try:
    import requests
except ImportError:
    print("No module 'requests' found. Install: pip install requests")
    sys.exit(1)


def debug(msg):
    if not debug_enabled:
        return

    now = time.strftime("%a %b %d %H:%M:%S %Z %Y")
    msg = "{0}: {1}\n".format(now, msg)
    print(msg)

    f = open(log_file, "a")
    f.write(msg)
    f.close()


def delete_keys(dictionary, keys):
    for key in keys:
        if key in dictionary:
            del dictionary[key]


def get_server_ip():
    return socket.gethostbyname(socket.gethostname())


def get_wazuh_token(server_ip, username, password, max_retries=3):
    """Authenticate with the Wazuh API and return a JWT token."""
    for attempt in range(max_retries):
        try:
            url = f"https://{server_ip}:55000/security/user/authenticate?raw=true"
            response = requests.post(url, auth=(username, password), verify=False, timeout=10)
            response.raise_for_status()
            return response.text
        except requests.RequestException as e:
            if attempt == max_retries - 1:
                debug(f"Failed to get Wazuh token after {max_retries} attempts: {e}")
                return None
            time.sleep(2 ** attempt)
    return None


def get_agent_groups(server_ip, wazuh_token, agent_id):
    """Fetch the list of groups an agent belongs to from the Wazuh API."""
    try:
        url = f"https://{server_ip}:55000/agents?agents_list={agent_id}&select=group"
        headers = {"Authorization": f"Bearer {wazuh_token}"}
        response = requests.get(url, headers=headers, verify=False, timeout=10)
        response.raise_for_status()
        items = response.json().get("data", {}).get("affected_items", [])
        if items:
            return items[0].get("group", [])
        return []
    except Exception as e:
        debug(f"Error fetching groups for agent {agent_id}: {e}")
        return []


def add_agent_to_group(server_ip, wazuh_token, agent_id, group_name):
    """Add an agent to a Wazuh group. Creates the group first if it doesn't exist."""
    headers = {"Authorization": f"Bearer {wazuh_token}"}
    try:
        # Ensure the group exists by attempting to create it (idempotent)
        create_url = f"https://{server_ip}:55000/groups"
        requests.post(create_url, json={"group_id": group_name}, headers=headers, verify=False, timeout=10)

        # Add the agent to the group
        url = f"https://{server_ip}:55000/agents/{agent_id}/group/{group_name}"
        response = requests.put(url, headers=headers, verify=False, timeout=10)
        response.raise_for_status()
        debug(f"Successfully added agent {agent_id} to group '{group_name}'")
        return True
    except Exception as e:
        debug(f"Error adding agent {agent_id} to group '{group_name}': {e}")
        return False


def get_agent_labels_from_api(server_ip, wazuh_token, agent_id):
    """Fetch agent labels from the Wazuh API as a fallback for missing label data."""
    try:
        url = f"https://{server_ip}:55000/agents/{agent_id}/config/agent/labels"
        headers = {"Authorization": f"Bearer {wazuh_token}"}
        response = requests.get(url, headers=headers, verify=False, timeout=10)
        response.raise_for_status()
        labels_list = response.json().get("data", {}).get("labels", [])
        labels_dict = {}
        for label in labels_list:
            if isinstance(label, dict) and 'key' in label and 'value' in label:
                labels_dict[label['key']] = label['value']
        return labels_dict
    except Exception as e:
        debug(f"Error fetching labels for agent {agent_id} from API: {e}")
        return {}


def check_and_assign_manual_install_group(server_ip, wazuh_token, agent_id):
    """
    Check if the agent belongs to the 'autoInstalled' group.
    If the group doesn't exist or the agent is not in it, add the agent to 'manualInstalled'.
    """
    groups = get_agent_groups(server_ip, wazuh_token, agent_id)
    debug(f"Agent {agent_id} current groups: {groups}")

    if "autoInstalled" not in groups and "manualInstalled" not in groups:
        debug(f"Agent {agent_id} is not in 'autoInstalled' or 'manualInstalled' group. Adding to 'manualInstalled'.")
        add_agent_to_group(server_ip, wazuh_token, agent_id, "manualInstalled")
    elif "autoInstalled" in groups:
        debug(f"Agent {agent_id} is already in 'autoInstalled' group. Skipping.")
    else:
        debug(f"Agent {agent_id} is already in 'manualInstalled' group. Skipping.")


# Set paths
pwd = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
log_file = f"{pwd}/logs/cloudanix-integration.log"
config_path = f"{pwd}/integrations/cloudanix-config.json"
alerts_db = f"{pwd}/integrations/cloudanix-alerts.db"

config = {}

# Read configuration parameters
with open(config_path, "r") as config_file:
    config = json.loads(config_file.read())
    config_file.close()

debug_enabled = config.get("CDX_DEBUG_ENABLED", False)
SERVER_IP = config.get("WAZUH_SERVER_IP", get_server_ip())

debug(f"Configuration loaded successfully {config}")

debug(sys.argv)

# Read the alert file
alert_file = open(sys.argv[1])
alert_content = alert_file.read().strip()
alert_file.close()

# Parse the first valid JSON object (or you can process all of them)
alert_json = None
for line in alert_content.split('\n'):
    line = line.strip()
    if line:  # Skip empty lines
        try:
            alert_json = json.loads(line)
        except json.JSONDecodeError as e:
            debug(f"Failed to parse JSON line: {line[:50]}... Error: {e}")
            continue

if not alert_json:
    debug("No valid JSON found in alert file")
    sys.exit(1)

debug(f"Alert JSON loaded successfully: {alert_json}")

keys_to_delete = ['level', 'description_raw', 'severity', 'os', 'mitre', 'groups', 'service', 'parent_rule']
delete_keys(alert_json["rule"], keys_to_delete)

if alert_json["agent"].get("id") == "000":
    alert_json["agent"]["ip"] = config.get("WAZUH_SERVER_IP", get_server_ip())

agent_id = alert_json.get("agent", {}).get("id", "")

# Get the account_identifier
account_identifier = alert_json.get("agent", {}).get("labels", {}).get("account_identifier", "unidentified_account")

# Get the workspace_identifier (label key is "workspace" in Wazuh agent labels)
workspace = alert_json.get("agent", {}).get("labels", {}).get("workspace", "unidentified_workspace")

# Get the cloud_type
cloud_type = alert_json.get("agent", {}).get("labels", {}).get("cloud_type", "AWS")

# Fallback: if labels are missing from the alert, try fetching from Wazuh API
if (account_identifier == "unidentified_account" or workspace == "unidentified_workspace") and agent_id != "000":
    debug(f"Labels missing from alert for agent {agent_id}. Attempting Wazuh API fallback.")
    wazuh_token = get_wazuh_token(SERVER_IP, "wazuh", config.get("WAZUH_REST_PASSWORD"))
    if wazuh_token:
        api_labels = get_agent_labels_from_api(SERVER_IP, wazuh_token, agent_id)
        if api_labels:
            if workspace == "unidentified_workspace" and api_labels.get("workspace"):
                workspace = api_labels["workspace"]
                debug(f"Resolved workspace from API: {workspace}")
            if account_identifier == "unidentified_account" and api_labels.get("account_identifier"):
                account_identifier = api_labels["account_identifier"]
                debug(f"Resolved account_identifier from API: {account_identifier}")
            if cloud_type == "AWS" and api_labels.get("cloud_type"):
                cloud_type = api_labels["cloud_type"]
                debug(f"Resolved cloud_type from API: {cloud_type}")

data = json.dumps(alert_json)
debug(data)

conn = None
try:
    timestamp = int(time.time())
    debug(f"Current timestamp: {timestamp}")

    # Insert the alert into table
    with sqlite3.connect(alerts_db) as conn:

        debug("Connected to the database successfully")

        # First, check for the terminal event: agent disconnection.
        if alert_json.get("rule", {}).get("id", "") in ["504", "505"]:
            debug("Agent disconnected")
            conn.execute("DELETE FROM agents WHERE agent_id=?", (agent_id,))
        else:
            # For any other event (new agent, vulnerability, etc.), ensure the agent record exists.
            # agent_added_date is stored as a Unix timestamp (integer) for consistency.
            conn.execute("INSERT OR IGNORE INTO agents (agent_id, agent_added_date, vulns_sync_status) VALUES(?,?,?)", (agent_id, timestamp, False))

            # Update workspace_identifier, account_identifier, cloud_type if available
            if account_identifier != "unidentified_account" and workspace != "unidentified_workspace":
                conn.execute("UPDATE agents SET account_identifier=?, workspace_identifier=?, cloud_type=? WHERE agent_id=?", (account_identifier, workspace, cloud_type, agent_id))
                debug(f"Updated agent {agent_id} with account details.")

            # New agent connected
            if alert_json.get("rule", {}).get("id", "") == "501":
                debug("New agent connected event processed.")

            # Vulnerability found - update first_vuln_date if not set
            if alert_json.get("data", {}).get("vulnerability"):
                debug(f"Vulnerability found for {agent_id}, updating first_vuln_date if necessary.")
                conn.execute("UPDATE agents SET first_vuln_date=? WHERE agent_id=? AND first_vuln_date IS NULL", (timestamp, agent_id))

            # Check and assign manualInstalled group if agent is not auto-installed.
            # Skip for agent 000 (the server itself).
            if agent_id != "000":
                try:
                    wazuh_token_for_group = get_wazuh_token(SERVER_IP, "wazuh", config.get("WAZUH_REST_PASSWORD"))
                    if wazuh_token_for_group:
                        check_and_assign_manual_install_group(SERVER_IP, wazuh_token_for_group, agent_id)
                    else:
                        debug(f"Could not get Wazuh token for group assignment of agent {agent_id}")
                except Exception as e:
                    debug(f"Error during group assignment for agent {agent_id}: {e}")

    debug("# Inserted alert into Local DB")

except Error as e:
    debug(e)

finally:
    if conn:
        conn.close()

sys.exit(0)
