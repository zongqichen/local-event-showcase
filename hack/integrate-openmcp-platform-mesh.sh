#!/bin/bash
set -euo pipefail

# WSL2: ensure wsl.exe is in PATH (needed by platform-mesh scripts)
if grep -qi microsoft /proc/version 2>/dev/null; then
    [[ ":$PATH:" != *":/mnt/c/Windows/System32:"* ]] && export PATH="$PATH:/mnt/c/Windows/System32"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HACK_DIR="${SCRIPT_DIR}"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors (matching platform-mesh local setup)
COL='\033[92m'
RED='\033[91m'
YELLOW='\033[93m'
COL_RES='\033[0m'

log() { echo -e "${COL}[$(date '+%H:%M:%S')] $1 ${COL_RES}"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1 ${COL_RES}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $1 ${COL_RES}"; }

# Load environment variables (optional)
if [[ -f "${HACK_DIR}/.env" ]]; then
    source "${HACK_DIR}/.env"
fi

# Default PLATFORM_MESH_DIR to the project-local checkout
PLATFORM_MESH_DIR="${PLATFORM_MESH_DIR:-${PROJECT_DIR}/demo/external/platform-mesh/helm-charts}"

if [[ ! -d "${PLATFORM_MESH_DIR}" ]]; then
    error "PLATFORM_MESH_DIR does not exist: ${PLATFORM_MESH_DIR}"
    exit 1
fi

log "Using PLATFORM_MESH_DIR: ${PLATFORM_MESH_DIR}"

# Check if kind cluster 'platform-mesh' exists
if ! kind get clusters 2>/dev/null | grep -q "^platform-mesh$"; then
    error "kind cluster 'platform-mesh' does not exist."
    warn "Please follow the platform-mesh local setup guide: https://platform-mesh.io/release-0.2/getting-started/"
    exit 1
fi

log "Kind cluster 'platform-mesh' found ✓"

# Export kubeconfig for platform-mesh cluster
KUBECONFIGS_DIR="${HACK_DIR}/.secret/kubeconfigs"
mkdir -p "${KUBECONFIGS_DIR}"
kind get kubeconfig --name platform-mesh > "${KUBECONFIGS_DIR}/platform-mesh.kubeconfig"
log "Exported kubeconfig to ${KUBECONFIGS_DIR}/platform-mesh.kubeconfig ✓"

# Check if platform-mesh resource is ready
PLATFORM_MESH_KUBECONFIG="${KUBECONFIGS_DIR}/platform-mesh.kubeconfig"
if ! KUBECONFIG="${PLATFORM_MESH_KUBECONFIG}" kubectl get platformmesh platform-mesh -n platform-mesh-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
    error "platform-mesh resource is not ready."
    warn "Please ensure platform-mesh is fully deployed: https://platform-mesh.io/release-0.2/getting-started/"
    exit 1
fi

log "platform-mesh resource is ready ✓"

# Patch platform-mesh resource with extraDefaultAPIBindings for opencp and gardener
# gardener.cloud binding now points to the separate root:providers:gardener workspace
log "Patching platform-mesh with extraDefaultAPIBindings..."
KUBECONFIG="${PLATFORM_MESH_KUBECONFIG}" kubectl patch platformmesh platform-mesh -n platform-mesh-system --type=merge -p '
{
  "spec": {
    "kcp": {
      "extraDefaultAPIBindings": [
        {
          "workspaceTypePath": "root:account",
          "export": "opencp.cloud",
          "path": "root:providers:opencp"
        },
        {
          "workspaceTypePath": "root:account",
          "export": "gardener.cloud",
          "path": "root:providers:gardener"
        }
      ]
    }
  }
}'
log "Patched platform-mesh with extraDefaultAPIBindings ✓"

# Copy KCP admin kubeconfig from platform-mesh
KCP_ADMIN_KUBECONFIG="${PLATFORM_MESH_DIR}/.secret/kcp/admin.kubeconfig"
if [[ ! -f "${KCP_ADMIN_KUBECONFIG}" ]]; then
    error "KCP admin kubeconfig not found at ${KCP_ADMIN_KUBECONFIG}"
    exit 1
fi
cp "${KCP_ADMIN_KUBECONFIG}" "${KUBECONFIGS_DIR}/kcp-admin.kubeconfig"
KUBECONFIG="${KUBECONFIGS_DIR}/kcp-admin.kubeconfig" kubectl config use-context workspace.kcp.io/current
log "Copied KCP admin kubeconfig to ${KUBECONFIGS_DIR}/kcp-admin.kubeconfig ✓"

# Find and export the first onboarding.* kind cluster kubeconfig
ONBOARDING_CLUSTER=$(kind get clusters 2>/dev/null | grep -E "^onboarding" | head -n 1 || true)
if [[ -z "${ONBOARDING_CLUSTER}" ]]; then
    warn "No onboarding.* kind cluster found. Available clusters:"
    kind get clusters 2>/dev/null || echo "  (none)"
    warn "Skipping onboarding kubeconfig export"
else
    log "Found onboarding cluster: ${ONBOARDING_CLUSTER}"
    kind get kubeconfig --name "${ONBOARDING_CLUSTER}" > "${KUBECONFIGS_DIR}/onboarding.kubeconfig"
    log "Exported onboarding kubeconfig to ${KUBECONFIGS_DIR}/onboarding.kubeconfig ✓"
fi

# Generate operator manifests
OPERATOR_DIR="${SCRIPT_DIR}/../demo/openmcp-init-operator"
log "Generating openmcp-init-operator manifests..."
(cd "${OPERATOR_DIR}" && task generate)
log "Generated openmcp-init-operator manifests ✓"

# Generate gardener-init-operator manifests
GARDENER_OPERATOR_DIR="${SCRIPT_DIR}/../demo/gardener-init-operator"
log "Generating gardener-init-operator manifests..."
(cd "${GARDENER_OPERATOR_DIR}" && task generate)
log "Generated gardener-init-operator manifests ✓"

# Prepare provider workspaces
KCP_KUBECONFIG="${KUBECONFIGS_DIR}/kcp-admin.kubeconfig"
KUBECONFIG="${KCP_KUBECONFIG}" kubectl create-workspace providers --type=root:providers --ignore-existing --server="https://localhost:8443/clusters/root"
KUBECONFIG="${KCP_KUBECONFIG}" kubectl create-workspace opencp --type=root:provider --ignore-existing --server="https://localhost:8443/clusters/root:providers"
KUBECONFIG="${KCP_KUBECONFIG}" kubectl create-workspace gardener --type=root:provider --ignore-existing --server="https://localhost:8443/clusters/root:providers"
log "Created provider workspaces (opencp + gardener) ✓"

# Copy openmcp-init-operator API resources to demo manifests directory for deployment
# (gardener resources are NOT copied here — they live in the separate gardener provider dir)
MANIFESTS_DIR="${SCRIPT_DIR}/../demo/manifests"
OPENCP_MANIFESTS_DIR="${MANIFESTS_DIR}/providers/opencp"
OPENCP_API_DIR="${OPENCP_MANIFESTS_DIR}/api"
OPENCP_CONFIG_DIR="${OPENCP_MANIFESTS_DIR}/config"
log "Copying opencp API resources to ${OPENCP_API_DIR}..."
cp "${OPERATOR_DIR}/config/resources/"*.yaml "${OPENCP_API_DIR}/"
log "Copied opencp API resources ✓"

# Copy gardener-init-operator API resources to gardener provider manifests directory
GARDENER_MANIFESTS_DIR="${MANIFESTS_DIR}/providers/gardener"
GARDENER_API_DIR="${GARDENER_MANIFESTS_DIR}/api"
GARDENER_CONFIG_DIR="${GARDENER_MANIFESTS_DIR}/config"
log "Copying gardener API resources to ${GARDENER_API_DIR}..."
cp "${GARDENER_OPERATOR_DIR}/config/resources/"*.yaml "${GARDENER_API_DIR}/"
log "Copied gardener API resources ✓"

# Lookup identityHash from core.platform-mesh.io APIExport
log "Looking up identityHash from core.platform-mesh.io APIExport..."
PLATFORM_MESH_SYSTEM_URL="https://localhost:8443/clusters/root:platform-mesh-system"
CONTENT_CONFIG_IDENTITY_HASH=$(KUBECONFIG="${KCP_KUBECONFIG}" kubectl get apiexport core.platform-mesh.io \
    --server="${PLATFORM_MESH_SYSTEM_URL}" \
    -o jsonpath='{.status.identityHash}')
log "Found identityHash: ${CONTENT_CONFIG_IDENTITY_HASH}"

# Patch copied consumer APIExport with contentconfigurations identityHash
APIEXPORT_FILE="${OPENCP_API_DIR}/apiexport-opencp.cloud.yaml"
log "Patching consumer APIExport with contentconfigurations identityHash..."
yq -i "(.spec.permissionClaims[] | select(.resource == \"contentconfigurations\")).identityHash = \"${CONTENT_CONFIG_IDENTITY_HASH}\"" "${APIEXPORT_FILE}"
log "Patched consumer APIExport file ✓"

OPENCP_WORKSPACE_URL="https://localhost:8443/clusters/root:providers:opencp"

# Step 1: Apply APIResourceSchemas (opencp only)
log "Applying APIResourceSchemas to opencp provider workspace..."
for f in "${OPENCP_API_DIR}"/apiresourceschema-*.yaml; do
    KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "$f" --server="${OPENCP_WORKSPACE_URL}" --server-side --force-conflicts
done
log "Applied APIResourceSchemas ✓"

# Step 2: Apply consumer APIExport
log "Applying consumer APIExport..."
KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "${APIEXPORT_FILE}" --server="${OPENCP_WORKSPACE_URL}" --server-side --force-conflicts
log "Applied consumer APIExport ✓"

# Step 3: Config manifests (ContentConfiguration, RBAC) for opencp provider
log "Applying config manifests..."
KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "${OPENCP_CONFIG_DIR}" --server="${OPENCP_WORKSPACE_URL}" --server-side --force-conflicts
log "Applied config manifests ✓"

# ─── Gardener Provider Workspace Setup ───
GARDENER_WORKSPACE_URL="https://localhost:8443/clusters/root:providers:gardener"

# Apply APIResourceSchemas to gardener provider workspace
log "Applying APIResourceSchemas to gardener provider workspace..."
for f in "${GARDENER_API_DIR}"/apiresourceschema-*.yaml; do
    KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "$f" --server="${GARDENER_WORKSPACE_URL}" --server-side --force-conflicts
done
log "Applied gardener APIResourceSchemas ✓"

# Apply gardener.cloud APIExport to gardener provider workspace
GARDENER_APIEXPORT_FILE="${GARDENER_API_DIR}/apiexport-gardener.cloud.yaml"
log "Applying gardener.cloud APIExport to gardener provider workspace..."
KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "${GARDENER_APIEXPORT_FILE}" --server="${GARDENER_WORKSPACE_URL}" --server-side --force-conflicts
log "Applied gardener.cloud APIExport ✓"

# Apply gardener config manifests (ContentConfiguration, RBAC)
log "Applying gardener config manifests..."
KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "${GARDENER_CONFIG_DIR}" --server="${GARDENER_WORKSPACE_URL}" --server-side --force-conflicts
log "Applied gardener config manifests ✓"

# Apply opencp-init WorkspaceType to root workspace
# This type carries initializer: true so the init-agent can watch for new account workspaces
INIT_AGENT_MANIFESTS_DIR="${MANIFESTS_DIR}/init-agent"
ROOT_WORKSPACE_URL="https://localhost:8443/clusters/root"
log "Applying opencp-init WorkspaceType to root workspace..."
KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "${INIT_AGENT_MANIFESTS_DIR}/workspace-type-opencp-init.yaml" \
    --server="${ROOT_WORKSPACE_URL}"
log "Applied opencp-init WorkspaceType ✓"

# Patch account WorkspaceType to extend from opencp-init
# This ensures new account workspaces get the root:opencp-init initializer via transitive extend.with
log "Patching account WorkspaceType to extend from opencp-init..."
KUBECONFIG="${KCP_KUBECONFIG}" kubectl patch workspacetype account \
    --server="${ROOT_WORKSPACE_URL}" \
    --type=json \
    -p '[{"op": "add", "path": "/spec/extend/with/-", "value": {"name": "opencp-init", "path": "root"}}]'
log "Patched account WorkspaceType ✓"

# Apply init-agent manifests (InitTemplate + InitTarget) to the config workspace
# The KCP init-agent reads these to know what resources to create in new workspaces
log "Applying init-agent manifests to platform-mesh-system workspace..."
KUBECONFIG="${KCP_KUBECONFIG}" kubectl apply -f "${INIT_AGENT_MANIFESTS_DIR}" --server="${PLATFORM_MESH_SYSTEM_URL}"
log "Applied init-agent manifests to ${PLATFORM_MESH_SYSTEM_URL} ✓"

# Create operator kubeconfig pointing to the opencp workspace
OPERATOR_KUBECONFIG="${KUBECONFIGS_DIR}/operator.kubeconfig"

# Extract credentials from the admin kubeconfig (using kcp-admin user)
CLIENT_CERT=$(KUBECONFIG="${KCP_KUBECONFIG}" kubectl config view --raw -o jsonpath='{.users[?(@.name=="kcp-admin")].user.client-certificate-data}')
CLIENT_KEY=$(KUBECONFIG="${KCP_KUBECONFIG}" kubectl config view --raw -o jsonpath='{.users[?(@.name=="kcp-admin")].user.client-key-data}')
CA_DATA=$(KUBECONFIG="${KCP_KUBECONFIG}" kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="workspace.kcp.io/current")].cluster.certificate-authority-data}')

