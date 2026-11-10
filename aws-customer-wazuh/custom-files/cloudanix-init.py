import json
import sqlite3
import sys


def create_table():
    database_file = "/var/ossec/integrations/cloudanix-alerts.db"

    # Connect to the SQLite database, create table, and close connection
    with sqlite3.connect(database_file) as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS vulnerability_alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT, agent_id TEXT, timestamp INTEGER);")
        conn.execute("CREATE TABLE IF NOT EXISTS agents (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_id TEXT UNIQUE, workspace_identifier TEXT, account_identifier TEXT, cloud_type TEXT, agent_added_date INTEGER, first_vuln_date TEXT, vulns_sync_date INTEGER, vulns_sync_status BOOLEAN);")

        # Migration: add columns if they don't exist yet (for existing DBs)
        existing_columns = [row[1] for row in conn.execute("PRAGMA table_info(agents)").fetchall()]
        if "workspace_identifier" not in existing_columns:
            conn.execute("ALTER TABLE agents ADD COLUMN workspace_identifier TEXT;")
        if "account_identifier" not in existing_columns:
            conn.execute("ALTER TABLE agents ADD COLUMN account_identifier TEXT;")
        if "cloud_type" not in existing_columns:
            conn.execute("ALTER TABLE agents ADD COLUMN cloud_type TEXT;")

    print('Table Created Successfully!')


def store_wazuh_password(pwd):
    config_file = "/var/ossec/integrations/cloudanix-config.json"

    # Read JSON file
    with open(config_file) as file:
        data = json.load(file)

    # Add the extracted value as a key-value pair
    data['WAZUH_REST_PASSWORD'] = pwd

    # Write the updated data back to the JSON file
    with open(config_file, 'w') as file:
        json.dump(data, file, indent=4)

    print('Config updated Successfully!')


if __name__ == "__main__":
    create_table()

    store_wazuh_password(sys.argv[1])
