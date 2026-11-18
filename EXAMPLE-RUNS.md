# Example Run Scenarios

This document shows how the orchestrator looks during different run scenarios.

---

## 1. Fresh Setup — AWS JIT Database (New VPC)

```
$ cd aws-jit-db && ./setup.sh

╔══════════════════════════════════════════════════════════════════╗
║            AWS JIT Database Setup                               ║
╚══════════════════════════════════════════════════════════════════╝

[08:30:01] [OK] All prerequisites available: aws jq docker

Select deployment scope:

  1) New VPC (cross-account DB with VPC peering)
  2) Existing VPC (cross-account DB, first setup)
  3) Existing VPC (same-account DB or additional setup)

Select option [1-3]: 1

[08:30:05] [INFO] Scope mode: new-vpc

[08:30:05] [STEP] ━━━ Configuration ━━━

[08:30:05] [INFO] Please provide the following values. Press Enter to accept defaults.

AWS Region [us-east-1]: us-east-1
JIT Workload Account ID []: 123456789012
Database Account ID []: 987654321098
Management Account ID (SSO) []: 111222333444
SSO Instance ARN [arn:aws:sso:::instance/ssoins-722367552337aabd]:
Project Name [cdx-jit-db]:
ECS Cluster Name [cdx-jit-db-cluster]:
Image Tag [latest]:
Enable Database Activity Monitoring (DAM) [false]: true
VPC CIDR Block [10.50.0.0/16]:
S3 Bucket Name (for query logs) [cdx-jit-db-logs]: cdx-jit-db-logs-acme
Secrets Manager Secret Name [CDX_SECRETS]:
CDX Auth Token []: eyJhbG...
CDX Signature Secret Key []: sk_live_...
CDX Sentry DSN [CDX_SENTRY_DSN]:
CDX Data Center (US/EU) [US]:
CDX API Base URL [https://console.cloudanix.com]:
Database VPC ID []: vpc-0abc123
Database VPC CIDR []: 10.0.0.0/16
RDS Security Group IDs (comma-separated) []: sg-0def456
SSO Permission Set Name [cdx-EcsSsmAccess]:

[08:31:20] [STEP] ━━━ Configuration Summary ━━━

  AWS Region: us-east-1
  JIT Workload Account ID: 123456789012
  Database Account ID: 987654321098
  Management Account ID (SSO): 111222333444
  SSO Instance ARN: arn:aws:sso:::instance/ssoins-722367552337aabd
  Project Name: cdx-jit-db
  ECS Cluster Name: cdx-jit-db-cluster
  Image Tag: latest
  Enable Database Activity Monitoring (DAM): true
  VPC CIDR Block: 10.50.0.0/16
  S3 Bucket Name: cdx-jit-db-logs-acme
  Secrets Manager Secret Name: CDX_SECRETS
  CDX Auth Token: ****************hbG...
  CDX Signature Secret Key: ****************ve_...
  CDX Sentry DSN: CDX_SENTRY_DSN
  CDX Data Center: US
  CDX API Base URL: https://console.cloudanix.com
  Database VPC ID: vpc-0abc123
  Database VPC CIDR: 10.0.0.0/16
  RDS Security Group IDs: sg-0def456
  SSO Permission Set Name: cdx-EcsSsmAccess

Proceed with these values? (y/n) [y]: y

[08:31:22] [STEP] ━━━ Executing Setup Steps ━━━

[08:31:22] [INFO] Total steps: 8

╔══════════════════════════════════════════════════════════════════╗
║  ⚠  ACCOUNT SWITCH REQUIRED                                     ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Switch to: JIT Workload Account                                 ║
║  Account:   123456789012                                         ║
║  Next step: Sync ECR Images                                      ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

Have you switched to the correct account? (y/n) [y]: y
[08:31:30] [OK] Account verified: 123456789012

[Step 1/8] (12%) Sync ECR Images
────────────────────────────────────────────────────────────
[08:31:31] [INFO] Source ECR: 774118602354 (us-east-2)
[08:31:31] [INFO] Target ECR: 123456789012 (us-east-1)
[08:31:32] [OK]   Repository exists: cloudanix/ecr-aws-jit-proxy-sql
[08:31:33] [INFO]   Pulling...
[08:31:45] [INFO]   Pushing to target...
[08:31:58] [OK]   Synced: cloudanix/ecr-aws-jit-proxy-sql
[08:31:59] [OK]   Repository created: cloudanix/ecr-aws-jit-query-logging
...
[08:33:10] [OK] All repositories synced successfully
[08:33:10] [OK] Sync ECR Images — complete

[Step 2/8] (25%) Install Workloads (New VPC)
────────────────────────────────────────────────────────────
[08:33:11] [STEP] ━━━ VPC ━━━
[08:33:12] [OK] VPC created: vpc-0fff999
[08:33:12] [STEP] ━━━ Subnets ━━━
[08:33:14] [OK] Subnets ready
[08:33:15] [STEP] ━━━ NAT Gateway ━━━
[08:33:15] [INFO] Waiting for NAT Gateway...
[08:34:00] [OK] NAT created: nat-0abc111
...
[08:36:30] [OK] Install Workloads (New VPC) — complete

[Step 3/8] (37%) Create VPC Peering Request
────────────────────────────────────────────────────────────
[08:36:31] [OK] Peering created: pcx-0abc123
[08:36:31] [INFO] Cross-account peering — accept in DB account
[08:36:32] [OK] Routes updated for DB CIDR: 10.0.0.0/16
[08:36:32] [OK] Create VPC Peering Request — complete

╔══════════════════════════════════════════════════════════════════╗
║  ⚠  ACCOUNT SWITCH REQUIRED                                     ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Switch to: Database/RDS Account                                 ║
║  Account:   987654321098                                         ║
║  Next step: Accept VPC Peering (DB Account)                      ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

Have you switched to the correct account? (y/n) [y]: y
[08:37:10] [OK] Account verified: 987654321098

[Step 4/8] (50%) Accept VPC Peering (DB Account)
────────────────────────────────────────────────────────────
[08:37:11] [INFO] Accepting peering: pcx-0abc123
[08:37:15] [OK] Peering accepted and active
[08:37:16] [OK] Routes updated: 10.50.0.0/16 → pcx-0abc123
[08:37:17] [OK] RDS SGs: allowed MySQL(3306) + PostgreSQL(5432)
[08:37:17] [OK] Accept VPC Peering (DB Account) — complete

[Step 5/8] (62%) Extend Role Permissions (DB Account)
────────────────────────────────────────────────────────────
[08:37:18] [OK] Cross-account role found: cdx-us-east-1-...-role_cross_accnt...
[08:37:19] [OK] RDS permissions policy attached
[08:37:19] [OK] Extend Role Permissions (DB Account) — complete

[Step 6/8] (75%) Extend Role Trust Policy (DB Account)
────────────────────────────────────────────────────────────
[08:37:20] [OK] Trust policy updated with ECS task role
[08:37:20] [OK] Extend Role Trust Policy (DB Account) — complete

╔══════════════════════════════════════════════════════════════════╗
║  ⚠  ACCOUNT SWITCH REQUIRED                                     ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Switch to: JIT Workload Account                                 ║
║  Account:   123456789012                                         ║
║  Next step: Update ECS Assume Role Policy                        ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

Have you switched to the correct account? (y/n) [y]: y
[08:38:00] [OK] Account verified: 123456789012

[Step 7/8] (87%) Update ECS Assume Role Policy
────────────────────────────────────────────────────────────
[08:38:01] [OK] Assume role policy updated
[08:38:01] [OK] Update ECS Assume Role Policy — complete

╔══════════════════════════════════════════════════════════════════╗
║  ⚠  ACCOUNT SWITCH REQUIRED                                     ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Switch to: Management Account (SSO)                             ║
║  Account:   111222333444                                         ║
║  Next step: Create SSO Permission Set                            ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

Have you switched to the correct account? (y/n) [y]: y
[08:38:30] [OK] Account verified: 111222333444

[Step 8/8] (100%) Create SSO Permission Set
────────────────────────────────────────────────────────────
[08:38:31] [OK] Permission set created: cdx-EcsSsmAccess
[08:38:32] [OK] Inline policy attached
[08:38:32] [OK] Create SSO Permission Set — complete

╔══════════════════════════════════════════════════════════════════╗
║  ✅  Setup Complete!                                             ║
╚══════════════════════════════════════════════════════════════════╝

  Setup Type: AWS JIT Database
  Scope Mode: new-vpc

  Steps completed:
    ✓ Sync ECR Images
    ✓ Install Workloads (New VPC)
    ✓ Create VPC Peering Request
    ✓ Accept VPC Peering (DB Account)
    ✓ Extend Role Permissions (DB Account)
    ✓ Extend Role Trust Policy (DB Account)
    ✓ Update ECS Assume Role Policy
    ✓ Create SSO Permission Set

  To tear down: ./setup.sh --cleanup
```

