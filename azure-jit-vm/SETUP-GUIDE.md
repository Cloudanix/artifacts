# Azure JIT VM

Temporary, recorded SSH sessions to private Azure VMs. Cloudanix deploys a jump VM and three private proxy containers in a dedicated hub VNet in your subscription. Your team connects with `cdx vm connect`. The CLI opens an Entra-authenticated SSH tunnel to the jump VM. The jump VM forwards only on loopback to the private proxy, which reaches the target VM. No standing SSH keys on laptops, and no inbound ports except SSH (22) from the operator CIDRs you name.

This page matches what `azure-jit-vm/setup.sh` does today.

## Choose your scenario

| Scenario | Menu option | Steps |
| --- | --- | --- |
| First hub. New VNet `10.30.0.0/16`, jump VM, private proxy, peer to the target VNet | **1. New VNet** | 01 through 10 |
| Proxy in a VNet you already have. You name the VNet and the jump and ACI subnets | **2. Existing VNet** | 01-existing, 02–06, 09, 10 |
| Hub exists and the target VNet is already peered. Allow SSH and store the key | **3. Onboard already-peered** | 09, 10 |
| Hub exists. Peer a new target VNet, allow SSH, store the key | **4. Onboard new VNet** | 07, 08, 09, 10 |

New VNet addresses: jump `10.30.1.0/24`, proxy `10.30.2.0/24`, spare `10.30.3.0/24`. That range must not overlap the target VNet.

Use the same `NAME_PREFIX` for options 3 and 4 as the hub install. Those options do not create a hub.

Test order: option 1 first. Then option 4 against a second target VNet, then option 3 against a VNet that is already peered. Option 2 needs its own VNet with a subnet that can be delegated to Container Instances. Do not point option 2 at the production hub.

## Install and run

From a machine where `az login` is already a **user** (not a service principal), in the artifacts repo:

```bash
export CDX_AUTH_TOKEN='...'
export CDX_SIGNATURE_SECRET_KEY='...'
cd azure-jit-vm
./setup.sh
```

Those two exports are the only Cloudanix secrets. They stay in the shell. They are not written to `.state.json`.

The one-line installer (`install.sh`) does not offer `azure-jit-vm` yet. There is no `--share` and no `--cleanup`.

If a step fails, fix the cause and run `./setup.sh` again. It asks whether to resume and skips completed steps.

## What the wizard asks

Press Enter to take the default. Then it prints a summary and asks you to confirm.

| Prompt | Default | Notes |
| --- | --- | --- |
| Azure Subscription ID | (none) | GUID. The script runs `az account set` to this subscription. |
| Azure Region | `eastus2` | |
| Resource name prefix | `cdxjit` | 3–12 characters, lowercase letter then letters or digits. Becomes every resource name. |
| Operator IP CIDR(s) | (none) | Comma-separated. SSH (22) on the jump VM is allowed only from these. `0.0.0.0/0` is rejected. |
| Entra object ID of the operator | (none) | This identity gets Virtual Machine User Login on the jump VM. `az ad signed-in-user show --query id -o tsv` |
| Jump VM admin username | `azureuser` | Break-glass local admin. Day-to-day access is Entra SSH, not this user. |
| Break-glass SSH public key file | `~/.ssh/id_ed25519.pub` | File must exist on the machine running the script. |
| Registry login server | (none) | Example: `example.azurecr.io`. Images must already be in this registry. |
| Registry resource ID | (none) | The proxy identity gets AcrPull on this ID only. |
| Image tag | (none) | Immutable tag. `latest` is rejected. |
| sshpiper image path | `cloudanix/jit-vm-sshpiper` | Path inside the registry. |
| VM proxy image path | `cloudanix/jit-vm-proxyserver` | |
| Logging image path | `cloudanix/jit-vm-logging` | |
| Cloudanix API base URL | `https://api.cloudanix.com` | |
| Cloudanix data center | `US` | `US`, `IN`, or `MC1`. |
| Blob container for recordings | `jit-vm-logs` | |

