#!/bin/bash

DEBUG=${DEBUG:-false}

if [ "${DEBUG}" = "true" ]; then
  set -x
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors (matching existing scripts)
COL='\033[92m'
RED='\033[91m'
YELLOW='\033[93m'
COL_RES='\033[0m'

log() { echo -e "${COL}[$(date '+%H:%M:%S')] $1 ${COL_RES}"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1 ${COL_RES}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $1 ${COL_RES}"; }

GARDENER_DIR="${PROJECT_DIR}/demo/external/gardener"

usage() {
  echo "Usage: $0 [--help]"
  echo ""
  echo "Bootstrap a local Gardener environment."
  echo "Clones Gardener into demo/external/gardener (if not present),"
  echo "creates a 'gardener-local' Kind cluster, and starts Gardener."
  echo ""
  echo "Options:"
  echo "  --help    Show this help message"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage ;;
    --*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) echo "Ignoring positional arg: $1" ;;
  esac
  shift
done

echo -e "${COL}-------------------------------------${COL_RES}"
echo -e "${COL}[$(date '+%H:%M:%S')] Starting Gardener Local Setup ${COL_RES}"
echo -e "${COL}-------------------------------------${COL_RES}"

# Clone gardener if not present
if [ ! -d "$GARDENER_DIR" ]; then
    log "Cloning Gardener repository into $GARDENER_DIR..."
    git clone https://github.com/gardener/gardener.git "$GARDENER_DIR"
else
    log "Gardener repository already exists at $GARDENER_DIR"
fi

# --- Patches for co-existing with other kind clusters ---
# All patches are applied to the cloned Gardener repo (gitignored via demo/external).

KIND_UP_SCRIPT="$GARDENER_DIR/hack/kind-up.sh"
COMPOSE_FILE="$GARDENER_DIR/dev-setup/infra/docker-compose.yaml"

# 1. Disable Gardener's network setup — we manage the kind network via `task kind-network`.
#    Gardener's setup_kind_network() validates subnet size and options, but rejects our
#    /16 subnet (it expects /24) and ICC option. Instead of patching the validation,
#    we simply skip it since the network is already correctly configured.
if grep -q '^setup_kind_network$' "$KIND_UP_SCRIPT" 2>/dev/null; then
    log "Patching kind-up.sh: disabling setup_kind_network (managed by task kind-network)..."
    sed -i.bak 's|^setup_kind_network$|# setup_kind_network # disabled: network managed by task kind-network|' "$KIND_UP_SCRIPT"
    rm -f "${KIND_UP_SCRIPT}.bak"
fi

# 2. Assign bind9 a static IP (172.18.255.53) on the kind Docker network.
#    On macOS, the loopback IPs on lo0 are not reachable from inside Docker containers.
#    Kind nodes resolve DNS via /etc/resolv.conf pointing to 172.18.255.53.
#    Giving bind9 this IP directly on the bridge makes it reachable without host loopback.
if ! grep -q 'ipv4_address: 172.18.255.53' "$COMPOSE_FILE" 2>/dev/null; then
    log "Patching docker-compose.yaml: bind9 static IP 172.18.255.53..."
    sed -i.bak '/^  bind9:/,/^  [a-z]/{
        s|^\(    networks:\)$|\1|
        s|^\(      kind:\)$|\1\n        ipv4_address: 172.18.255.53|
    }' "$COMPOSE_FILE"
    rm -f "${COMPOSE_FILE}.bak"
fi

# 3. Disable IPv6 port bindings for bind9 — Docker Desktop on macOS cannot bind
#    to fd00:ff::53 on the loopback interface (IPv6 addresses are not mirrored into the VM).
if grep -q '^\s*- "\[fd00:ff::53\]:53:53' "$COMPOSE_FILE" 2>/dev/null; then
    log "Patching docker-compose.yaml: disabling bind9 IPv6 port bindings (unsupported on Docker Desktop macOS)..."
    sed -i.bak 's|^\(\s*\)- "\[fd00:ff::53\]:53:53/\(.*\)"$|\1# - "[fd00:ff::53]:53:53/\2"  # disabled: Docker Desktop macOS|' "$COMPOSE_FILE"
    rm -f "${COMPOSE_FILE}.bak"
fi

# --- WSL2-specific patches ---
IS_WSL2=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL2=true
fi

# Fix 1: Pre-download calico manifest to avoid DNS issues during kustomize build.
#   On WSL2, host DNS points to bind9 (10.255.255.254) which may be unreliable at
#   this point. Kustomize fetches calico from GitHub at build time — this fails.
if $IS_WSL2; then
    CALICO_BASE_DIR="$GARDENER_DIR/dev-setup/kind/calico/base"
    CALICO_KUSTOMIZATION="$CALICO_BASE_DIR/kustomization.yaml"
    if grep -q 'raw.githubusercontent.com' "$CALICO_KUSTOMIZATION" 2>/dev/null; then
        log "WSL2: downloading calico manifest locally (avoids DNS issues)..."
        CALICO_URL=$(grep 'raw.githubusercontent.com' "$CALICO_KUSTOMIZATION" | sed 's/^- //')
        curl -sL -o "$CALICO_BASE_DIR/calico.yaml" "$CALICO_URL"
        sed -i.bak "s|^- https://.*calico.yaml$|- calico.yaml|" "$CALICO_KUSTOMIZATION"
        rm -f "${CALICO_KUSTOMIZATION}.bak"
        log "WSL2: calico manifest downloaded and kustomization patched ✓"
    fi
