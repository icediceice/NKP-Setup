#!/usr/bin/env bash
# NKP 2.17.1 — Node prerequisites
# Run on every CP node before bootstrap. Idempotent.
set -euo pipefail

REGISTRY_IP="${1:-192.168.1.159}"
REGISTRY_PORT="${2:-5000}"

log() { echo "[prereq] $*"; }

log "Node: $(hostname) | registry mirror: http://${REGISTRY_IP}:${REGISTRY_PORT}"

# ── swap off ──────────────────────────────────────────────────────────────────
swapoff -a 2>/dev/null || true
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
log "swap disabled"

# ── kernel modules ────────────────────────────────────────────────────────────
cat > /etc/modules-load.d/nkp-k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay      2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
log "kernel modules loaded"

# ── sysctl ────────────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/99-nkp-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 1048576
vm.overcommit_memory                = 1
EOF
sysctl --system >/dev/null 2>&1
log "sysctl applied"

# ── containerd: configure only if already installed (NKP installs it otherwise)
CERTS_DIR="/etc/containerd/certs.d"
if command -v containerd &>/dev/null; then
    mkdir -p /etc/containerd
    if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
        containerd config default 2>/dev/null > /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        log "containerd SystemdCgroup enabled"
    else
        log "containerd SystemdCgroup already set"
    fi

    # set config_path for hosts.toml mirrors (containerd v2.x)
    if ! grep -q 'config_path' /etc/containerd/config.toml 2>/dev/null; then
        sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a\      config_path = "/etc/containerd/certs.d"' \
            /etc/containerd/config.toml 2>/dev/null || true
    fi

    systemctl enable containerd >/dev/null 2>&1 || true
    systemctl restart containerd
    log "containerd restarted"
else
    log "containerd not installed — NKP will install from bundle during bootstrap"
fi

# ── registry mirrors (hosts.toml) — pre-create so NKP picks them up ───────────
mkdir -p "$CERTS_DIR"
for reg in docker.io registry.k8s.io quay.io gcr.io ghcr.io; do
    mkdir -p "$CERTS_DIR/$reg"
    cat > "$CERTS_DIR/$reg/hosts.toml" <<EOF
server = "http://${REGISTRY_IP}:${REGISTRY_PORT}"

[host."http://${REGISTRY_IP}:${REGISTRY_PORT}"]
  capabilities = ["pull", "resolve"]
  skip_verify  = true
EOF
done
log "registry mirrors configured → http://${REGISTRY_IP}:${REGISTRY_PORT}"

log "✓ $(hostname) prerequisites complete"