# Create a clean kubeconfig with single cluster/context pointing to opencp workspace
cat > "${OPERATOR_KUBECONFIG}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: openmcp
  cluster:
    server: ${OPENCP_WORKSPACE_URL}
    certificate-authority-data: ${CA_DATA}
contexts:
- name: openmcp
  context:
    cluster: openmcp
    user: openmcp
current-context: openmcp
users:
- name: openmcp
  user:
    client-certificate-data: ${CLIENT_CERT}
    client-key-data: ${CLIENT_KEY}
EOF
chmod 600 "${OPERATOR_KUBECONFIG}"
log "Created operator kubeconfig at ${OPERATOR_KUBECONFIG} ✓"

# Create a separate kubeconfig pointing to the gardener provider workspace
GARDENER_OPERATOR_KUBECONFIG="${KUBECONFIGS_DIR}/gardener-operator.kubeconfig"
cat > "${GARDENER_OPERATOR_KUBECONFIG}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: gardener
  cluster:
    server: ${GARDENER_WORKSPACE_URL}
    certificate-authority-data: ${CA_DATA}
contexts:
- name: gardener
  context:
    cluster: gardener
    user: gardener
current-context: gardener
users:
- name: gardener
  user:
    client-certificate-data: ${CLIENT_CERT}
    client-key-data: ${CLIENT_KEY}