---

## 2. Resuming After Interruption

```
$ cd aws-jit-db && ./setup.sh

╔══════════════════════════════════════════════════════════════════╗
║            AWS JIT Database Setup                               ║
╚══════════════════════════════════════════════════════════════════╝

[09:00:01] [OK] All prerequisites available: aws jq docker

[09:00:01] [INFO] Found existing setup state (scope: New VPC (cross-account DB with VPC peering))

Resume from where you left off? (y/n) [y]: y

[09:00:03] [STEP] ━━━ Executing Setup Steps ━━━

[09:00:03] [INFO] Total steps: 8
[09:00:03] [INFO] [Step 1/8] Sync ECR Images — already complete, skipping
[09:00:03] [INFO] [Step 2/8] Install Workloads (New VPC) — already complete, skipping
[09:00:03] [INFO] [Step 3/8] Create VPC Peering Request — already complete, skipping

╔══════════════════════════════════════════════════════════════════╗
║  ⚠  ACCOUNT SWITCH REQUIRED                                     ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Switch to: Database/RDS Account                                 ║
║  Account:   987654321098                                         ║
║  Next step: Accept VPC Peering (DB Account)                      ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

Have you switched to the correct account? (y/n) [y]: y
[09:00:15] [OK] Account verified: 987654321098

[Step 4/8] (50%) Accept VPC Peering (DB Account)
────────────────────────────────────────────────────────────
...continues from step 4...
```

