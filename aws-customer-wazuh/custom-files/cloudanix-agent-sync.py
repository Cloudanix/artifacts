#!/usr/bin/env python3

import json
import os
import time
import requests

# AWS Secrets Manager imports
try:
    import boto3
except ImportError:
    print("No module 'boto3' found. Install: pip install boto3")
    exit(1)

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


def get_aws_secret(secrets_client, secret_name: str, force_refresh=False) -> bool:
    """
    Returns the JWT Token for each account ID from AWS Secrets Manager

    Args:
        secrets_client: Boto3 secrets manager client
        secret_name: Name of the secret in AWS Secrets Manager
        force_refresh: If True, refresh even if time interval hasn't elapsed

    Returns:
        True if secrets were loaded successfully, False otherwise
    """
    global customer_secrets, secrets_last_loaded_time

    # Check if we should refresh based on time
    if not force_refresh and not should_refresh_secrets() and customer_secrets:
        debug("Secrets are still fresh, skipping refresh.")
        return True

    try:
        response = secrets_client.get_secret_value(SecretId=secret_name)

        # Clear existing secrets before loading new ones
        customer_secrets.clear()
        customer_secrets.update(json.loads(response['SecretString']))

        # Update the last loaded time
        secrets_last_loaded_time = time.time()

        debug(f"Successfully loaded/refreshed {len(customer_secrets)} customer secrets.")
        return True
    except Exception as e:
        debug(f"Error retrieving secret from AWS Secrets Manager: {str(e)}")
        return False


def get_auth_token_for_workspace(secrets_client, secret_name: str, workspace: str) -> str:
    """
    Retrieves the auth token for a given workspace.
    If the token is not found, it will attempt to refresh secrets once and retry.

    Args:
        secrets_client: Boto3 secrets manager client
        secret_name: Name of the secret in AWS Secrets Manager
        workspace: The workspace identifier

    Returns:
        The auth token string, or empty string if not found
    """
    workspace_key = f"workspace_{workspace}"

    # First, check if periodic refresh is needed
    if should_refresh_secrets():
        debug(f"Secrets have expired (>3 hours old), refreshing...")
        get_aws_secret(secrets_client=secrets_client, secret_name=secret_name)

    # Try to get the token
    auth_token = customer_secrets.get(workspace_key)

    # If not found, try refreshing secrets once (lazy load for new workspaces)
    if not auth_token:
        debug(f"Token not found for workspace '{workspace}', attempting to refresh secrets...")
        if get_aws_secret(secrets_client=secrets_client, secret_name=secret_name, force_refresh=True):
            auth_token = customer_secrets.get(workspace_key)

            if auth_token:
                debug(f"Successfully retrieved token for workspace '{workspace}' after refresh.")
            else:
                debug(f"Token still not found for workspace '{workspace}' after refresh.")
        else:
            debug(f"Failed to refresh secrets for missing workspace '{workspace}'")

    return auth_token or ""


