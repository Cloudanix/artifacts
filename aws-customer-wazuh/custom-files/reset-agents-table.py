#!/usr/bin/env python3
import json
import time
import os
import sqlite3


def debug(msg):
    if not debug_enabled:
        return

    now = time.strftime("%a %b %d %H:%M:%S %Z %Y")
    msg = "{0}: {1}\n".format(now, msg)
    print(msg)

    f = open(log_file, "a")
    f.write(msg)
    f.close()


def reset_agents_table():
    with sqlite3.connect(alerts_db) as conn:
        try:
            cursor = conn.cursor()
            query = "DELETE FROM agents"
            cursor.execute(query)
            debug("Agents Deleted from the DB")
        except Exception as e:
            debug(e)


pwd = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
alerts_db = f"{pwd}/integrations/cloudanix-alerts.db"
config_path = f"{pwd}/integrations/cloudanix-config.json"
log_file = f"{pwd}/logs/reset-agents-table.log"

config = {}

with open(config_path, "r") as config_file:
    config = json.loads(config_file.read())
    config_file.close()

debug_enabled = config.get("CDX_DEBUG_ENABLED", False)

reset_agents_table()
