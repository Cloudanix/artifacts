# Cloudanix JIT Setup Guide — Azure

Just-In-Time (JIT) access lets your team get temporary, audited access to private databases, Kubernetes clusters, and VMs without standing credentials on laptops or open inbound ports. Cloudanix deploys a small hub in your Azure subscription and brokers access through Entra ID.

Sign in with `az login` as a user before any page below. `az` and `jq` are required.

Each page is resumable in the sense that the scripts check for resources that already exist. There is no one-line installer entry for these Azure products yet.

## What you'll set up

| Product | What it gives your team | Page |
| --- | --- | --- |
| Azure JIT Database | Temporary, audited access to private Azure Database for PostgreSQL or MySQL | Azure JIT Database |
| Azure JIT VM | Temporary, recorded SSH sessions to private Azure VMs | Azure JIT VM |
| Azure JIT Kubernetes | Temporary `kubectl` access to private AKS clusters | Azure JIT Kubernetes |

## Before you start

- You can create resource groups, networks, virtual machines, and role assignments in the subscription. Owner, or Contributor plus User Access Administrator, covers that.
- You know the subscription ID. `az account show --query id -o tsv`
- You know your Entra object ID. `az ad signed-in-user show --query id -o tsv`
- You have a public IP CIDR for the operators who will open the hub, or you accept SSH from anywhere.
- Cloudanix has given you `CDX_AUTH_TOKEN` and `CDX_SIGNATURE_SECRET_KEY`. Export them in the shell. Do not put them in a file you commit.
- The hub address range must not overlap the database VNet, the target VM VNet, or the AKS VNet.

---

# Azure JIT Database

Temporary access to a private PostgreSQL or MySQL server. A jump VM and a private container instance sit in a hub VNet. The container is the database proxy. The jump VM is the only public SSH endpoint.

Run the scripts in `azure-jit-db/` in this order. They prompt as they go. Script 2 writes `~/jit-infra.env`. Scripts 3 through 6 read that file.

```bash
cd azure-jit-db
./1.sync-acr.sh
./2.setup-infra.sh
./3.deploy-aci.sh
./4.create-custom-role.sh
./5.connect-db.sh
./6.create-sp-and-binding.sh
```

## What you'll need handy

- JIT subscription ID and the database subscription ID. They can be the same.
- Region
- Resource group, VNet, subnet, registry, and container names. The scripts offer defaults such as `cdx-jit-db-rg`.
- Database server name and engine (`postgresql` or `mysql`)
- Cloudanix API base URL, data center, auth token, and signature key
- Script 1 creates a registry named `jitacr` plus a short suffix and asks for the image tag. It imports that tag from `cdxjitcentral.azurecr.io`. That registry allows anonymous pull, so there is no pull token and no Docker. The same tag is what the containers run. `latest` is rejected. The customer registry name is separate from `cdxjitcentral`.

## What the scripts do

1. **Sync images.** Asks for the image tag, then imports that tag from `cdxjitcentral.azurecr.io` into your registry. Container Instances pull the same tag.
2. **Hub.** Resource group, VNet, jump subnet, container subnet, private-endpoint subnet, jump VM with Entra SSH login, network security group limited to your CIDRs, Key Vault, storage for the proxy and for logs, managed identity, and the secrets the proxy reads at startup.
3. **Container.** Deploys the database proxy container on the private subnet, using the identity to pull the image.
4. **Custom role.** Creates the SSH login role used to reach the jump VM.
5. **Database connectivity.** Connects the hub to the database server and opens the path the proxy needs.
6. **Service principal and database binding.** Creates the Entra identity the database will trust and binds it to the server.

## After setup

Add the database in the Cloudanix console, then connect with `cdx db connect`.

Send Cloudanix the subscription ID, resource group, jump VM name, jump public IP, VNet name, and Key Vault name. There is no `--share` command.

To remove the hub, delete the resource group created by script 2. That does not delete the database server. A firewall or network rule script 5 added on the database may remain. Remove that rule yourself if you want it gone.

---

# Azure JIT VM

Temporary, recorded SSH to a private Azure VM. A jump VM and three private proxy containers sit in the hub. `cdx vm connect` opens an Entra SSH tunnel to the jump VM. The jump VM forwards to the proxy on loopback only. The public IP exposes port 22 and nothing else.

```text
cdx vm connect → az ssh (Entra) → jump VM:22 → private proxy → target VM:22
```

## Who listens