def get_server_unique_id(config):
    cloud_type = config.get("CDX_CLOUD_TYPE")
    agent_name = config.get("SERVER_NAME")
    agent_unique_id = None
    account_id = None

    if cloud_type == "AWS":
        try:
            # First attempt without IMDSv2 token
            resp = requests.get("http://169.254.169.254/latest/meta-data/instance-id", timeout=2)
            if resp.status_code == 200:
                agent_name = resp.text.strip()
                identity_doc = requests.get(
                    "http://169.254.169.254/latest/dynamic/instance-identity/document",
                    timeout=2
                ).json()
                account_id = identity_doc.get("accountId")
                region = identity_doc.get("region")
                agent_unique_id = f"arn:aws:ec2:{region}:{account_id}:instance/{agent_name}"
            else:
                # Try IMDSv2
                token = requests.put(
                    "http://169.254.169.254/latest/api/token",
                    headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
                    timeout=2
                ).text.strip()
                headers = {"X-aws-ec2-metadata-token": token}
                resp = requests.get(
                    "http://169.254.169.254/latest/meta-data/instance-id",
                    headers=headers, timeout=2
                )
                if resp.status_code == 200:
                    agent_name = resp.text.strip()
                    identity_doc = requests.get(
                        "http://169.254.169.254/latest/dynamic/instance-identity/document",
                        headers=headers, timeout=2
                    ).json()
                    account_id = identity_doc.get("accountId")
                    region = identity_doc.get("region")
                    agent_unique_id = f"arn:aws:ec2:{region}:{account_id}:instance/{agent_name}"

        except Exception as e:
            print(f"Error fetching AWS metadata: {e}")

    elif cloud_type == "AZURE":
        try:
            headers = {"Metadata": "true"}
            agent_name = requests.get(
                "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-08-01&format=text",
                headers=headers, timeout=2
            ).text.strip()
            metadata_json = requests.get(
                "http://169.254.169.254/metadata/instance?api-version=2021-02-01&format=json",
                headers=headers, timeout=2
            ).json()
            account_id = metadata_json.get("compute", {}).get("subscriptionId")
            resource_group = metadata_json.get("compute", {}).get("resourceGroupName")
            vm_name = metadata_json.get("compute", {}).get("name")
            agent_unique_id = f"/subscriptions/{account_id}/resourceGroups/{resource_group}/providers/Microsoft.Compute/virtualMachines/{vm_name}"
        except Exception as e:
            print(f"Error fetching Azure metadata: {e}")

    elif cloud_type == "GCP":
        try:
            headers = {"Metadata-Flavor": "Google"}
            agent_name = requests.get(
                "http://metadata.google.internal/computeMetadata/v1/instance/id",
                headers=headers, timeout=2
            ).text.strip()
            account_id = requests.get(
                "http://169.254.169.254/computeMetadata/v1/project/project-id",
                headers=headers, timeout=2
            ).text.strip()
            zone_full = requests.get(
                "http://169.254.169.254/computeMetadata/v1/instance/zone",
                headers=headers, timeout=2
            ).text.strip()
            instance_name = requests.get(
                "http://169.254.169.254/computeMetadata/v1/instance/name",
                headers=headers, timeout=2
            ).text.strip()
            zone = os.path.basename(zone_full)
            agent_unique_id = f"projects/{account_id}/zones/{zone}/instances/{instance_name}"
        except Exception as e:
            print(f"Error fetching GCP metadata: {e}")

    elif cloud_type == "VMWARE":
        if not (cloud_type and agent_name):
            raise ValueError("Error: --cloud, --host_id are required")
        account_id = "UNKNOWN"
        agent_unique_id = agent_name

    elif cloud_type == "OCI":
        try:
            headers = {"Authorization": "Bearer Oracle"}
            agent_name = requests.get(
                "http://169.254.169.254/opc/v2/instance/id",
                headers=headers, timeout=2
            ).text.strip()
            account_id = requests.get(
                "http://169.254.169.254/opc/v2/instance/compartmentId",
                headers=headers, timeout=2
            ).text.strip()
            region = requests.get(
                "http://169.254.169.254/opc/v2/instance/canonicalRegionName",
                headers=headers, timeout=2
            ).text.strip()
            instance_name = requests.get(
                "http://169.254.169.254/opc/v2/instance/displayName",
                headers=headers, timeout=2
            ).text.strip()
            agent_unique_id = f"ocid1.instance.{region}.{account_id}.{agent_name}"
        except Exception as e:
            print(f"Error fetching OCI metadata: {e}")

    else:
        raise ValueError("Unknown Cloud Type. Canceled Agent Installation")

    return {
        "agent_unique_id": agent_unique_id,
        "account_id": account_id
    }