`CDX_AUTH_TOKEN` and `CDX_SIGNATURE_SECRET_KEY` are not prompts. Export them before `./setup.sh`.

## Steps it runs

All six steps use the same subscription. The script checks you are in that subscription before the first step.

### 1. Network and Jump VM

- Resource group `{prefix}-jit-vm-rg`
- VNet `{prefix}-jit-vm-vnet` (`10.30.0.0/16`)
- Subnets: jump, ACI (delegated to Container Instances), VM
- NSG on the jump subnet: TCP 22 from your CIDRs only. Ports 2222 and 8079 are not opened.
- Standard public IP and Ubuntu 22.04 jump VM (`Standard_B2s`). The jump VM is tagged `owner=cloudanix`, `service=jump-box`, `purpose=cdx-jit-vm`. Every resource this setup creates also gets `asset-owner=Cloudanix`, `asset-service=CloudSecurity`, and `asset-purpose=Security-Monitoring`. A VNet, subnet, or NSG you already owned is not retagged.
- Entra SSH login extension (`AADSSHLoginForLinux`)
- Your operator object ID gets **Virtual Machine User Login** on the jump VM and **Reader** on the resource group

### 2. Storage and Key Vaults

- Storage account `{prefix}jitvmstore` (TLS 1.2, no public blob access)
- File shares `sshpiper-workingdir` and `sshpiper-recordings` (50 GiB each)
- Blob container for recordings
- Two Key Vaults, RBAC mode: `{prefix}-jitenv-kv` (runtime config) and `{prefix}-jitkeys-kv` (target SSH private keys)
- You (the signed-in user) get **Key Vault Secrets Officer** on both vaults

### 3. Managed identity and roles

User-assigned identity `{prefix}-jit-identity`, used by all three containers:

- **Key Vault Secrets User** on both vaults
- **Storage Blob Data Contributor** on the storage account
- **AcrPull** on the registry resource ID you gave

### 4. Runtime configuration

Writes these into the environment Key Vault. Containers read them at startup.

| Secret name | Value |
| --- | --- |
| `CDX-APP-ENV` | `PRODUCTION` |
| `CDX-LOG-LEVEL` | `INFO` |
| `CDX-DC` | your data center |
| `CDX-API-BASE` | your API base URL |
| `CDX-AUTH-TOKEN` | from the environment |
| `CDX-SIGNATURE-SECRET-KEY` | from the environment |
| `CDX-SENTRY-DSN` | `none` |
| `CDX-PROXY-SERVER-VERSION` | image tag |
| `CDX-LOG-MANAGER-VERSION` | image tag |
| `CDX-LOGGING-AZURE-CONTAINER` | blob container name |
| `AZURE-STORAGE-ACCOUNT-URL` | `https://{storage}.blob.core.windows.net/` |

The script is `steps/04-runtime-config.sh`. It fails closed if the two exports are missing.

### 5. Private proxy containers

Three container groups, private IP only, on the ACI subnet. The registry is pulled with the managed identity (no registry password).

| Group | Image | Port | Mounts |
| --- | --- | --- | --- |
| `{prefix}-jit-sshpiper` | sshpiper | 2222 | recordings + working dir |
| `{prefix}-jit-vmproxy` | VM proxy | 8079 | recordings + working dir |
| `{prefix}-jit-logging` | logging | 8079 | recordings |

An existing group is left as-is. To change the image, delete that group and re-run. Its private IP will change, so also run step 6.

### 6. Jump VM loopback forwarders

On the jump VM, two systemd services:

- `127.0.0.1:2222` → sshpiper private IP `:2222`
- `127.0.0.1:8079` → VM proxy private IP `:8079`

Both bind to loopback. The public IP still exposes only port 22. The script checks both local ports before it reports success.

Then it prints the resource group, jump VM name, public IP, both Key Vault names, and the recordings URL.

## After setup

1. In the Cloudanix console, add the Azure VM target (subscription, region, resource group, VM name, OS user).
2. Put that VM's SSH private key in `{prefix}-jitkeys-kv`. The wizard does not ask for the target key.
3. The target must accept SSH from `10.30.2.0/24`, or you peer its VNet to the hub and allow the proxy subnet.
4. Connect: `cdx vm connect`.