| Place | Listens on | Who connects |
| --- | --- | --- |
| Jump VM public IP | TCP 22 | The laptop, through `az ssh` and Entra. The network security group allows the VPN CIDR you give, or `0.0.0.0/0` when you have none. |
| Jump VM loopback | `127.0.0.1:2222` | socat to the sshpiper private IP, port 2222. This port is not on the public IP. |
| Jump VM loopback | `127.0.0.1:8079` | socat to the VM proxy private IP, port 8079. This port is not on the public IP. |
| sshpiper | TCP 2222 | The jump VM socat. Private IP only. |
| VM proxy | TCP 8079 | The jump VM socat. Private IP only. It calls the Cloudanix API over HTTPS 443. |
| Query logging | TCP 8079 | Nothing on the SSH path. It reads the recordings share and uploads `.cast` and `.json` files to blob container `jit-vm-logs`. |
| Target VM | TCP 22 | sshpiper, over the VNet peering. No public IP. |

There is no internal load balancer.

## VNet peering

A new peering is two records. Both allow virtual network access and forwarded traffic. The state must be `Connected`, and the address spaces must not overlap. The target subscription can be the hub subscription or a different one.

| Direction | Name |
| --- | --- |
| Hub VNet to target VNet | `cdx-{prefix}-to-target` for one VM. Bulk onboard uses `cdx-{prefix}-<hash>` so each target VNet gets its own peering. |
| Target VNet to hub VNet | `cdx-{prefix}-to-hub` |

The target network security group gets rule `AllowCdxProxySsh`: inbound TCP 22 from the proxy subnet (`10.30.2.0/24` on the default hub).

Default hub `10.30.0.0/16`:

| Subnet | CIDR | What sits there |
| --- | --- | --- |
| `{prefix}-jump-subnet` | `10.30.1.0/24` | Jump VM. Network security group allows inbound TCP 22 only. |
| `{prefix}-aci-subnet` | `10.30.2.0/24` | sshpiper, VM proxy, query logging. Delegated to Container Instances. |
| `{prefix}-vm-subnet` | `10.30.3.0/24` | Spare. Unused when the target VM is in another VNet. |

## Choose your scenario

| Scenario | Use this scope |
| --- | --- |
| First hub. New VNet, jump VM, private proxy, peered to the target VNet | **New VNet** |
| Proxy in a VNet you already have | **Existing VNet** |
| Add a VM whose VNet is already peered to the hub | **Onboard (already-peered VNet)** |
| Add a VM in a VNet that is not peered yet | **Onboard (new VNet)** |
| Many VMs, one shared root key and one shared non-root key | **Bulk onboard** (finished hub menu, or `./bulk-onboard.sh`) |

Setup asks for the hub VNet CIDR when you create a new hub. The default is `10.30.0.0/16`: jump `.1.0/24`, proxy `.2.0/24`, spare `.3.0/24`. It must be a `/16` and it must not overlap the target VNet. Onboard and bulk reuse the hub, so they use the same name prefix and do not create another jump VM.

## Install and run

```bash
export CDX_AUTH_TOKEN='...'
export CDX_SIGNATURE_SECRET_KEY='...'
cd ~/.cdx-jit/azure-jit-vm
./setup.sh
```

Install with `install.sh` and the argument `azure-jit-vm`. That copies the wizard to `~/.cdx-jit/azure-jit-vm`. Hub scopes need those two exports. Onboard scopes and bulk onboard do not. They are not written to `.state.json`. If a step fails, run `./setup.sh` again and resume. Completed steps are skipped.

When every hub step is complete, `./setup.sh` shows **Bulk onboard VMs from a CSV** instead of the resume prompt.

## What you'll need handy

- Hub subscription, region, and a name prefix (default `cdxjit`, 3–12 characters, starting with a lowercase letter). Use the same prefix when you add another VM to this hub
- A VPN CIDR for SSH to the jump VM, if you have one. Otherwise the jump VM allows SSH from `0.0.0.0/0`
- The signed-in Entra user is the default operator. Setup fills in that object ID
- A jump VM SSH key. Setup creates it at `~/.ssh/cdx-azure-jit-jump` when it is missing
- Registry login server (default `cdxjitcentral.azurecr.io`). The resource ID is looked up from that name. Setup asks for the image tag, then imports `cloudanix/ecr-aws-jit-vm-sshpiper`, `cloudanix/ecr-aws-jit-vm-proxyserver`, and `cloudanix/ecr-aws-jit-vm-logging` at that tag. The containers run the same tag. `latest` is rejected. When the registry is already `cdxjitcentral`, the images are not copied
- API base URL (default `https://api.cloudanix.com`) and data center (`US`, `IN`, or `MC1`)
- Target VM name, resource group, OS user (default `azureuser`), and the path to its private key
- For a new peering: target VNet name, its resource group, and the target subscription ID

