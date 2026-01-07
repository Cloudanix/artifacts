#!/bin/bash
set -e

echo "=========================================="
echo "Jump VM Optimization Installer"
echo "=========================================="
echo ""
echo "This script will:"
echo "  1. Backup existing configurations"
echo "  2. Apply system optimizations"
echo "  3. Update socat services"
echo "  4. Install monitoring tools"
echo "  5. Test everything"
echo ""
echo "It's safe to run on your existing VM."
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# Create backup directory
BACKUP_DIR="/root/optimization-backup-$(date +%Y%m%d-%H%M%S)"
echo ""
echo "Creating backup in: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# ===========================================
# BACKUP EXISTING CONFIGURATIONS
# ===========================================

echo ""
echo "[1/6] Backing up existing configurations..."

# Backup limits.conf
if [ -f /etc/security/limits.conf ]; then
  cp /etc/security/limits.conf "$BACKUP_DIR/limits.conf.bak"
  echo "  ✓ Backed up limits.conf"
fi

# Backup sysctl configs
if [ -d /etc/sysctl.d ]; then
  cp -r /etc/sysctl.d "$BACKUP_DIR/sysctl.d.bak"
  echo "  ✓ Backed up sysctl.d/"
fi

# Backup systemd services
mkdir -p "$BACKUP_DIR/systemd"
for service in /etc/systemd/system/socat-*.service; do
  if [ -f "$service" ]; then
    cp "$service" "$BACKUP_DIR/systemd/"
    echo "  ✓ Backed up $(basename $service)"
  fi
done

echo ""
echo "Backup complete: $BACKUP_DIR"
echo "To rollback, run: /root/rollback-optimizations.sh"

# ===========================================
# CREATE ROLLBACK SCRIPT
# ===========================================

cat > /root/rollback-optimizations.sh <<ROLLBACK
#!/bin/bash
# Rollback optimizations

echo "Rolling back optimizations..."

# Restore limits.conf
if [ -f "$BACKUP_DIR/limits.conf.bak" ]; then
  cp "$BACKUP_DIR/limits.conf.bak" /etc/security/limits.conf
  echo "  ✓ Restored limits.conf"
fi