fi

# Check if gardener-local kind cluster exists and Gardener is running
if ! kind get clusters 2>/dev/null | grep -q "^gardener-local$"; then
    # Fix 2: On WSL2, split kind-up and gardener-up to fix DNS between them.
    #   Docker bridge inter-container UDP is unreliable on WSL2 — kind nodes cannot
    #   query bind9 at 172.18.255.53. We fix resolv.conf and add /etc/hosts entries
    #   for registry containers after kind-up, before gardener-up.
    if $IS_WSL2; then
        log "WSL2: running kind-up and gardener-up separately with DNS fix..."
        pushd "$GARDENER_DIR" > /dev/null
        make kind-up
        popd > /dev/null

        log "WSL2: fixing kind node DNS and registry resolution..."
        # Remove unreachable IPv6 DNS and add 8.8.8.8 as fallback
        docker exec gardener-local-control-plane bash -c '
            grep -v "fd00:ff::53" /etc/resolv.conf > /tmp/resolv.new
            echo "nameserver 8.8.8.8" >> /tmp/resolv.new
            cp /tmp/resolv.new /etc/resolv.conf
        '
        # Add /etc/hosts entries for registry containers (bypass bind9)
        for container in registry registry-cache-quay registry-cache-gcr registry-cache-k8s registry-cache-europe-docker-pkg-dev; do
            IP=$(docker inspect "$container" --format "{{.NetworkSettings.Networks.kind.IPAddress}}" 2>/dev/null || true)
            [ -z "$IP" ] && continue
            case "$container" in
                registry) HOST="registry.local.gardener.cloud" ;;
                registry-cache-quay) HOST="quay.registry-cache.local.gardener.cloud" ;;
                registry-cache-gcr) HOST="gcr.registry-cache.local.gardener.cloud" ;;
                registry-cache-k8s) HOST="registry.registry-cache.local.gardener.cloud" ;;
                registry-cache-europe-docker-pkg-dev) HOST="europe-docker.registry-cache.local.gardener.cloud" ;;
            esac
            docker exec gardener-local-control-plane bash -c "echo '$IP $HOST' >> /etc/hosts"
        done
        # Remove containerd mirror configs that point to bind9-dependent hostnames
        docker exec gardener-local-control-plane bash -c '
            rm -rf /etc/containerd/certs.d/quay.io /etc/containerd/certs.d/gcr.io \
                   /etc/containerd/certs.d/registry.k8s.io /etc/containerd/certs.d/europe-docker.pkg.dev
        '
        docker exec gardener-local-control-plane systemctl restart containerd
        log "WSL2: fixed kind node DNS ✓"

        pushd "$GARDENER_DIR" > /dev/null
        make gardener-up
        popd > /dev/null
    else
        log "Creating Kind cluster and starting Gardener..."
        pushd "$GARDENER_DIR" > /dev/null
        make kind-up gardener-up
        popd > /dev/null
    fi
else
    log "Kind cluster 'gardener-local' already exists"
    # Check if Gardener pods are running; if not, start Gardener
    if ! kubectl --context kind-gardener-local get pods -n garden -l app=gardener-apiserver --no-headers 2>/dev/null | grep -q "Running"; then
        warn "Gardener does not seem to be running. Starting Gardener..."
        pushd "$GARDENER_DIR" > /dev/null
        make gardener-up
        popd > /dev/null
    else
        log "Gardener is already running"
    fi
fi

# Fix 3: On WSL2, Gardener's kind-up.sh sets /etc/resolv.conf to bind9 loopback
#   (10.255.255.254) which is unreliable. Ensure 8.8.8.8 is the primary nameserver
#   so subsequent operations (docker build, git clone, curl) don't fail.
if $IS_WSL2; then
    if ! head -1 /etc/resolv.conf | grep -q "8.8.8.8"; then
        log "WSL2: fixing host DNS order (8.8.8.8 first)..."
        sudo bash -c '
            EXISTING=$(grep "^nameserver" /etc/resolv.conf | grep -v "8.8.8.8" || true)
            SEARCH=$(grep "^search" /etc/resolv.conf || true)
            { echo "nameserver 8.8.8.8"; echo "$EXISTING"; [ -n "$SEARCH" ] && echo "$SEARCH"; } > /etc/resolv.conf
        '
        log "WSL2: host DNS fixed ✓"
    fi
fi

kubectl config use-context kind-gardener-local || true

echo -e "${COL}-------------------------------------${COL_RES}"
echo -e "${COL}[$(date '+%H:%M:%S')] Gardener Local Setup Complete ${RED}♥${COL} !${COL_RES}"
echo -e "${COL}-------------------------------------${COL_RES}"
echo ""
echo -e "Gardener is running on Kind cluster ${YELLOW}kind-gardener-local${COL_RES}"
echo ""
echo -e "To access the Gardener cluster:"
echo -e "  ${YELLOW}kubectl config use-context kind-gardener-local${COL_RES}"
echo ""

exit 0