---

## 3. Account Mismatch Detection

```
╔══════════════════════════════════════════════════════════════════╗
║  ⚠  ACCOUNT SWITCH REQUIRED                                     ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Switch to: Database/RDS Account                                 ║
║  Account:   987654321098                                         ║
║  Next step: Accept VPC Peering (DB Account)                      ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

Have you switched to the correct account? (y/n) [y]: y
[09:05:10] [ERROR] Account mismatch!
[09:05:10] [ERROR]   Expected: 987654321098
[09:05:10] [ERROR]   Actual:   123456789012
[09:05:10] [WARN] Please switch to the correct account and re-run.
```

---

## 4. Step Failure and Recovery

```
[Step 2/8] (25%) Install Workloads (New VPC)
────────────────────────────────────────────────────────────
[08:33:11] [STEP] ━━━ VPC ━━━
[08:33:12] [OK] VPC created: vpc-0fff999
[08:33:12] [STEP] ━━━ NAT Gateway ━━━
[08:33:12] [ERROR] Script failed at line 142 with exit code 1
[08:33:12] [ERROR] Step 'Install Workloads (New VPC)' failed with exit code 1
[08:33:12] [ERROR] Progress has been saved. Re-run to resume from this step.
```

When you re-run:
```
$ ./setup.sh

[09:00:01] [INFO] Found existing setup state (scope: New VPC ...)
Resume from where you left off? (y/n) [y]: y

[09:00:03] [INFO] [Step 1/8] Sync ECR Images — already complete, skipping

[Step 2/8] (25%) Install Workloads (New VPC)
────────────────────────────────────────────────────────────
[09:00:04] [STEP] ━━━ VPC ━━━
[09:00:05] [OK] VPC exists: vpc-0fff999       ← idempotent! reuses existing
[09:00:06] [STEP] ━━━ NAT Gateway ━━━
[09:00:07] [OK] NAT created: nat-0abc111      ← creates what was missing
...continues successfully...
```