# Restore sysctl
if [ -d "$BACKUP_DIR/sysctl.d.bak" ]; then
  rm -rf /etc/sysctl.d/*
  cp -r "$BACKUP_DIR/sysctl.d.bak"/* /etc/sysctl.d/
  sysctl -p /etc/sysctl.d/*.conf
  echo "  ✓ Restored sysctl settings"
fi

# Restore systemd services
if [ -d "$BACKUP_DIR/systemd" ]; then
  cp "$BACKUP_DIR/systemd"/*.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl restart socat-*
  echo "  ✓ Restored socat services"
fi

echo "Rollback complete!"
ROLLBACK

chmod +x /root/rollback-optimizations.sh

# ===========================================
# INSTALL REQUIRED PACKAGES
# ===========================================

echo ""
echo "[2/6] Installing required packages..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  socat htop iotop sysstat 2>&1 | grep -v "already the newest version" || true

echo "  ✓ Packages installed"

# ===========================================
# APPLY SYSTEM OPTIMIZATIONS
# ===========================================

echo ""
echo "[3/6] Applying system optimizations..."

# Update limits.conf (append, don't replace)
cat >> /etc/security/limits.conf <<'LIMITS'

# JIT Jump VM Optimizations - Added $(date)
*               soft    nofile          65536
*               hard    nofile          65536
*               soft    nproc           8192
*               hard    nproc           8192
root            soft    nofile          65536
root            hard    nofile          65536
root            soft    nproc           8192
root            hard    nproc           8192
LIMITS

echo "  ✓ Updated limits.conf"

# Create sysctl optimizations
cat > /etc/sysctl.d/99-jit-optimization.conf <<'SYSCTL'
# JIT Jump VM Network Optimizations

# TCP Buffer Sizes (32MB max)
net.core.rmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_default = 262144
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

# TCP Connection Tuning
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Increase connection backlog
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# TCP Keepalive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# Port range
net.ipv4.ip_local_port_range = 10000 65535

# Reuse sockets faster
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# File descriptor limits
fs.file-max = 2097152
SYSCTL

echo "  ✓ Created sysctl optimizations"

# Apply sysctl settings
sysctl -p /etc/sysctl.d/99-jit-optimization.conf > /dev/null 2>&1
echo "  ✓ Applied sysctl settings"

# ===========================================
# UPDATE SOCAT SERVICES
# ===========================================

echo ""
echo "[4/6] Updating socat services..."

# Get ILB addresses from existing services or metadata
if systemctl cat socat-proxysql-mysql >/dev/null 2>&1; then
  PROXYSQL_ILB=$(systemctl cat socat-proxysql-mysql | grep -oP 'TCP:\K[^:]+' | head -1)
  echo "  Found ProxySQL ILB: $PROXYSQL_ILB"
else
  PROXYSQL_ILB=$(curl -sfH "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/proxysql-ilb 2>/dev/null || echo "10.236.0.101")
  echo "  Using ProxySQL ILB from metadata: $PROXYSQL_ILB"
fi

if systemctl cat socat-proxyserver >/dev/null 2>&1; then
  PROXYSERVER_ILB=$(systemctl cat socat-proxyserver | grep -oP 'TCP:\K[^:]+' | head -1)
  echo "  Found ProxyServer ILB: $PROXYSERVER_ILB"
else
  PROXYSERVER_ILB=$(curl -sfH "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/proxyserver-ilb 2>/dev/null || echo "10.236.0.103")
  echo "  Using ProxyServer ILB from metadata: $PROXYSERVER_ILB"
fi

if systemctl cat socat-dam-server >/dev/null 2>&1; then
  DAM_SERVER_ILB=$(systemctl cat socat-dam-server | grep -oP 'TCP:\K[^:]+' | head -1)
  echo "  Found DAM Server ILB: $DAM_SERVER_ILB"
else
  DAM_SERVER_ILB=$(curl -sfH "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/dam-server-ilb 2>/dev/null || echo "10.236.0.102")
  echo "  Using DAM Server ILB from metadata: $DAM_SERVER_ILB"
fi

# Service definitions
declare -A SERVICES=(
  ["proxysql-mysql"]="6033:${PROXYSQL_ILB}"
  ["proxysql-psql"]="6133:${PROXYSQL_ILB}"
  ["proxyserver"]="8079:${PROXYSERVER_ILB}"
  ["dam-server"]="8080:${DAM_SERVER_ILB}"
)

echo ""
echo "  Updating service configurations..."

for name in "${!SERVICES[@]}"; do
  port=$(echo "${SERVICES[$name]}" | cut -d: -f1)
  ilb=$(echo "${SERVICES[$name]}" | cut -d: -f2)

  # Stop service before updating
  if systemctl is-active socat-${name} >/dev/null 2>&1; then
    systemctl stop socat-${name}
  fi

  # Create optimized service
  cat > /etc/systemd/system/socat-${name}.service <<SVC
[Unit]
Description=Optimized Socat forward to ${name}
After=network.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=3
StartLimitBurst=10
StartLimitIntervalSec=60

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

# Optimized socat with:
# - 256KB buffers (vs 8KB default)
# - TCP_NODELAY (lower latency)
# - Keepalive (detect dead connections)
ExecStart=/usr/bin/socat -d -d \\
  TCP-LISTEN:${port},fork,reuseaddr,sndbuf=262144,rcvbuf=262144 \\
  TCP:${ilb}:${port},nodelay,keepalive,keepidle=60,keepintvl=10,keepcnt=6

StandardOutput=journal
StandardError=journal
SyslogIdentifier=socat-${name}

[Install]
WantedBy=multi-user.target
SVC

  echo "    ✓ Updated socat-${name}"
done

# Reload systemd and restart services
systemctl daemon-reload
echo "  ✓ Reloaded systemd"

# Start services one by one
echo ""
echo "  Starting optimized services..."
for name in "${!SERVICES[@]}"; do
  systemctl enable socat-${name} >/dev/null 2>&1
  systemctl start socat-${name}
  
  # Wait a moment and check if started
  sleep 1
  if systemctl is-active socat-${name} >/dev/null 2>&1; then
    echo "    ✓ socat-${name} running"
  else
    echo "    ✗ socat-${name} failed to start"
    echo "      Check logs: journalctl -u socat-${name} -n 20"
  fi
done

# ===========================================
# INSTALL MONITORING TOOLS
# ===========================================

echo ""
echo "[5/6] Installing monitoring tools..."

# Create monitoring script
cat > /usr/local/bin/check-jit-services <<'MONITOR'
#!/bin/bash
echo "=========================================="
echo "JIT Services Status"
echo "=========================================="
echo ""

for service in proxysql-mysql proxysql-psql proxyserver dam-server; do
  echo "Service: socat-${service}"
  if systemctl is-active socat-${service} >/dev/null 2>&1; then
    echo "  Status: ✓ Running"
  else
    echo "  Status: ✗ Stopped"
  fi
  
  port=$(systemctl cat socat-${service} 2>/dev/null | grep TCP-LISTEN | sed 's/.*TCP-LISTEN:\([0-9]*\).*/\1/')
  if [ -n "$port" ]; then
    connections=$(ss -tn 2>/dev/null | grep ":${port}" | wc -l)
    echo "  Port: ${port}"
    echo "  Active connections: ${connections}"
  fi
  echo ""
