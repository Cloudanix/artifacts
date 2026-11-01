#!/usr/bin/env bash
# =============================================================================
# Step 06 — Jump VM Loopback Forwarders
# =============================================================================
# On the jump VM, two systemd services forward loopback ports to the private
# ACI groups:
#   127.0.0.1:2222 -> sshpiper ACI:2222
#   127.0.0.1:8079 -> VM proxy ACI:8079
# Both bind to 127.0.0.1 only, so the public IP never exposes them. The CLI
# reaches them through the az ssh tunnel.
#
# ACI private IPs are fixed when a group is created and change if it is
# recreated. Re-run this step (or refresh-forwarders.sh) after any recreation.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

SSHPIPER_IP="$(az container show --resource-group "$RG" --name "$ACI_SSHPIPER" --query ipAddress.ip -o tsv)"
VMPROXY_IP="$(az container show --resource-group "$RG" --name "$ACI_VMPROXY" --query ipAddress.ip -o tsv)"
if [[ -z "$SSHPIPER_IP" || -z "$VMPROXY_IP" ]]; then
    error "Container private IPs not found. Run step 05 first."
    exit 1
fi

# The remote script is built locally so the current IPs are baked in.
REMOTE_SCRIPT="set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq socat netcat-openbsd
cat > /etc/systemd/system/cdx-sshpiper.service <<UNIT
[Unit]
Description=Loopback forward to sshpiper container
After=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:2222,bind=127.0.0.1,fork,reuseaddr TCP:${SSHPIPER_IP}:2222
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/cdx-vmproxy.service <<UNIT
[Unit]
Description=Loopback forward to VM proxy container
After=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:8079,bind=127.0.0.1,fork,reuseaddr TCP:${VMPROXY_IP}:8079
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable cdx-sshpiper cdx-vmproxy
systemctl restart cdx-sshpiper cdx-vmproxy
sleep 2
nc -z 127.0.0.1 2222
nc -z 127.0.0.1 8079
echo forwarders-ok"

info "Configuring forwarders on $JUMP_VM"
RESULT="$(az vm run-command invoke --resource-group "$RG" --name "$JUMP_VM" \
    --command-id RunShellScript --scripts "$REMOTE_SCRIPT" \
    --query 'value[0].message' -o tsv)"

# run-command can report success even when the script fails, so the output
# must contain the success marker.
if [[ "$RESULT" != *forwarders-ok* ]]; then
    error "Forwarder check did not pass. run-command output:"
    echo "$RESULT"
    exit 1
fi
ok "Forwarders active: 127.0.0.1:2222 -> $SSHPIPER_IP:2222, 127.0.0.1:8079 -> $VMPROXY_IP:8079"

JUMP_PUBLIC_IP="$(az network public-ip show --resource-group "$RG" --name "$JUMP_PIP" --query ipAddress -o tsv)"

echo ""
echo "Azure JIT VM proxy is deployed."
echo "  Resource group : $RG"
echo "  Jump VM        : $JUMP_VM ($JUMP_PUBLIC_IP)"
echo "  Environment KV : $KV_ENV"
echo "  Target keys KV : $KV_KEYS"
echo "  Recordings     : https://${STORAGE}.blob.core.windows.net/${LOG_CONTAINER}"
echo ""
echo "Next: add the target VM in the Cloudanix console, store its SSH private key in $KV_KEYS,"
echo "then connect with: cdx vm connect"

echo "OUTPUT:JUMP_PUBLIC_IP=$JUMP_PUBLIC_IP"
echo "OUTPUT:RESOURCE_GROUP=$RG"