If you replace a container group, private IPs change. From the same directory:

```bash
./refresh-forwarders.sh
```

To rotate the Cloudanix token or signature key, export the new values and re-run `./setup.sh` so step 4 writes new secret versions, then restart the VM-proxy and logging container groups. They read Key Vault only at startup.

There is no teardown command. Deleting `{prefix}-jit-vm-rg` removes the resources this setup creates. It does not delete your registry or your target VM.

## How to test

Do not use a production subscription. The address plan and names are created for real, and there is no cleanup script.

**Already done (no Azure calls).** Every script passes `bash -n`. `make lint` includes this package. The wizard was driven with a fake `az` that records calls and does not talk to Azure: steps 1, 2, 3, 5, and 6 completed, `.state.json` stored the 16 non-secret answers, and the three container definitions had private IPs, the right ports, and the right mounts. Step 4 was left out of that run because its file does not exist.

**Before a live test**

1. A subscription where you are Owner (or Contributor plus User Access Administrator), not the QA production subscription.
2. `az` and `jq` installed. `az login` as your user. `az account show` is that subscription.
3. An ACR in that subscription that already has the three images at one immutable tag. Copy the login server and the registry resource ID.
4. Your public IP as a `/32`, and your Entra object ID.
5. A throwaway SSH public key file for the jump VM break-glass user.
6. The two Cloudanix secrets exported in the shell.
7. Step 4's script present. Without it the test creates the VNet, jump VM, storage, vaults, and identity, then fails.

**Live test**

```bash
export CDX_AUTH_TOKEN='...'
export CDX_SIGNATURE_SECRET_KEY='...'
cd azure-jit-vm
./setup.sh
```

Pick option 1. Use a prefix you have never used, for example `cdxaztest`. Accept the summary.

Check, in order:

- Resource group `{prefix}-jit-vm-rg` exists.
- Jump VM is running, NSG allows 22 only from your CIDR, and 2222/8079 are absent.
- Both Key Vaults contain no secret *values* in the script output. Environment vault has the secret *names* from step 4.
- Three container groups are Running, private IP, in the ACI subnet.
- `./refresh-forwarders.sh` prints the two private IPs and exits 0.
- A private test VM in `10.30.3.0/24` (or a peered VNet) accepts SSH from `10.30.2.0/24`, its key is in the keys vault, and `cdx vm connect` opens a shell.

Tear down with `az group delete --name {prefix}-jit-vm-rg --yes` when finished. That does not remove the ACR.

## Not in this setup yet

- One-line installer entry
- `--share` and `--cleanup`
- A step that copies images into your registry
- Azure JIT Database and Azure JIT Kubernetes pages

## How to test each option

Start a new wizard each time (`rm -f .state.json` only when you intend to abandon the previous run). Hub options need the two exports. Onboard options do not.

1. **New VNet.** Option 1. Prefix you have never used. Target VNet must not overlap `10.30.0.0/16`. Expect peering `Connected`, NSG rule `AllowCdxProxySsh`, and secret `<vm>-<user>` in `{prefix}-jitkeys-kv`.
2. **Onboard new VNet.** Option 4. Same prefix. A different target VNet and VM. Expect a second peering and a second key secret. No new container groups.
3. **Onboard already-peered.** Option 3. Same prefix. A VM in a VNet that already has the hub peering. Expect only the NSG rule and the key secret.
4. **Existing VNet.** Option 2, on a non-production VNet. The ACI subnet must be empty or already delegated. Expect the jump VM in that subnet and containers on the ACI subnet.

Do not use the production prefix or `jit-vm-prod-vnet` for option 2. Deleting `{prefix}-jit-vm-rg` removes a hub from option 1. It does not remove peerings created inside the target VNet. Delete those peerings by name `cdx-{prefix}-to-hub` before deleting the hub, or the target VNet keeps a disconnected peering.