---

## 5. Cleanup Mode

```
$ cd aws-jit-db && ./setup.sh --cleanup

=== Cleanup: AWS JIT Database ===

The following steps were completed:

  ✓ Sync ECR Images (JIT Workload Account)
  ✓ Install Workloads (New VPC) (JIT Workload Account)
  ✓ Create VPC Peering Request (JIT Workload Account)
  ✓ Accept VPC Peering (DB Account) (Database/RDS Account)
  ✓ Extend Role Permissions (DB Account) (Database/RDS Account)
  ✓ Extend Role Trust Policy (DB Account) (Database/RDS Account)
  ✓ Update ECS Assume Role Policy (JIT Workload Account)
  ✓ Create SSO Permission Set (Management Account (SSO))

Proceed with cleanup? This will remove all created resources (y/n) [n]: y
...cleanup executes in reverse order...
```

---

## 6. AWS JIT VM Setup (shorter flow)

```
$ cd aws-jit-vm && ./setup.sh

╔══════════════════════════════════════════════════════════════════╗
║            AWS JIT VM (SSH Proxy) Setup                         ║
╚══════════════════════════════════════════════════════════════════╝

[10:00:01] [OK] All prerequisites available: aws jq docker

Select deployment scope:

  1) New VPC (cross-account VM with VPC peering)
  2) Existing VPC (VM in same or peered network)

Select option [1-2]: 1
...follows same pattern with 6 steps...
```

---

## 7. AWS JIT EKS Setup

```
$ cd aws-jit-eks && ./setup.sh

╔══════════════════════════════════════════════════════════════════╗
║            AWS JIT EKS (Kubernetes) Setup                      ║
╚══════════════════════════════════════════════════════════════════╝

[11:00:01] [OK] All prerequisites available: aws jq

Select deployment scope:

  1) New VPC (bastion hub with VPC peering to EKS)
  2) Existing VPC (bastion in existing network)

Select option [1-2]: 1
...follows same pattern with 5 steps...
```

---

## State File Example (.state.json after partial run)

```json
{
  "version": 1,
  "setup_type": "aws-jit-db",
  "scope_mode": "new-vpc",
  "started_at": "2026-08-18T08:30:05Z",
  "config": {
    "AWS_REGION": "us-east-1",
    "JIT_ACCOUNT_ID": "123456789012",
    "DB_ACCOUNT_ID": "987654321098",
    "MGMT_ACCOUNT_ID": "111222333444",
    "PROJECT_NAME": "cdx-jit-db",
    "VPC_CIDR": "10.50.0.0/16",
    "IMAGE_TAG": "latest",
    "ENABLE_DAM": "true",
    "BUCKET_NAME": "cdx-jit-db-logs-acme",
    "CDX_AUTH_TOKEN": "eyJhbG...",
    "CDX_SIGNATURE_SECRET_KEY": "sk_live_..."
  },
  "steps": {
    "01-sync-ecr": {
      "status": "complete",
      "completed_at": "2026-08-18T08:33:10Z",
      "outputs": {
        "ECR_SYNCED": "true",
        "TARGET_ECR_PREFIX": "123456789012.dkr.ecr.us-east-1.amazonaws.com"
      }
    },
    "02-install-workloads-new-vpc": {
      "status": "complete",
      "completed_at": "2026-08-18T08:36:30Z",
      "outputs": {
        "VPC_ID": "vpc-0fff999",
        "ECS_CLUSTER_ARN": "arn:aws:ecs:us-east-1:123456789012:cluster/cdx-jit-db-cluster",
        "ECS_SG_ID": "sg-0aaa111",
        "EFS_ID": "fs-0bbb222",
        "SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:CDX_SECRETS-AbCdEf",
        "PRIVATE_SUBNET_1_ID": "subnet-0ccc333",
        "PRIVATE_SUBNET_2_ID": "subnet-0ddd444"
      }
    },
    "03-setup-vpc-peering": {
      "status": "complete",
      "completed_at": "2026-08-18T08:36:32Z",
      "outputs": {
        "PEERING_CONNECTION_ID": "pcx-0abc123"
      }
    }
  }
}
```