def get_server_name(config):
    cloud_type = config.get("CDX_CLOUD_TYPE")
    server_name = config.get("SERVER_NAME")
    if cloud_type == "AWS":
        if requests.get("http://169.254.169.254/latest/meta-data/instance-id").status_code == 200:
            server_name = requests.get("http://169.254.169.254/latest/meta-data/instance-id").text
        else:
            token = requests.put("http://169.254.169.254/latest/api/token", headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"}).text
            headers = {"X-aws-ec2-metadata-token": token}
            if requests.get("http://169.254.169.254/latest/meta-data/instance-id", headers=headers).status_code == 200:
                server_name = requests.get("http://169.254.169.254/latest/meta-data/instance-id", headers=headers).text
    elif cloud_type == "AZURE":
        headers = {"Metadata": "true"}
        server_name = requests.get("http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-08-01&format=text", headers=headers).text
    elif cloud_type == "GCP":
        headers = {"Metadata-Flavor": "Google"}
        server_name = requests.get("http://metadata.google.internal/computeMetadata/v1/instance/id", headers=headers).text
    elif cloud_type == "OCI":
        headers = {"Authorization": "Bearer Oracle"}
        server_name = requests.get("http://169.254.169.254/opc/v2/instance/id", headers=headers, timeout=2).text
    return server_name


def get_token(username, password, server_ip, max_retries=3) -> str:
    for attempt in range(max_retries):
        try:
            # Reference: https://documentation.wazuh.com/4.10/user-manual/api/reference.html#section/Authentication
            url = f"https://{server_ip}:55000/security/user/authenticate?raw=true"
            response = requests.post(url, auth=(username, password), verify=False, timeout=10)
            response.raise_for_status()
            return response.text
        except requests.RequestException as e:
            if attempt == max_retries - 1:
                debug(f"Failed to get token after {max_retries} attempts: {e}")
                return None
            time.sleep(2 ** attempt)
    return None


def get_agents_list(server_ip, token) -> list:
    # Reference: https://documentation.wazuh.com/4.10/user-manual/api/reference.html#tag/Agents/operation/api.controllers.agent_controller.get_agents
    url: str = f"https://{server_ip}:55000/agents"

    params: dict = {
        'status': 'active'
    }

    headers: dict = {
        'Authorization': f'Bearer {token}'
    }

    agent_details: list = []

    try:
        response = requests.get(url, headers=headers, params=params, verify=False)
        response.raise_for_status()
        agents = response.json().get('data', {}).get('affected_items', [])
        for agent in agents:
            agent_info = {
                'agent_name': agent.get('name', ''),
                'agent_id': agent.get('id', ''),
                'ipAddress': agent.get('ip', ''),
                'status': agent.get('status', ''),
                'agent_version': agent.get('version', '')
            }
            if agent.get('id', '') == "000":
                agent_info['agent_name'] = get_server_name(config)

            agent_details.append(agent_info)

        return agent_details
    except requests.RequestException as e:
        debug(f"Error fetching agents list: {str(e)}")
        return []
    except json.JSONDecodeError as e:
        debug(f"Error decoding JSON response: {str(e)}")
        return []
    except Exception as e:
        debug(f"Unexpected error in Get Agents List: {str(e)}")
        return []


def get_agent_config(agent_details: list, server_ip: str, token: str) -> dict:
    agent_workspace_mapping: dict = {}  # Store agent all agents for a account id in same dict

    try:
        for agent in agent_details:
            if agent.get('agent_id') == '000':
                try:
                    server_labels = get_server_unique_id(config)
                    agent['agent_unique_id'] = server_labels.get('agent_unique_id')
                    agent['account_id'] = server_labels.get('account_id')
                    agent.pop('agent_id', None)
                except Exception as e:
                    debug(f"Error fetching server unique ID for agent 000: {str(e)}")
                continue

            try:
                # Reference: https://documentation.wazuh.com/4.10/user-manual/api/reference.html#tag/Agents/operation/api.controllers.agent_controller.get_agent_config
                url: str = f"https://{server_ip}:55000/agents/{agent['agent_id']}/config/agent/labels"

                headers: dict = {
                    'Authorization': f'Bearer {token}'
                }

                debug(f"Request URL: {url}")
                debug(f"Request Headers: {headers}")
                response = requests.get(url=url, headers=headers, verify=False)
                debug(f"Respose Code: {response.status_code}")
                debug(f"Response: {response.text}")
                response.raise_for_status()

                labels = response.json().get('data', {}).get('labels', [])
                # Keys to exclude when copying labels onto the agent object.
                skip_label_keys: set = set()
                # Copy every label into the agent object under its own key.
                for label in labels:
                    key = label.get('key')
                    if not key or key in skip_label_keys:
                        continue
                    agent[key] = label.get('value', '')

                # Seed the workspace bucket if this agent reports a workspace label.
                if agent.get('workspace') and agent.get('workspace') not in agent_workspace_mapping:
                    agent_workspace_mapping[agent.get('workspace')] = []

                if agent.get('workspace') in agent_workspace_mapping:
                    agent_workspace_mapping[agent.get('workspace')].append(agent)
                agent.pop('agent_id', None)
            except Exception as e:
                debug(f"Error fetching config for agent {agent.get('agent_id')}: {e}")
                continue

        return agent_workspace_mapping
    except requests.RequestException as e:
        debug(f"Error fetching agents list: {str(e)}")
        return {}
    except json.JSONDecodeError as e:
        debug(f"Error decoding JSON response: {str(e)}")
        return {}
    except Exception as e:
        debug(f"Unexpected error in Get Agent Config: {str(e)}")
        return {}


def format_agent_data(agent_details: list, wazuh_server_version: str) -> dict:
    """
    Format agent data according to the new payload structure.

    Args:
        agent_details: List of agent details
        wazuh_server_version: Version of Wazuh server from config

    Returns:
        Dictionary with active_agents and failed_agents lists
    """
    active_agents = []
    failed_agents = []

    # Internal/routing keys that must not be forwarded in the payload.
    reserved_keys = {"agent_id", "status", "workspace", "dc", "agent_version"}

    for agent in agent_details:
        account_id = agent.get('account_id', '')
        # Per-agent version from the Wazuh API (e.g. "Wazuh v4.10.0" or
        # "v4.14.5"); take the last token and drop a leading "v" for a bare
        # version, fall back to server version.
        raw_version = agent.get('agent_version') or wazuh_server_version
        agent_version = raw_version.split()[-1].lstrip('v') if raw_version else wazuh_server_version

        # Base agent data: forward every collected label, minus reserved keys.
        agent_data = {k: v for k, v in agent.items() if k not in reserved_keys}
        agent_data.setdefault("agent_name", "")
        agent_data.setdefault("agent_unique_id", "")
        agent_data["account_id"] = account_id
        agent_data["logsUrl"] = ""  # Empty as per requirements

        # Check if agent status is active
        if agent.get('status', '').lower() == 'active':
            # Agent is active - both installations are success
            agent_data.update({
                "wazuhAgentInstallation": "success",
                "cdxManagerAgentInstallation": "success",
                "serverVersion": wazuh_server_version,
                "agentVersion": agent_version
            })
            active_agents.append(agent_data)
        else:
            # Agent is not active - installations failed
            agent_data.update({
                "wazuhAgentInstallation": "failure",
                "cdxManagerAgentInstallation": "failure",
                "errorMessage": f"Agent status is {agent.get('status', 'unknown')}",
                "errorCode": "AGENT_INACTIVE"
            })
            failed_agents.append(agent_data)

    return {
        "active_agents": active_agents,
        "failed_agents": failed_agents
    }


def send_active_agent_data(agent_details, auth_token, wazuh_server_version) -> bool:
    if not agent_details:
        debug("No agents to send, agent_details is empty")
        return False

    agent1: dict = agent_details[0]
    dc: str = agent1.get("dc", "")

    url: str = f"https://incoming-{dc.lower()}.cloudanix.com/inbound/vms/agent-healthcheck"
    if dc == "US":
        url = US_HEALTH_CHECK_URL
    elif dc == "IN":
        url = IN_HEALTH_CHECK_URL
    elif dc == "MC1":
        url = MC1_HEALTH_CHECK_URL

    headers: dict = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': f'Bearer {auth_token}'
    }

    # Format agent data according to new structure
    formatted_data = format_agent_data(agent_details, wazuh_server_version)

    payload: dict = {
        "request": formatted_data
    }

    try:
        debug(f"Active Agent Payload: {payload}")
        debug(f"Active Agent Headers: {headers}")
        response = requests.post(url=url, headers=headers, json=payload, timeout=30)
        debug(f"Active Agent Response: {response.text}")
        response.raise_for_status()
        return True
    except requests.RequestException as e:
        debug(f"Error sending agent data: {str(e)}")
        return False
    except Exception as e:
        debug(f"Unexpected error: {str(e)}")
        return False


