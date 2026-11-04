# Azure JIT VM

Just-In-Time (JIT) access lets your team get temporary, audited SSH to private Azure VMs without standing credentials on laptops or open inbound ports. Cloudanix deploys a jump VM and three private proxy containers in a hub VNet in your subscription, connects them to the target VM over the private network, and brokers the session through Entra ID.

```text
cdx vm connect → az ssh (Entra) → jump VM (port 22 only) → private proxy → target VM
```

The jump VM forwards ports 2222 and 8079 on loopback only. Those ports are not opened on the public IP.

## Choose your scenario

| Scenario | Use this scope |
| --- | --- |
| First-time setup. New hub VNet, jump VM, private proxy, peered to the target VNet | **New VNet** |
| Run the proxy in a VNet you already have | **Existing VNet** |
| Add a VM in a VNet already peered to the hub | **Onboard (already-peered VNet)** |
| Add a VM in a new or unpeered VNet | **Onboard (new VNet)** |

New VNet asks for a hub CIDR. The default is `10.30.0.0/16`: jump `.1.0/24`, proxy `.2.0/24`, spare `.3.0/24`. That range must not overlap the target VNet.

Options 3 and 4 reuse the hub. Use the same name prefix as the hub install. They do not create another jump VM or another set of containers.

## Install and run

Sign in as a user (`az login`), not a service principal. From this repo:

```bash
export CDX_AUTH_TOKEN='...'
export CDX_SIGNATURE_SECRET_KEY='...'
cd azure-jit-vm
./setup.sh
```

Hub installs (New VNet and Existing VNet) need those two exports. Onboard options do not. The values stay in the shell and are not written to `.state.json`.

The wizard asks for every non-secret value up front, prints a summary, then runs the steps. If a step fails, fix the cause and run `./setup.sh` again. Choose resume. Completed steps are skipped.

The one-line installer does not offer `azure-jit-vm` yet.

## What you'll need handy

**New VNet and Existing VNet**

- Hub subscription ID and region
- Name prefix, 3–12 characters, a lowercase letter then letters or digits (default `cdxjit`). Use the same prefix when you add another VM to this hub
- A VPN CIDR for SSH to the jump VM, if you have one. Otherwise the jump VM allows SSH from `0.0.0.0/0`
- The signed-in Entra user is the default operator
- A jump VM SSH key created at `~/.ssh/cdx-azure-jit-jump`
- Registry login server (default `cdxjitcentral.azurecr.io`). The resource ID is looked up from that name. Setup asks for the image tag with the other answers, then imports the three proxy images at that tag. The containers run the same tag. `latest` is rejected. When the registry is already `cdxjitcentral`, the images are not copied.
- Cloudanix API base URL (default `https://api.cloudanix.com`) and data center (`US`, `IN`, or `MC1`)
- `CDX_AUTH_TOKEN` and `CDX_SIGNATURE_SECRET_KEY`

**Existing VNet also**

- VNet name and resource group
- Subnet for the jump VM
- Subnet for the proxy containers. It must already be delegated to Container Instances, or be empty so the script can delegate it

**Every scope**

- Target VM name, resource group, and OS user (default `azureuser`)
- Path to that VM's SSH private key
- For New VNet and Onboard new VNet: target VNet name, its resource group, and the target subscription ID (the same GUID when there is only one subscription)

## Storing the SSH key

The last step of every scope stores the target private key in the keys vault `{prefix}-jitkeys-kv`.

1. Enter the VM name. The script uses that name, not the full resource ID.
2. Enter the OS user.
3. Give the key by file path. The file is passed to Key Vault and is not printed.

The secret name is `<vm-name>-<os-user>`. Dots and underscores become hyphens. A second OS user on the same VM is another run of an onboard scope with a different OS user. That writes a second secret and leaves the first one in place. Two people who log in as the same OS user share that one key.

You can add more keys later by re-running and choosing an onboard scope.

## What each scope creates

**New VNet** creates the JIT VM roles, imports the images, then runs steps 01 through 10.

1. Resource group, VNet, jump / proxy / spare subnets, network security group, public IP, Ubuntu 22.04 jump VM (`Standard_B2s`), Entra SSH login.
2. Storage account, working-dir share, recordings share, log container, environment vault, keys vault.
3. Managed identity: read both vaults, write blobs, pull from your registry.
4. Runtime configuration in the environment vault, including the two Cloudanix credentials.
5. Three private container groups: sshpiper on 2222, VM proxy on 8079, logging on 8079.
6. Loopback forwarders on the jump VM.
7. Peering from the hub VNet to the target VNet.
8. Peering from the target VNet back to the hub. It must reach `Connected`.
9. TCP 22 from the proxy subnet on the target network security group.
10. The target SSH key.

**Existing VNet** runs the same hub steps inside the VNet you name, then steps 9 and 10. It does not create a VNet and it does not create a peering.

**Onboard (already-peered)** runs steps 9 and 10 only.

**Onboard (new VNet)** runs steps 7 through 10.

## Tags

The jump VM is tagged `owner=cloudanix`, `service=jump-box`, `purpose=cdx-jit-vm`. That is what `cdx vm connect` looks for when `jump_vm_tags` is not set.

Every resource this setup creates also gets:

| Tag | Value |
| --- | --- |
| `asset-owner` | `Cloudanix` |
| `asset-service` | `CloudSecurity` |
| `asset-purpose` | `Security-Monitoring` |

A VNet, subnet, or network security group you already owned is not retagged. Subnets, security rules, file shares, and the blob container cannot carry their own tags. The storage account tag covers the shares and the container.

## After setup

1. Add the Azure VM target in the Cloudanix console (subscription, region, resource group, VM name, OS user).
2. Confirm the private key secret exists in `{prefix}-jitkeys-kv`.
3. Connect with `cdx vm connect`.

If you replace a container group, its private IP changes. From the same directory, run `./refresh-forwarders.sh`.

There is no `--share` command yet. Send Cloudanix the resource group, jump VM name, jump public IP, subscription ID, both Key Vault names, and the name prefix.

There is no `--cleanup` command yet. Delete the peering named `cdx-{prefix}-to-hub` in the target VNet first, then delete the resource group `{prefix}-jit-vm-rg`. Deleting the group does not remove that peering, your registry, or the target VM. An NSG rule named `AllowCdxProxySsh` on a target group you already owned is left in place. Remove it yourself if you want it gone.

## Roles the connecting user needs

`CDX JIT VM Read Access` and `CDX JIT VM SSH Access` are created by this setup and assigned to the operator. Read covers the VM, NIC, and public IP. SSH Access is `Microsoft.Compute/virtualMachines/login/action`. These names are separate from the Kubernetes roles `CDX VM Read Access` and `CDX VM SSH Access`. The person who runs this setup also needs permission to create the resources and the role assignments (Owner, or Contributor plus User Access Administrator).