Existing VNet also asks for the VNet and for the jump and proxy subnets. The proxy subnet must already be delegated to Container Instances, or be empty so the script can delegate it.

## Storing the SSH key

The last step writes the target private key into `{prefix}-jitkeys-kv`. You give the VM name, the OS user, and a file path. The file is passed to Key Vault and is not printed.

The proxy looks up the Azure VM id, because validate sends that id as `vmInstanceId`. The step stores the same key twice:

1. `<vmId>-<os-user>`
2. `<vm-name>-<os-user>`

Dots and underscores in either part become hyphens. Another OS user on the same VM is a second onboard run with a different OS user. That writes a second pair of secrets and leaves the first pair in place.

## What each scope runs

**New VNet.** Creates **CDX JIT VM SSH Access** and **CDX JIT VM Read Access**, asks for the image tag, imports the three proxy images at that tag, then resource group, VNet, subnets, network security group, public IP, Ubuntu 22.04 jump VM (`Standard_B2s`), Entra SSH login, storage, both Key Vaults, managed identity, runtime configuration, three private container groups (sshpiper on 2222, VM proxy on 8079, logging on 8079), loopback forwarders, both sides of the VNet peering, TCP 22 from the proxy subnet, and the target key.

**Existing VNet.** The same hub pieces inside the VNet you name, then the SSH allow and the key. No new VNet and no peering.

**Onboard (already-peered).** SSH allow and the key only.

**Onboard (new VNet).** Peering both ways, then SSH allow and the key. Peering must reach `Connected`.