pwd: str = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
config_path: str = f"{pwd}/integrations/cloudanix-config.json"
log_file: str = f"{pwd}/logs/agent-sync.log"

config: dict = {}

try:
    with open(config_path, "r") as f:
        config = json.loads(f.read())
        f.close()
except json.JSONDecodeError as e:
    debug(f"Error while reading the config file: {str(e)}")
except FileNotFoundError as e:
    debug(f"Error locating the file on the path: {config_path}. Error: {str(e)}")

debug_enabled: bool = config.get("CDX_DEBUG_ENABLED", False)
SERVER_IP = config.get("WAZUH_SERVER_IP")
SECRET_NAME = config.get("CDX_SECRET_NAME")
US_HEALTH_CHECK_URL = config.get("US_HEALTH_CHECK_URL", "")
IN_HEALTH_CHECK_URL = config.get("IN_HEALTH_CHECK_URL", "")
MC1_HEALTH_CHECK_URL = config.get("MC1_HEALTH_CHECK_URL", "")
AWS_REGION = config.get("AWS_REGION", "us-east-1")
WAZUH_SERVER_VERSION = config.get("WAZUH_SERVER_VERSION", "4.10")

if not all([US_HEALTH_CHECK_URL, IN_HEALTH_CHECK_URL, MC1_HEALTH_CHECK_URL]):
    debug("Missing required configuration values")
    exit(1)

