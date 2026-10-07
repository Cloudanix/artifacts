#!/usr/bin/env python3
"""Upload finished per-minute Wazuh archive files to S3, then delete them locally.

rsyslog (see 60-wazuh-archives.conf) tails /var/ossec/logs/archives/archives.json
and writes each event into <spool>/<date>/<hour>/<minute>.json. This script runs
once a minute from the worker crontab and ships any file that has stopped being
written to.

Credentials come from IRSA. Under cron the environment is stripped, so this is
invoked through /var/ossec/etc/cloudanix-cron-run.sh, which re-exports the AWS_*
variables first.

Placeholders below are substituted by wazuh/apply.sh --s3.
"""

import fcntl
import os
import socket
import sys
import time
from datetime import datetime, timezone

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:
    print("No module 'boto3' found. Install: pip install boto3")
    sys.exit(1)

BUCKET = "__S3_BUCKET__"
KEY_PREFIX = "__S3_PREFIX__"
REGION = "__AWS_REGION__"
SPOOL_DIR = "__SPOOL_DIR__"

# A file is "finished" once rsyslog has not touched it for this long. The minute
# boundary alone is not enough: rsyslog flushes on a timer and can still append
# to the previous minute's file for a few seconds after the clock rolls over.
MIN_AGE_SECONDS = 120

# Empty date/hour directories are pruned once they are older than this.
EMPTY_DIR_AGE_SECONDS = 300

LOCK_PATH = os.path.join(SPOOL_DIR, ".upload.lock")
LOG_PATH = "/var/ossec/logs/cloudanix-s3-archive.log"
LOG_MAX_BYTES = 10 * 1024 * 1024


def log(message):
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    line = "{} {}\n".format(stamp, message)
    sys.stdout.write(line)
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
            with open(LOG_PATH, "w"):
                pass
        with open(LOG_PATH, "a") as handle:
            handle.write(line)
    except OSError:
        pass


def acquire_lock():
    """Single-instance guard: a slow upload must not overlap the next cron tick."""
    handle = open(LOCK_PATH, "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def finished_files(now):
    for root, _dirs, files in os.walk(SPOOL_DIR):
        for name in sorted(files):
            if not name.endswith(".json"):
                continue
            path = os.path.join(root, name)
            try:
                if now - os.path.getmtime(path) >= MIN_AGE_SECONDS:
                    yield path
            except OSError:
                continue


def prune_empty_dirs(now):
    for root, dirs, files in os.walk(SPOOL_DIR, topdown=False):
        if root == SPOOL_DIR or dirs or files:
            continue
        try:
            if now - os.path.getmtime(root) >= EMPTY_DIR_AGE_SECONDS:
                os.rmdir(root)
        except OSError:
            continue


def main():
    if not os.path.isdir(SPOOL_DIR):
        return 0

    lock = acquire_lock()
    if lock is None:
        log("previous run still in progress, skipping")
        return 0

    # Pod name keeps workers from overwriting each other: every replica produces
    # the same <date>/<hour>/<minute>.json path.
    source = socket.gethostname()
    client = boto3.client("s3", region_name=REGION)

    now = time.time()
    uploaded = 0
    failed = 0

    for path in finished_files(now):
        relative = os.path.relpath(path, SPOOL_DIR)
        key = "{}/{}/{}".format(KEY_PREFIX, source, relative)
        try:
            client.upload_file(
                path,
                BUCKET,
                key,
                ExtraArgs={"ContentType": "application/x-ndjson"},
            )
        except (BotoCoreError, ClientError) as exc:
            # Leave the file in place; the next run retries it.
            failed += 1
            log("ERROR upload failed for {}: {}".format(relative, exc))
            continue
        try:
            os.remove(path)
        except OSError as exc:
            log("ERROR could not remove {} after upload: {}".format(relative, exc))
        uploaded += 1

    prune_empty_dirs(now)

    if uploaded or failed:
        log("uploaded={} failed={} bucket={} prefix={}/{}".format(
            uploaded, failed, BUCKET, KEY_PREFIX, source))

    lock.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