**Bulk onboard.** No new hub. For each CSV row: reuse a peering to that VNet when one exists, otherwise create both sides; allow TCP 22 from the proxy subnet; store the root key and the non-root key. See [Bulk onboard a fleet](#bulk-onboard-a-fleet).

## Bulk onboard a fleet

Use this after the hub setup is complete, when one environment has many VMs and every VM uses the same root key and the same non-root key.

Run `./setup.sh` and choose **Bulk onboard VMs from a CSV**. It asks for the CSV path, runs a dry run, then asks before it changes Azure. Or run it directly:

```bash
cd ~/.cdx-jit/azure-jit-vm
./bulk-onboard.sh --csv ./vms.csv --dry-run
./bulk-onboard.sh --csv ./vms.csv
```

`--root-key` and `--nonroot-key` fill in any row that leaves the path columns empty. `--root-user` defaults to `root`. `--nonroot-user` defaults to `ubuntu`.

### CSV pattern

Header names are case-insensitive. Order is free. Values cannot contain commas or quotes. Required columns are `subscription_id`, `vm_resource_group`, and `vm_name`. Leave `vnet_name` and `vnet_resource_group` empty to take the VNet from the VM's NIC.

```csv
subscription_id,vm_resource_group,vm_name,region,root_user,nonroot_user,root_key_path,nonroot_key_path,vnet_name,vnet_resource_group
00000000-0000-0000-0000-000000000000,app-rg,app-vm-01,eastus2,root,ubuntu,/keys/fleet-root.pem,/keys/fleet-ubuntu.pem,,
00000000-0000-0000-0000-000000000000,app-rg,app-vm-02,eastus2,root,ubuntu,/keys/fleet-root.pem,/keys/fleet-ubuntu.pem,,
```

Pre-flight checks every row before any Azure change. A missing key file stops the run. A `region` that does not match the VM fails that row. Finished rows are recorded in `.bulk-onboard-progress.json` (no key material) and skipped on the next run.

### Key Vault secret pattern

Each user is stored twice in `{prefix}-jitkeys-kv`. Dots and underscores in the VM name or the user become hyphens. The VM id is the Azure `vmId`, not the resource ID.

| Secret name | Example for `app-vm-01`, user `ubuntu` |
| --- | --- |
| `<vmId>-<user>` | `815b755a-b3d3-4c03-a50f-96e8366e484d-ubuntu` |
| `<vm-name>-<user>` | `app-vm-01-ubuntu` |

A row with users `root` and `ubuntu` writes four secrets: `<vmId>-root`, `<vm-name>-root`, `<vmId>-ubuntu`, `<vm-name>-ubuntu`.

The setup guide says not to use root as the JIT user. Bulk onboard stores a root key only when the fleet already has one. Keep that key to the users named in the CSV.

Peering: an existing peering to that VNet is kept. A new hub peering is named `cdx-{prefix}-<hash>` (first 10 hex characters of the target VNet id). The target peering is `cdx-{prefix}-to-hub`. Both must reach `Connected`. The target NSG rule is `AllowCdxProxySsh`, TCP 22 from the proxy subnet.

## Tags

The jump VM is tagged `owner=cloudanix`, `service=jump-box`, `purpose=cdx-jit-vm`. That is what `cdx vm connect` looks for when `jump_vm_tags` is not set.

Every resource this setup creates also gets `asset-owner=Cloudanix`, `asset-service=CloudSecurity`, and `asset-purpose=Security-Monitoring`. A VNet or network security group you already owned is not retagged.

## After setup

Add the VM in the Cloudanix console, confirm both key secrets, then run `cdx vm connect`.

If you replace a container group, run `./refresh-forwarders.sh` so the jump VM picks up the new private IP.

Send the hub details to Cloudanix:

```bash
cd ~/.cdx-jit/azure-jit-vm && ./setup.sh --share
```

That prints the subscription, the jump VM resource group and tags, the two role definition IDs, and the log container name. It does not print keys or tokens. Paste that JSON to Cloudanix.

## Create the user on the target VM

The proxy logs in as the OS user you name during setup. Cloudanix records which person opened the session. The VM still needs its own account and a public key.

Create one OS user per access level. People who need the same rights share that user. A person who needs sudo gets a second user and a second key, not a shared root login.

On the target VM, as an admin:

```bash
sudo adduser --disabled-password --gecos "" jituser
sudo mkdir -p /home/jituser/.ssh
sudo chmod 700 /home/jituser/.ssh
```

Generate the key on your own machine, not on the VM. The private key must have an empty passphrase. The proxy cannot type one.

```bash
ssh-keygen -t ed25519 -f ./jituser -N "" -C "jituser"
```

Install only the public key on the VM:

```bash
sudo tee /home/jituser/.ssh/authorized_keys < ./jituser.pub >/dev/null
sudo chown -R jituser:jituser /home/jituser/.ssh
sudo chmod 600 /home/jituser/.ssh/authorized_keys
```

sshd should allow public keys and refuse passwords and root login: `PubkeyAuthentication yes`, `PasswordAuthentication no`, `PermitRootLogin no`.

### Root and non-root accounts

- **Never use root as the JIT user.** Root login is off, and a root session through the proxy would have no per-person limit.
- **The JIT user is non-root with no sudo.** Every command in the session is recorded. Give the account only what the work needs.
- **Do not use the VM's admin account as the JIT user.** The `azureuser` default in setup is usually the provisioning account. On Ubuntu images it typically has passwordless sudo, so a JIT session on it is a root session. Set the OS user to a dedicated account.
- **Sudo for a person who needs it:** give that person a separate non-root account with sudo limited to the commands they need, in `/etc/sudoers.d/<name>`. Check the file with `sudo visudo -cf /etc/sudoers.d/<name>`. Avoid `ALL=(ALL) NOPASSWD: ALL` except for a platform admin. That account gets its own key and its own onboard run.
- **Keep one admin account for break-glass only.** Its key stays out of the JIT keys vault, so JIT access cannot reach it.
- **Check the account after you create it:**

```bash
sudo passwd -S jituser    # no usable password (NP or L)
sudo -l -U jituser        # no sudo rights, or only the commands you listed
```

- **When access ends,** lock the account (`sudo usermod -L jituser`), delete `/home/jituser/.ssh/authorized_keys`, and remove both secrets from the keys vault.

Run an onboard scope. The OS user is `jituser` and the private key path is `./jituser`. Setup stores that key as `<vmId>-jituser` and `<vm-name>-jituser`. After both secrets are in the keys vault, delete `./jituser` from your machine. The VM keeps the public key only.

- The account is not root and has no password.
- The private key is not in the VM image, cloud-init, or a git repo.
- The OS user you type in setup is the account name on the VM.
- sudo, when someone needs it, is a separate group that logs the command. It is not a root key shared by the team.

To remove the hub:

```bash
cd ~/.cdx-jit/azure-jit-vm && ./setup.sh --cleanup
```

The script asks you to confirm, then type the resource group name. It deletes:

- The peering `cdx-{prefix}-to-hub` in the target VNet, and `cdx-{prefix}-to-target` on the hub VNet
- Bulk peerings recorded in `.bulk-onboard-progress.json`: `cdx-{prefix}-to-hub` on each target VNet, and `cdx-{prefix}-<hash>` on the hub. A peering that already existed under another name is left in place
- The `AcrPull` role the proxy identity holds on your registry
- The resource group `{prefix}-jit-vm-rg`. That removes the hub VNet, jump VM, containers, storage account, both Key Vaults, and the managed identity

**The storage account holds every session recording.** Deleting it deletes the recordings in `jit-vm-logs`. Copy out any you need first.

It does not delete the target VM, your registry images, your existing VNet, or the custom roles. It prints the items to remove by hand: the `AllowCdxProxySsh` rule on the target network security group, the `AllowOperatorSSH` rule on a customer's network security group, and the two Key Vault names if you want to reuse them. Key Vaults stay in soft-delete until the retention ends.

The person who connects needs **CDX JIT VM Read Access** and **CDX JIT VM SSH Access**. This setup creates both and assigns them to the operator. Read covers the VM, NIC, and public IP. SSH Access is the Entra login action. These are not the Kubernetes roles `CDX VM Read Access` and `CDX VM SSH Access`.

---

# Azure JIT Kubernetes

Temporary `kubectl` access to a private AKS cluster. A jump VM in a hub VNet is peered to the cluster VNet. The CLI opens an Entra SSH tunnel through that VM and reaches the cluster API over the peering.

Run the scripts in `azure-jit-k8s/` in this order. Each script prompts for its own values. They are not the `./setup.sh` wizard. That wizard looks for a `steps/` directory these files are not in.

```bash
cd azure-jit-k8s
./01-create-custom-roles.sh
./02-setup-hub-vnet-and-vm.sh
./03-setup-peering-role-and-dns.sh
```

When you later add a cluster in another subscription:

```bash
./04-extend-role-scopes.sh
./03-setup-peering-role-and-dns.sh
```

## What you'll need handy

- Hub subscription ID and region (script 2 defaults the region to `eastus`)
- Hub VNet CIDR (default `10.100.0.0/16`) and jump subnet CIDR (default `10.100.1.0/24`)
- Allowed SSH source CIDRs
- An SSH public key for the jump VM admin user `azureuser`
- AKS subscription ID, resource group, VNet name, and cluster name
- Extra AKS subscription IDs, if the cluster is not in the hub subscription

## What the scripts do

1. **Custom roles**, in the hub subscription.
   - **CDX VM SSH Access.** Entra SSH login to the jump VM.
   - **CDX VM Read Access.** Read the jump VM, its NIC, and its public IP.
   - **CDX K8s Read Access.** Read the AKS cluster and download its kubeconfig. The role's assignable scopes include the hub subscription and any extra AKS subscriptions you pass.
2. **Hub.** Resource group `cdx-jit-k8s-hub-rg`, VNet `cdx-vnet-hub`, subnet `cdx-snet-jumpbox`, network security group `cdx-nsg-jumpbox` allowing SSH only from your CIDRs, and jump VM `cdx-vm-jumpbox` (`Standard_B2s`) with Entra SSH login.
3. **Peering, role, and DNS.** Peers the hub VNet to the AKS VNet in both directions, extends **CDX K8s Read Access** to the AKS subscription when it is not already covered, and sets the private DNS link the jump VM needs to resolve the cluster API.
4. **Extend scopes.** Adds more subscriptions to **CDX K8s Read Access** after the first setup. Then run script 3 again for the new cluster VNet.

## After setup

Add the cluster in the Cloudanix console, then connect with `cdx k8s connect`.

Send Cloudanix the hub subscription ID, resource group `cdx-jit-k8s-hub-rg`, jump VM name `cdx-vm-jumpbox`, hub VNet name, and the AKS cluster name. There is no `--share` command.

To remove the hub, delete `cdx-jit-k8s-hub-rg`. Delete the peering on the AKS VNet as well. Deleting the hub group does not remove that peering or the cluster. The custom roles remain in the tenant until you delete those role definitions.

## Roles the connecting user needs

Assign **CDX VM Read Access** and **CDX VM SSH Access** on the hub, and **CDX K8s Read Access** on the cluster subscription.