# Create boto3 client for AWS Secrets Manager
secrets_client = boto3.client('secretsmanager', region_name=AWS_REGION)

# Initial load of secrets
if secrets_client:
    get_aws_secret(secrets_client=secrets_client, secret_name=SECRET_NAME)

retry_count: int = 3
token: str = get_token("wazuh-wui", config.get("WAZUH_REST_PASSWORD"), SERVER_IP)

if token:
    agents_details: list = get_agents_list(SERVER_IP, token)
    active_agents_details: dict = get_agent_config(agents_details, SERVER_IP, token)

    for workspace_identifier, agents in active_agents_details.items():
        # Use the new function that handles lazy loading and periodic refresh
        customer_token = get_auth_token_for_workspace(
            secrets_client=secrets_client,
            secret_name=SECRET_NAME,
            workspace=workspace_identifier
        )

        if not customer_token:
            debug(f"Cannot send events: Auth token not found for workspace '{workspace_identifier}' even after refresh attempt.")
            continue

        for attempt in range(retry_count):
            if send_active_agent_data(agents, customer_token, WAZUH_SERVER_VERSION):
                debug(f"Successfully sent agent data for workspace {workspace_identifier}")
                break
            else:
                debug(f"Attempt {attempt + 1} failed to send agent data for workspace {workspace_identifier}. Retrying...")
                time.sleep(5)
        else:
            debug(f"Failed to send agent data for workspace {workspace_identifier} after {retry_count} attempts")
