# Azure JIT VM — Setup

Deploys the Cloudanix JIT proxy for Azure VM access into your subscription.

```
cdx vm connect → az ssh (Entra login) → jump VM → private proxy containers → target VM
```

## What it creates

| Resource | Purpose |
|---|---|
| VNet `10.30.0.0/16` with jump, ACI, and VM subnets | Private network for the proxy |
| NSG on the jump subnet | SSH (22) from `SSH_ALLOWED_CIDRS` only |
| Jump VM (Ubuntu 22.04, Standard_B2s) + public IP | Entra SSH entry point; the only public endpoint |
| 3 private container groups (ACI) | sshpiper (2222), VM proxy (8079), logging |
| Storage account | sshpiper working dir, shared recordings, log blob container |
| Key Vault `*-jitenv-kv` | Runtime config for the containers |
| Key Vault `*-jitkeys-kv` | Target VM SSH private keys |
| User-assigned identity | Runs the containers; read KV, write blobs, pull image |

Ports 2222 and 8079 are never opened on the NSG. The jump VM forwards them to
loopback only.

## Prerequisites

- Azure CLI (`az`) and `jq`, signed in as a **user** (`az login`), with rights
  to create resources and role assignments in the subscription (Owner, or
  Contributor plus User Access Administrator).
- An Azure Container Registry containing the Cloudanix proxy images, tagged with
  an immutable version (not `latest`). Pass its login server and resource ID.
- `CDX_AUTH_TOKEN` and `CDX_SIGNATURE_SECRET_KEY`, provided by Cloudanix.
- Your operator public IP or CIDR, and your Entra object ID:
  `az ad signed-in-user show --query id -o tsv`
- A target VM reachable from the ACI subnet (`10.30.2.0/24`). Either place it in
  the created VM subnet (`10.30.3.0/24`) or peer its VNet.

## Deploy

```bash
export CDX_AUTH_TOKEN='...'                 # not saved to disk
export CDX_SIGNATURE_SECRET_KEY='...'       # not saved to disk
cd azure-jit-vm
./setup.sh
```

The wizard asks for the non-secret values, saves them to `.state.json`, and runs
steps 01–06. It resumes from the last completed step if interrupted. Saved state
contains subscription and resource names only, no secrets.

## Operations

- **Container IPs changed** (a group was recreated): `./refresh-forwarders.sh`
- **Rotate Cloudanix credentials**: export the new values, run `./setup.sh`
  (it skips completed steps), then restart the containers so they reload.
- **Add a target VM**: finish the target setup in the Cloudanix console, then
  store its SSH private key in the keys vault.

## Known limits

- Step 05 does not update an existing container group. Delete it to change its
  image.
- No cleanup command yet. Remove the resource group in the portal or with
  `az group delete`.