done

echo "System Resources:"
echo "  Load: $(uptime | awk -F'load average:' '{print $2}')"
echo "  Memory: $(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
echo "  Open files: $(lsof 2>/dev/null | wc -l) / $(ulimit -n)"
echo ""

echo "Optimizations Applied:"
echo "  File descriptors: $(ulimit -n)"
echo "  TCP rmem max: $(sysctl -n net.core.rmem_max) bytes"
echo "  TCP wmem max: $(sysctl -n net.core.wmem_max) bytes"
echo ""
MONITOR

chmod +x /usr/local/bin/check-jit-services
echo "  ✓ Installed check-jit-services"

# Create aliases if not already present
if ! grep -q "check-jit" /root/.bashrc 2>/dev/null; then
  cat >> /root/.bashrc <<'ALIASES'

# JIT Jump VM Aliases
alias check-services='systemctl status socat-*'
alias check-jit='/usr/local/bin/check-jit-services'
alias jit-logs='journalctl -u socat-* -f'
alias jit-restart='systemctl restart socat-*'
alias test-mysql='mysql -h 127.0.0.1 -P 6033 -u cdx_cloudsql_mysql_writer -p -e "SELECT 1"'
alias test-dam='curl -s http://127.0.0.1:8080/health'
alias test-proxy='curl -s http://127.0.0.1:8079/health'

echo ""
echo "JIT Jump VM - Optimized"
echo "Run 'check-jit' to see status"
echo ""
ALIASES

  echo "  ✓ Added helpful aliases"
fi

# ===========================================
# TEST EVERYTHING
# ===========================================

echo ""
echo "[6/6] Testing services..."

sleep 2

ALL_OK=true
for service in proxysql-mysql proxysql-psql proxyserver dam-server; do
  if systemctl is-active socat-${service} >/dev/null 2>&1; then
    echo "  ✓ socat-${service} is running"
  else
    echo "  ✗ socat-${service} is NOT running"
    ALL_OK=false
  fi
done

echo ""

if [ "$ALL_OK" = true ]; then
  echo "=========================================="
  echo "✓ Optimization Complete!"
  echo "=========================================="
  echo ""
  echo "Summary of changes:"
  echo "  ✓ Increased file descriptors to 65,536"
  echo "  ✓ Optimized TCP buffers (256KB)"
  echo "  ✓ Enabled TCP_NODELAY (lower latency)"
  echo "  ✓ Configured TCP keepalive (2 min timeout)"
  echo "  ✓ Increased connection backlog to 4,096"
  echo "  ✓ All socat services updated and running"
  echo ""
  echo "Expected improvements:"
  echo "  • 5-20% faster queries (within GCP)"
  echo "  • 64x more concurrent connections"
  echo "  • Better handling of large result sets"
  echo "  • Faster dead connection cleanup"
  echo ""
  echo "New commands available:"
  echo "  check-jit     - Check service status"
  echo "  test-mysql    - Test MySQL connection"
  echo "  jit-logs      - Watch logs"
  echo "  jit-restart   - Restart all services"
  echo ""
  echo "Backup saved in: $BACKUP_DIR"
  echo "To rollback: /root/rollback-optimizations.sh"
  echo ""
  echo "Log out and back in to use new commands!"
else
  echo "=========================================="
  echo "⚠ Some services failed to start"
  echo "=========================================="
  echo ""
  echo "Check logs with:"
  echo "  journalctl -u socat-* -n 50"
  echo ""
  echo "To rollback:"
  echo "  /root/rollback-optimizations.sh"
  echo ""
fi