EOF
chmod 600 "${GARDENER_OPERATOR_KUBECONFIG}"
log "Created gardener operator kubeconfig at ${GARDENER_OPERATOR_KUBECONFIG} ✓"

# Get platform-mesh control plane Docker IP for cross-cluster access
# The sync agent in MCP clusters needs this IP to reach KCP via hostAliases
PLATFORM_MESH_IP=$(docker inspect platform-mesh-control-plane --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
log "Platform-mesh control plane IP: ${PLATFORM_MESH_IP}"

# Save the IP for the operator to use in hostAliases (maps localhost -> platform-mesh IP)
echo "${PLATFORM_MESH_IP}" > "${KUBECONFIGS_DIR}/platform-mesh-ip.txt"
log "Saved platform-mesh IP to ${KUBECONFIGS_DIR}/platform-mesh-ip.txt ✓"

# Get gardener-local control plane Docker IP (needed by openmcp-init-operator for CoreDNS proxy)
GARDENER_CLUSTER=$(kind get clusters 2>/dev/null | grep -E "^gardener-local$" || true)
GARDENER_IP=""
if [[ -n "${GARDENER_CLUSTER}" ]]; then
    GARDENER_IP=$(docker inspect gardener-local-control-plane --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
    log "Gardener Docker IP: ${GARDENER_IP}"
else
    warn "gardener-local kind cluster not found, gardener IP will not be set"
fi

# Build and deploy the openmcp-init-operator
if [[ -z "${ONBOARDING_CLUSTER}" ]]; then
    error "Cannot deploy operator: no onboarding cluster found"
    exit 1
fi

ONBOARDING_KUBECONFIG="${KUBECONFIGS_DIR}/onboarding.kubeconfig"

# Install Flux on the platform cluster (opencp prerequisite)
PLATFORM_KUBECONFIG="${KUBECONFIGS_DIR}/platform.kubeconfig"
kind get kubeconfig --name platform > "${PLATFORM_KUBECONFIG}"
log "Installing Flux on platform cluster..."
KUBECONFIG="${PLATFORM_KUBECONFIG}" flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller
log "Flux installed on platform cluster ✓"

# Build and push api-syncagent image to local registry
API_SYNCAGENT_DIR="${PROJECT_DIR}/demo/external/api-syncagent"
API_SYNCAGENT_REPO="https://github.com/xrstf/kcp-api-syncagent.git"
API_SYNCAGENT_BRANCH="host-override"
if [ -d "${API_SYNCAGENT_DIR}/.git" ] && (cd "${API_SYNCAGENT_DIR}" && git remote get-url origin) | grep -q "xrstf/kcp-api-syncagent"; then
    log "Updating api-syncagent source..."
    (cd "${API_SYNCAGENT_DIR}" && git fetch origin && git checkout "${API_SYNCAGENT_BRANCH}" && git pull origin "${API_SYNCAGENT_BRANCH}")
else
    log "Cloning api-syncagent (xrstf/host-override branch)..."
    rm -rf "${API_SYNCAGENT_DIR}"
    git clone -b "${API_SYNCAGENT_BRANCH}" "${API_SYNCAGENT_REPO}" "${API_SYNCAGENT_DIR}"
fi
# Build and push via localhost (host-reachable), pods pull via kind-registry (container DNS)
API_SYNCAGENT_TAG="local-$(date +%s)"
API_SYNCAGENT_IMAGE_LOCAL="localhost:5002/kcp-dev/api-syncagent:${API_SYNCAGENT_TAG}"
API_SYNCAGENT_IMAGE="kind-registry:5002/kcp-dev/api-syncagent:${API_SYNCAGENT_TAG}"
log "Building api-syncagent Docker image..."
docker build -t "${API_SYNCAGENT_IMAGE_LOCAL}" "${API_SYNCAGENT_DIR}"
docker push "${API_SYNCAGENT_IMAGE_LOCAL}"
log "Pushed ${API_SYNCAGENT_IMAGE_LOCAL} ✓"

OPERATOR_IMAGE="openmcp-init-operator:local-$(date +%s)"

# Build Docker image
log "Building openmcp-init-operator Docker image..."
docker build -t "${OPERATOR_IMAGE}" "${OPERATOR_DIR}"
log "Built Docker image ${OPERATOR_IMAGE} ✓"

# Load image into the onboarding kind cluster
log "Loading Docker image into ${ONBOARDING_CLUSTER} cluster..."
kind load docker-image "${OPERATOR_IMAGE}" --name "${ONBOARDING_CLUSTER}"
log "Loaded Docker image into ${ONBOARDING_CLUSTER} ✓"

# Create namespace for the operator
OPERATOR_NAMESPACE="openmcp-system"
KUBECONFIG="${ONBOARDING_KUBECONFIG}" kubectl create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | \
    KUBECONFIG="${ONBOARDING_KUBECONFIG}" kubectl apply -f -
log "Created namespace ${OPERATOR_NAMESPACE} ✓"

# Create KCP kubeconfig secret
# Keep localhost in the kubeconfig - hostAliases will map localhost to platform-mesh IP
KCP_OPERATOR_KUBECONFIG=$(sed "s|https://localhost:8443|https://localhost:31000|g" "${OPERATOR_KUBECONFIG}")
KUBECONFIG="${ONBOARDING_KUBECONFIG}" kubectl create secret generic kcp-openmfp-system-kubeconfig \
    --namespace="${OPERATOR_NAMESPACE}" \
    --from-literal=kubeconfig="${KCP_OPERATOR_KUBECONFIG}" \
    --dry-run=client -o yaml | \
    KUBECONFIG="${ONBOARDING_KUBECONFIG}" kubectl apply -f -
log "Created KCP kubeconfig secret ✓"

# Deploy the operator using Helm
log "Deploying openmcp-init-operator to ${ONBOARDING_CLUSTER}..."
helm upgrade --install openmcp-init-operator "${OPERATOR_DIR}/chart" \
    --kubeconfig="${ONBOARDING_KUBECONFIG}" \
    --namespace="${OPERATOR_NAMESPACE}" \
    --set image.name="${OPERATOR_IMAGE%:*}" \
    --set image.tag="${OPERATOR_IMAGE#*:}" \
    --set image.imagePullSecret="" \
    --set image.pullPolicy="Never" \
    --set kcp.apiExportEndpointSliceName="opencp.cloud" \
    --set kcp.platformMeshIP="${PLATFORM_MESH_IP}" \
    --set kcp.hostOverride="localhost:31000" \
    --set gardener.ip="${GARDENER_IP}" \
    --set syncAgent.imageRepository="kind-registry:5002/kcp-dev/api-syncagent" \
    --set syncAgent.imageTag="${API_SYNCAGENT_TAG}" \
    --set "syncAgent.apiExportHostPortOverrides={localhost:8443=localhost:31000}" \
    --set kro.chartURL="oci://registry.k8s.io/kro/charts/kro" \
    --set flux.chartURL="oci://ghcr.io/fluxcd-community/charts/flux2" \
    --set ocm.chartURL="oci://ghcr.io/open-component-model/kubernetes/controller/chart" \
    --set runtime.namespace="default" \
    --set log.level="debug" \
    --set log.noJson=true
log "Deployed openmcp-init-operator ✓"

# Wait for operator to be ready
log "Waiting for operator deployment to be ready..."
KUBECONFIG="${ONBOARDING_KUBECONFIG}" kubectl rollout status deployment/openmcp-init-operator \
    --namespace="${OPERATOR_NAMESPACE}" --timeout=120s
log "Operator is ready ✓"

# ─── Gardener Init Operator (deployed to gardener-local cluster) ───
if [[ -n "${GARDENER_CLUSTER}" ]]; then
    log "Found gardener-local cluster, deploying gardener-init-operator..."

    # Export gardener-local kubeconfig
    GARDENER_RAW_KUBECONFIG="${KUBECONFIGS_DIR}/gardener-local.kubeconfig"
    kind get kubeconfig --name gardener-local > "${GARDENER_RAW_KUBECONFIG}"
    log "Exported gardener-local kubeconfig ✓"

    # The operator runs ON gardener-local, so it can reach Gardener at localhost:443
    # No cross-cluster Docker IP kubeconfig needed for the Gardener API itself

    # Create namespace on gardener-local for the operator
    KUBECONFIG="${GARDENER_RAW_KUBECONFIG}" kubectl create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | \
        KUBECONFIG="${GARDENER_RAW_KUBECONFIG}" kubectl apply -f -
    log "Created namespace ${OPERATOR_NAMESPACE} on gardener-local ✓"

    # Create KCP kubeconfig secret on gardener-local (pointing to gardener provider workspace)
    # hostAliases will map localhost to platform-mesh IP so the operator can reach KCP
    KCP_GARDENER_KUBECONFIG=$(sed "s|https://localhost:8443|https://localhost:31000|g" "${GARDENER_OPERATOR_KUBECONFIG}")
    KUBECONFIG="${GARDENER_RAW_KUBECONFIG}" kubectl create secret generic kcp-openmfp-system-kubeconfig \
        --namespace="${OPERATOR_NAMESPACE}" \
        --from-literal=kubeconfig="${KCP_GARDENER_KUBECONFIG}" \
        --dry-run=client -o yaml | \
        KUBECONFIG="${GARDENER_RAW_KUBECONFIG}" kubectl apply -f -
    log "Created KCP kubeconfig secret on gardener-local ✓"

    # Build gardener-init-operator Docker image
    GARDENER_OPERATOR_IMAGE="gardener-init-operator:local-$(date +%s)"
    log "Building gardener-init-operator Docker image..."
    docker build -t "${GARDENER_OPERATOR_IMAGE}" "${GARDENER_OPERATOR_DIR}"
    log "Built Docker image ${GARDENER_OPERATOR_IMAGE} ✓"

    # Load image into the gardener-local kind cluster (not onboarding)
    log "Loading Docker image into gardener-local cluster..."
    kind load docker-image "${GARDENER_OPERATOR_IMAGE}" --name gardener-local
    log "Loaded Docker image into gardener-local ✓"

    # Deploy the gardener-init-operator to gardener-local using Helm
    log "Deploying gardener-init-operator to gardener-local..."
    helm upgrade --install gardener-init-operator "${GARDENER_OPERATOR_DIR}/chart" \
        --kubeconfig="${GARDENER_RAW_KUBECONFIG}" \
        --namespace="${OPERATOR_NAMESPACE}" \
        --set image.name="${GARDENER_OPERATOR_IMAGE%:*}" \
        --set image.tag="${GARDENER_OPERATOR_IMAGE#*:}" \
        --set image.imagePullSecret="" \
        --set image.pullPolicy="Never" \
        --set kcp.apiExportEndpointSliceName="gardener.cloud" \
        --set kcp.platformMeshIP="${PLATFORM_MESH_IP}" \
        --set kcp.hostOverride="localhost:31000" \
        --set gardener.ip="${GARDENER_IP}" \
        --set runtime.namespace="default" \
        --set log.level="debug" \
        --set log.noJson=true
    log "Deployed gardener-init-operator ✓"

    # Wait for gardener-init-operator to be ready
    log "Waiting for gardener-init-operator deployment to be ready..."
    KUBECONFIG="${GARDENER_RAW_KUBECONFIG}" kubectl rollout status deployment/gardener-init-operator \
        --namespace="${OPERATOR_NAMESPACE}" --timeout=120s
    log "Gardener init operator is ready ✓"
else
    warn "gardener-local kind cluster not found, skipping gardener-init-operator deployment"
fi

# ─── Onboarding UI (deployed to platform-mesh cluster) ───
ONBOARDING_UI_DIR="${PROJECT_DIR}/demo/openmcp-onboarding-ui"
ONBOARDING_UI_IMAGE="openmcp-onboarding-ui:local-$(date +%s)"

log "Building openmcp-onboarding-ui Docker image..."
docker build -t "${ONBOARDING_UI_IMAGE}" "${ONBOARDING_UI_DIR}"
log "Built Docker image ${ONBOARDING_UI_IMAGE} ✓"

log "Loading Docker image into platform-mesh cluster..."
kind load docker-image "${ONBOARDING_UI_IMAGE}" --name platform-mesh
log "Loaded Docker image into platform-mesh ✓"

log "Deploying openmcp-onboarding-ui to platform-mesh..."
helm upgrade --install openmcp-onboarding-ui "${ONBOARDING_UI_DIR}/chart" \
    --kubeconfig="${PLATFORM_MESH_KUBECONFIG}" \
    --namespace="platform-mesh-system" \
    --set image.name="${ONBOARDING_UI_IMAGE%:*}" \
    --set image.tag="${ONBOARDING_UI_IMAGE#*:}" \
    --set image.pullPolicy="Never"
log "Deployed openmcp-onboarding-ui ✓"

log "Waiting for openmcp-onboarding-ui deployment to be ready..."
KUBECONFIG="${PLATFORM_MESH_KUBECONFIG}" kubectl rollout status deployment/openmcp-onboarding-ui \
    --namespace="platform-mesh-system" --timeout=120s
log "Onboarding UI is ready ✓"

log "Integration complete!"
log "Portal URL: https://portal.localhost:8443/"
