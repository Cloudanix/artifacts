#!/usr/bin/env python3

import requests
import json
import sqlite3
import os
import time


def debug(msg):
    if not debug_enabled:
        return

    now = time.strftime("%a %b %d %H:%M:%S %Z %Y")
    msg = "{0}: {1}\n".format(now, msg)
    print(msg)

    f = open(log_file, "a")
    f.write(msg)
    f.close()


def get_agents_list(server_ip, token):
    url = f"https://{server_ip}:55000/agents"
    params = {
        'select': 'id',
        'status': 'active'
    }
    headers = {
        'Authorization': f'Bearer {token}'
    }
    try:
        response = requests.get(url, params=params, headers=headers, verify=False)
        response.raise_for_status()
        return response.json()['data']['affected_items']
    except (requests.RequestException, IndexError, KeyError):
        debug("Error in fetching agents")
        return []


def insert_agents_in_table(agents, token):
    timestamp = int(time.time())
    with sqlite3.connect(alerts_db) as conn:
        try:
            cursor = conn.cursor()
            for agent in agents:
                if agent.get('id') == "000":
                    continue
                agent_id = agent.get('id')
                # Insert the agent if it doesn't exist yet
                cursor.execute("INSERT OR IGNORE INTO agents (agent_id, agent_added_date, vulns_sync_status) VALUES(?,?,?)", (agent_id, timestamp, False))

                # Fallback: populate workspace_identifier, account_identifier, cloud_type from Wazuh API labels
                # if they are still NULL in the DB
                cursor.execute("SELECT workspace_identifier, account_identifier, cloud_type FROM agents WHERE agent_id=?", (agent_id,))
                row = cursor.fetchone()
                if row and (not row[0] or not row[1] or not row[2]):
                    labels = get_agent_labels(token, agent_id, SERVER_IP)
                    ws = labels.get("workspace", "")
                    acct = labels.get("account_identifier", "")
                    ct = labels.get("cloud_type", "")
                    if ws or acct or ct:
                        cursor.execute(
                            "UPDATE agents SET workspace_identifier=COALESCE(NULLIF(workspace_identifier,''),?), account_identifier=COALESCE(NULLIF(account_identifier,''),?), cloud_type=COALESCE(NULLIF(cloud_type,''),?) WHERE agent_id=?",
                            (ws, acct, ct, agent_id)
                        )
                        debug(f"Backfilled agent {agent_id} labels from API: workspace={ws}, account={acct}, cloud_type={ct}")
        except sqlite3.Error as e:
            debug(f"Database error: {e}")


def get_agent_ip(token, agent_id, server_ip):
    url = f"https://{server_ip}:55000/agents"
    params = {
        'q': f'id={agent_id}',
        'select': 'ip'
    }
    headers = {
        'Authorization': f'Bearer {token}'
    }
    try:
        response = requests.get(url, params=params, headers=headers, verify=False)
        response.raise_for_status()
        return response.json()['data']['affected_items'][0].get("ip", "")
    except (requests.RequestException, IndexError, KeyError):
        debug("Error in fetching agent IP")
        return ""


def get_agent_labels(token, agent_id, server_ip):
    """
    Fetches agent labels including workspace, cloud_type, and account_identifier.
    These labels are needed to route vulnerability alerts to the correct workspace.
    """
    # Reference: https://documentation.wazuh.com/4.10/user-manual/api/reference.html#tag/Agents/operation/api.controllers.agent_controller.get_agent_config
    url = f"https://{server_ip}:55000/agents/{agent_id}/config/agent/labels"

    headers: dict = {
        'Authorization': f'Bearer {token}'
    }
    try:
        response = requests.get(url=url, headers=headers, verify=False)
        response.raise_for_status()

        # Extract labels into a dictionary
        labels_list = response.json().get("data", {}).get("labels", [])
        labels_dict: dict = {}

        for label in labels_list:
            if isinstance(label, dict) and 'key' in label and 'value' in label:
                labels_dict[label['key']] = label['value']

        debug(f"Agent {agent_id} labels: {labels_dict}")

        required_labels = ['workspace', 'cloud_type', 'account_identifier']
        missing_labels = [label for label in required_labels if label not in labels_dict]
        if missing_labels:
            debug(f"WARNING: Agent {agent_id} missing required labels: {missing_labels}")

        return labels_dict

    except (requests.RequestException, IndexError, KeyError) as e:
        debug(f"Error fetching agent labels for {agent_id}: {e}")
        return {}


