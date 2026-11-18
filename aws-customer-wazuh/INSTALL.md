# Cloudanix AWS Wazuh installer

Use the public `aws-customer-wazuh/install.sh` bootstrap from AWS CloudShell or a
Linux/macOS admin machine.

```bash
curl -fsSLO https://raw.githubusercontent.com/Cloudanix/artifacts/main/aws-customer-wazuh/install.sh
bash install.sh
```

The installer downloads the playbook into `~/.cloudanix/aws-customer-wazuh`, verifies
prerequisites, confirms the active AWS account, writes customer parameters with
mode `0600`, generates unique TLS certificates locally, and deploys the EKS
infrastructure and Wazuh workloads.

Use `CDX_DOWNLOAD_ONLY=true` to download without deploying. Run
`~/.cloudanix/aws-customer-wazuh/setup.sh --help` for non-interactive environment
variables and other options.

Archive forwarding is opt-in through `CDX_FORWARD_TARGET` and
`CDX_FORWARD_PORT`, or through the interactive prompt.

## Public artifact safety

- Customer `parameters.json` is neither distributed nor committed.
- TLS private keys are generated locally and never distributed.
- Forwarding destinations are generated locally and never committed.
- Upstream Wazuh manifests contain placeholder Wazuh/indexer/dashboard
  credentials. Rotate them before production exposure.