def get_server_name(config):
    cloud_type = config.get("CDX_CLOUD_TYPE")
    try:
        if cloud_type == "AWS":
            try:
                response = requests.get("http://169.254.169.254/latest/meta-data/instance-id", timeout=2)
                return response.text
            except requests.RequestException:
                token = requests.put("http://169.254.169.254/latest/api/token",
                                    headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"}).text
                headers = {"X-aws-ec2-metadata-token": token}
                response = requests.get("http://169.254.169.254/latest/meta-data/instance-id", headers=headers, timeout=2)
                return response.text
        elif cloud_type == "AZURE":
            headers = {"Metadata": "true"}
            return requests.get("http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-08-01&format=text",
                                headers=headers, timeout=2).text
        elif cloud_type == "GCP":
            headers = {"Metadata-Flavor": "Google"}
            return requests.get("http://metadata.google.internal/computeMetadata/v1/instance/id",
                                headers=headers, timeout=2).text
        elif cloud_type == "OCI":
            headers = {"Authorization": "Bearer Oracle"}
            return requests.get("http://169.254.169.254/opc/v2/instance/id",
                                headers=headers, timeout=2).text
        else:
            return config.get("SERVER_NAME")
    except Exception:
        debug("Error in fetching server name")
        return ""


def get_indexer_endpoint(config):
    """Get the indexer endpoint from config or use default cluster service"""
    indexer_endpoint = config.get("WAZUH_INDEXER_ENDPOINT")
    indexer_port = config.get("WAZUH_INDEXER_PORT", "9200")

    return f"{indexer_endpoint}:{indexer_port}"


def get_token(username, password, server_ip, max_retries=3):
    for attempt in range(max_retries):
        try:
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


def get_agents(alerts_db):
    agent_list = []

    with sqlite3.connect(alerts_db) as conn:
        try:
            cursor = conn.cursor()
            query = "SELECT agent_id, first_vuln_date FROM agents WHERE vulns_sync_status is false"
            cursor.execute(query)

            for row in cursor.fetchall():
                agent_id, first_vuln_date = row

                agent_list.append({
                    "agent_id": agent_id,
                    "first_vuln_date": first_vuln_date
                })
            debug("Agents Fetched from the DB")
        except Exception as e:
            debug(e)

    return agent_list


def count_vulnerabilities(indexer_endpoint, username, password, agent_id, first_vuln_date=None):
    url = f"https://{indexer_endpoint}/wazuh-states-vulnerabilities-*/_count"
    headers = {"Content-Type": "application/json"}

    if first_vuln_date:
        payload = {
            "query": {
                "bool": {
                    "must": [
                        {
                            "match": {
                                "agent.id": agent_id
                            }
                        },
                        {
                            "range": {
                                "vulnerability.detected_at": {
                                    "lt": first_vuln_date
                                }
                            }
                        }
                    ]
                }
            }
        }
    else:
        payload = {
            "query": {
                "match": {
                    "agent.id": agent_id
                }
            }
        }

    try:
        response = requests.get(url, headers=headers, json=payload, auth=(username, password), verify=False, timeout=30)
        response.raise_for_status()
        result = response.json()
        count = result.get('count', 0)
        debug(f"Found {count} vulnerability records for Agent {agent_id}")
        return count
    except (requests.RequestException, ValueError) as e:
        debug(f"Error counting vulnerabilities for Agent {agent_id}: {e}")
        return 0


def get_vulnerabilities_data(server_ip, token, username, password, alerts_db, config):
    agents_list = get_agents(alerts_db)
    vulnerabilities_data = []
    indexer_endpoint = get_indexer_endpoint(config)
    url = f"https://{indexer_endpoint}/wazuh-states-vulnerabilities-*/_search"
    headers = {"Content-Type": "application/json"}

    for agent in agents_list:
        total_vulnerabilities = count_vulnerabilities(indexer_endpoint, username, password, agent.get("agent_id"), agent.get("first_vuln_date"))

        page_size = 5000  # Adjust based on performance needs
        total_pages = (total_vulnerabilities + page_size - 1) // page_size

        payload = {}

        for page in range(0, total_pages):
            try:
                if agent.get("first_vuln_date"):
                    payload = {
                        "size": page_size,
                        "from": page * page_size,
                        "sort": [
                            {"vulnerability.detected_at": "asc"},
                            {"_id": "asc"}
                        ],
                        "query": {
                            "bool": {
                                "must": [
                                    {
                                        "match": {
                                            "agent.id": agent.get("agent_id")
                                        }
                                    },
                                    {
                                        "range": {
                                            "vulnerability.detected_at": {
                                                "lt": agent.get("first_vuln_date")
                                            }
                                        }
                                    }
                                ]
                            }
                        }
                    }
                else:
                    payload = {
                        "size": page_size,
                        "from": page * page_size,
                        "sort": [
                            {"vulnerability.detected_at": "asc"},
                            {"_id": "asc"}
                        ],
                        "query": {
                            "match": {
                                "agent.id": agent.get("agent_id")
                            }
                        }
                    }

                response = requests.get(url, headers=headers, json=payload, auth=(username, password), verify=False, timeout=30)
                response.raise_for_status()
                data = response.json()
                vulnerabilities_data.extend(data.get('hits', {}).get('hits', []))
                debug("Fetched vulnerability data from the inventory")

            except (requests.RequestException, ValueError) as e:
                debug(f"Error processing agent {agent.get('agent_id')}, page {page}: {e}")

    return transform_vulnerabilities_data(vulnerabilities_data, token, config, server_ip)


def transform_vulnerabilities_data(vulnerabilities_data, token, config, server_ip):
    transformed_data = []
    agent_cache = {}  # Cache for agent IPs and labels

    server_name = get_server_name(config)

    for vulnerability in vulnerabilities_data:
        source = vulnerability.get("_source", {})
        agent_id = source.get("agent", {}).get("id", "")

        # Cache agent information (IP and labels) to avoid repeated API calls
        if agent_id not in agent_cache:
            agent_ip = get_agent_ip(token, agent_id, server_ip)
            agent_labels = get_agent_labels(token, agent_id, server_ip)
            agent_cache[agent_id] = {
                "ip": agent_ip,
                "labels": agent_labels
            }

        agent_info = agent_cache[agent_id]

        transformed_vulnerability = {
            "timestamp": vulnerability.get("_source", {}).get("vulnerability", {}).get("detected_at", ""),
            "agent": {
                "id": vulnerability.get("_source", {}).get("agent", {}).get("id", ""),
                "name": vulnerability.get("_source", {}).get("agent", {}).get("name", ""),
                "ip": agent_info["ip"],
                "labels": agent_info["labels"]  # Include labels for workspace routing
            },
            "manager": {
                "name": server_name,
                "ip": server_ip,
                "version": config.get("WAZUH_SERVER_VERSION")
            },
            "decoder": {
                "name": "json"
            },
            "data": {
                "vulnerability": vulnerability.get("_source", {}),
                "score": vulnerability.get("_score", 0)
            },
            "location": "vulnerability-detector",
            "initial_scan": True
        }

        # Validate that we have the required labels
        labels = agent_info["labels"]
        if not labels.get("workspace"):
            debug(f"WARNING: Agent {agent_id} missing 'workspace' label. Vulnerability may not be routed correctly.")
        if not labels.get("cloud_type"):
            debug(f"WARNING: Agent {agent_id} missing 'cloud_type' label. Using 'AWS' as default.")
        if not labels.get("account_identifier"):
            debug(f"WARNING: Agent {agent_id} missing 'account_identifier' label.")

        transformed_data.append(transformed_vulnerability)

    debug(f"Vulnerability data transformed: {len(transformed_data)} vulnerabilities")

    return transformed_data


def load_vulnerabilities_data(vulnerabilities_data, alerts_db):
    try:
        conn = sqlite3.connect(alerts_db)
        cursor = conn.cursor()

        try:
            timestamp = int(time.time())
            unique_agents = set()

            # Start a transaction
            conn.execute('BEGIN')

            for entry in vulnerabilities_data:
                agent_id = entry.get("agent", {}).get("id", "")

                if agent_id and agent_id not in unique_agents:
                    # Mark agent as synced
                    cursor.execute('''UPDATE agents SET vulns_sync_date=?, vulns_sync_status=? WHERE agent_id=? AND vulns_sync_status = false''', (timestamp, True, agent_id))
                    unique_agents.add(agent_id)

                entry_json = json.dumps(entry)
                debug(f"Storing vulnerability for agent {agent_id}")

                # Insert into vulnerability_alerts with agent_id instead of account details
                cursor.execute('''INSERT INTO vulnerability_alerts (event, agent_id, timestamp) VALUES(?, ?, ?)''', (entry_json, agent_id, timestamp))

            conn.commit()
            debug(f"Vulnerability data stored in the DB: {len(vulnerabilities_data)} records")

        except sqlite3.Error as e:
            conn.rollback()
            debug(f"Database error: {e}")

        finally:
            conn.close()

    except sqlite3.OperationalError as e:
        debug(f"Could not connect to database: {e}")


pwd = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
alerts_db = f"{pwd}/integrations/cloudanix-alerts.db"
config_path = f"{pwd}/integrations/cloudanix-config.json"
log_file = f"{pwd}/logs/fetch-inventory.log"

config = {}

with open(config_path, "r") as config_file:
    config = json.loads(config_file.read())
    config_file.close()

debug_enabled = config.get("CDX_DEBUG_ENABLED", False)
SERVER_IP = config.get("WAZUH_SERVER_IP")

token = get_token("wazuh-wui", config.get("WAZUH_REST_PASSWORD"), SERVER_IP)
if token:
    # add agents in agents table if not added by event
    total_agents = get_agents_list(SERVER_IP, token)
    insert_agents_in_table(total_agents, token)

    vulnerabilities_data = get_vulnerabilities_data(SERVER_IP, token, config.get("WAZUH_USERNAME"), config.get("WAZUH_PASSWORD"), alerts_db, config)
    load_vulnerabilities_data(vulnerabilities_data, alerts_db)
    debug("Vulnerability data stored successfully.")
