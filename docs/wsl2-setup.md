# WSL2 Setup Guide

This guide documents the WSL2-specific issues encountered when running the local-event-showcase setup and the automatic fixes applied by the scripts. The standard setup (`task gardener:local platform-mesh:local openmcp:local integrate`) works on macOS but fails on WSL2 due to Docker bridge networking limitations and tool compatibility issues.

All fixes are applied automatically by the scripts when WSL2 is detected (`grep -qi microsoft /proc/version`). No manual steps are required beyond what's in the main README.

---

## Prerequisites

Same as the main [README](../README.md#requirements), plus:

- **WSL2** (kernel 6.6+) with systemd enabled
- **Docker Desktop for Windows** with WSL2 backend, or Docker CE installed directly in WSL2
- Sufficient resources: 8+ CPU cores, 32 GB+ RAM, 120 GB+ disk (same as macOS, but WSL2 may need explicit memory limits in `.wslconfig`)

---

## Setup Steps

> All commands are run inside the WSL2 terminal.

### 0. Delete existing kind clusters (optional)

```bash
task delete-clusters
```

Removes all kind clusters on the machine. Skip if you have clusters you want to keep.

### 1. Create the shared Docker network

```bash
task kind-network
```

Creates a Docker bridge network named `kind` with:
- **Subnet `172.18.0.0/16`** — all kind clusters share this network so containers can reach each other.
- **ICC enabled** (`com.docker.network.bridge.enable_icc=true`) — Docker >= 29.x defaults ICC to `false` on user-created bridge networks. Without ICC, containers on the same bridge cannot communicate, which breaks DNS (bind9) and registry caches.
- **IPv6 subnet `fd00:10::/64`** — required by Gardener's kind config for dual-stack support.

### 2. Start the local OCI registry

```bash
task local-registry
```

Starts a Docker container named `kind-registry` on port `5002`, attached to the `kind` network. This is an **HTTP** (not HTTPS) registry. Helm OCI push (`helm push`) always uses HTTP for `oci://` URLs regardless of `--ca-file`, so HTTPS would cause `400 Bad Request` errors. All kind nodes are configured to pull from `kind-registry:5002` over HTTP via containerd's `hosts.toml`.

### 3. Download the OpenMCP distro

```bash
task openmcp:clone-distro
```

Uses the OCM CLI to transfer OpenMCP components (openmcp-operator, cluster-provider-kind, service-provider-crossplane) from `ghcr.io/openmcp-project/components` into the local registry. This is a large download (~2 GB) and only needs to run once.

### 4. Set up Gardener

```bash
task gardener:local
```

Runs [`hack/setup-gardener-local.sh`](../hack/setup-gardener-local.sh), which:

1. **Clones Gardener** into `demo/external/gardener/` (if not already present).

2. **Patches Gardener's `kind-up.sh`** — disables `setup_kind_network()` because we manage the kind network ourselves (step 1). Gardener's network setup validates subnet size and rejects our `/16` subnet.

3. **Patches `docker-compose.yaml`** — gives bind9 a static IP `172.18.255.53` on the kind bridge and disables IPv6 port bindings for bind9 (`fd00:ff::53`). Docker Desktop on macOS/WSL2 cannot bind to IPv6 loopback addresses.

4. **(WSL2 Fix 1) Pre-downloads calico manifest:**
   ```bash
   curl -sL -o "$CALICO_BASE_DIR/calico.yaml" "$CALICO_URL"
   sed -i "s|^- https://.*calico.yaml$|- calico.yaml|" "$CALICO_KUSTOMIZATION"
   ```
   **Why:** Gardener's `make kind-up` runs kustomize which fetches `calico.yaml` from `raw.githubusercontent.com` at build time. At this point, the host's `/etc/resolv.conf` already points to bind9 at `10.255.255.254` (set by Gardener's `kind-up.sh`). On WSL2, bind9 is unreachable because Docker bridge inter-container UDP is unreliable. The download fails with `dial udp 10.255.255.254:53: connect: resource temporarily unavailable`. Downloading the manifest beforehand and patching the kustomization to use the local file avoids this DNS dependency.

5. **(WSL2 Fix 2) Splits `make kind-up` and `make gardener-up`:**

   On macOS/Linux, Gardener runs `make kind-up gardener-up` as a single command. On WSL2, we split it into two steps and fix DNS in between:

   **Step A — `make kind-up`:** Creates the `gardener-local` kind cluster and starts the bind9 + registry containers via docker-compose.

   **Step B — Fix kind node DNS:**
   ```bash
   # Remove unreachable IPv6 DNS entry and add 8.8.8.8 as fallback
   docker exec gardener-local-control-plane bash -c '
       grep -v "fd00:ff::53" /etc/resolv.conf > /tmp/resolv.new
       echo "nameserver 8.8.8.8" >> /tmp/resolv.new
       cp /tmp/resolv.new /etc/resolv.conf
   '
   ```
   **Why:** The kind node's `/etc/resolv.conf` contains `nameserver fd00:ff::53` (IPv6) and `nameserver 172.18.255.53` (IPv4). On WSL2, bind9 doesn't listen on the IPv6 address, and the IPv4 address is unreachable via Docker bridge UDP. Adding `8.8.8.8` ensures the node can resolve external domains (e.g., `quay.io`, `registry.k8s.io`) to pull container images.

   ```bash
   # Add /etc/hosts entries for Gardener's registry containers
   for container in registry registry-cache-quay ...; do
       IP=$(docker inspect "$container" --format "{{.NetworkSettings.Networks.kind.IPAddress}}")
       docker exec gardener-local-control-plane bash -c "echo '$IP $HOST' >> /etc/hosts"
   done
   ```
   **Why:** Gardener uses local registry caches (e.g., `quay.registry-cache.local.gardener.cloud`) that are resolved by bind9. Since bind9 is unreachable from the kind node on WSL2, we bypass DNS entirely by adding the container IPs directly to `/etc/hosts`. The IP-to-hostname mapping:
   | Container | Hostname |
   |-----------|----------|
   | `registry` | `registry.local.gardener.cloud` |
   | `registry-cache-quay` | `quay.registry-cache.local.gardener.cloud` |
   | `registry-cache-gcr` | `gcr.registry-cache.local.gardener.cloud` |
   | `registry-cache-k8s` | `registry.registry-cache.local.gardener.cloud` |
   | `registry-cache-europe-docker-pkg-dev` | `europe-docker.registry-cache.local.gardener.cloud` |

   ```bash
   # Remove containerd mirror configs that route pulls through bind9-dependent hostnames
   docker exec gardener-local-control-plane bash -c '
       rm -rf /etc/containerd/certs.d/quay.io /etc/containerd/certs.d/gcr.io \
              /etc/containerd/certs.d/registry.k8s.io /etc/containerd/certs.d/europe-docker.pkg.dev
   '
   docker exec gardener-local-control-plane systemctl restart containerd
   ```
   **Why:** Containerd's `hosts.toml` files redirect image pulls through the registry caches (e.g., `quay.io` -> `quay.registry-cache.local.gardener.cloud`). Even with `/etc/hosts` entries, the TLS certificates of these caches may not match, causing pull failures. Removing the mirror configs makes containerd pull directly from upstream registries, using `8.8.8.8` for DNS.

   **Step C — `make gardener-up`:** Deploys Gardener components (apiserver, controller-manager, scheduler, gardenlet) into the kind cluster. This step pulls images from the registry caches — which now work because of the DNS fixes above.

6. **(WSL2 Fix 3) Fixes host DNS order after Gardener setup:**
   ```bash
   sudo bash -c '
       EXISTING=$(grep "^nameserver" /etc/resolv.conf | grep -v "8.8.8.8" || true)
       SEARCH=$(grep "^search" /etc/resolv.conf || true)
       { echo "nameserver 8.8.8.8"; echo "$EXISTING"; [ -n "$SEARCH" ] && echo "$SEARCH"; } > /etc/resolv.conf
   '
   ```
   **Why:** Gardener's `kind-up.sh` overwrites the WSL2 host's `/etc/resolv.conf` to `nameserver 10.255.255.254` (bind9 loopback). On WSL2, this loopback IP is unreliable, causing all subsequent host operations (`docker build`, `git clone`, `curl`) to fail with `Could not resolve host`. This fix puts `8.8.8.8` first so the host can resolve external domains, while keeping `10.255.255.254` as a fallback for Gardener's `*.local.gardener.cloud` domains.

   > **Note:** WSL2 regenerates `/etc/resolv.conf` on restart, so this fix is temporary. After a WSL restart, Gardener's bind9 may not be running, so the default DNS is fine. The fix is only needed during a session where Gardener has been started.

### 5. Set up Platform Mesh

```bash
task platform-mesh:local
```

Clones the [platform-mesh/helm-charts](https://github.com/platform-mesh/helm-charts) repository into `demo/external/platform-mesh/helm-charts/`, checks out the `feat/local-event-showcase` branch, and runs `local-setup:cached:showcase`.

This creates the `platform-mesh` kind cluster running KCP and the platform portal.

**(WSL2 Fix 5) PATH detection:**
```bash
if grep -qi microsoft /proc/version 2>/dev/null; then
    [[ ":$PATH:" != *":/mnt/c/Windows/System32:"* ]] && export PATH="$PATH:/mnt/c/Windows/System32"
fi
```
**Why:** Platform Mesh's local setup script runs `wsl.exe` for WSL2 compatibility checks. On WSL2, `wsl.exe` is at `/mnt/c/Windows/System32/wsl.exe`, but this directory is not always in PATH (depends on WSL config). Adding it to PATH ensures the script can find `wsl.exe`.

### 6. Set up OpenMCP

```bash
task openmcp:local
```

Creates the `platform` kind cluster, installs Flux, mirrors Crossplane artifacts to the local registry, and deploys the OpenMCP operator stack. The kind cluster is configured with containerd `hosts.toml` pointing to the HTTP local registry at `kind-registry:5002`.

### 7. Run the integration

```bash
task integrate
```

Runs [`hack/integrate-openmcp-platform-mesh.sh`](../hack/integrate-openmcp-platform-mesh.sh), which wires everything together:

- Patches the `platform-mesh` resource with `extraDefaultAPIBindings` for `opencp.cloud` and `gardener.cloud`
- Creates KCP provider workspaces (`root:providers:opencp`, `root:providers:gardener`)
- Deploys APIExports, APIResourceSchemas, RBAC, and ContentConfigurations
- Builds and deploys the `openmcp-init-operator` to the onboarding cluster
- Builds and deploys the `gardener-init-operator` to the gardener-local cluster
- Builds and deploys the `openmcp-onboarding-ui` to the platform-mesh cluster

**(WSL2 Fix 5)** Same PATH fix as step 5 — applied at the top of the script.

**(WSL2 Fix 6) Removed `--force-conflicts` from Helm commands:**
```diff
- helm upgrade --install openmcp-init-operator ... --force-conflicts
+ helm upgrade --install openmcp-init-operator ...
```
**Why:** Helm 3.15+ removed the `--force-conflicts` flag (`Error: unknown flag: --force-conflicts`). This flag was used on three `helm upgrade --install` commands (openmcp-init-operator, gardener-init-operator, openmcp-onboarding-ui). Note: `kubectl apply --server-side --force-conflicts` is a different flag and remains valid.

---

## After Setup

Once all steps complete, you have 4+ kind clusters:

```
$ kind get clusters
gardener-local
onboarding.<hash>
platform
platform-mesh
```

Portal is accessible at: **https://portal.localhost:8443/**

See the main [README](../README.md#after-setup) for cluster descriptions and useful tasks.

---

## Summary of WSL2 Fixes

| # | File | Problem | Root Cause | Fix |
|---|------|---------|------------|-----|
| 1 | `setup-gardener-local.sh` | kustomize fails to fetch calico manifest | Host DNS points to unreliable bind9 loopback | Pre-download calico.yaml locally before `make kind-up` |
| 2 | `setup-gardener-local.sh` | Calico/Gardener pods stuck in `ImagePullBackOff` | Kind node cannot reach bind9 at `172.18.255.53` via Docker bridge UDP | Split kind-up/gardener-up; fix node's resolv.conf and /etc/hosts in between |
| 3 | `setup-gardener-local.sh` | `docker build`, `git clone`, `curl` fail after Gardener setup | Host resolv.conf overwritten to bind9 loopback `10.255.255.254` | Put `8.8.8.8` first in host resolv.conf |
| 4 | `Taskfile.yml` | `helm push` returns `400 Bad Request` | Helm OCI push always uses HTTP regardless of `--ca-file` | Switch local registry from HTTPS to HTTP |
| 5 | `integrate-openmcp-platform-mesh.sh`, `Taskfile.yml` | `wsl.exe: not found` | `/mnt/c/Windows/System32` not in PATH | Add Windows System32 to PATH when WSL2 detected |
| 6 | `integrate-openmcp-platform-mesh.sh` | `Error: unknown flag: --force-conflicts` | Helm 3.15+ removed this flag | Remove `--force-conflicts` from `helm upgrade` commands |

### Common root cause

All networking issues (Fix 1-3) stem from **WSL2's Docker bridge networking**. On macOS and native Linux, Docker bridge networks reliably forward UDP packets between containers. On WSL2, the kernel's netfilter bridge module does not reliably forward UDP between containers on user-created bridge networks. Since DNS uses UDP, bind9 at `172.18.255.53` is unreachable from kind nodes, and the bind9 loopback at `10.255.255.254` is unreachable from the host.

---

## Troubleshooting

### DNS stops working after WSL restart

WSL2 regenerates `/etc/resolv.conf` on restart. If you restart WSL and then start Gardener again, the `make kind-up` step will overwrite resolv.conf again. The script handles this automatically — just re-run `task gardener:local`.

### Pods stuck in ImagePullBackOff on gardener-local

Check if the kind node can reach DNS:
```bash
docker exec gardener-local-control-plane nslookup quay.io
```

If this fails, the DNS fix didn't apply correctly. You can manually fix it:
```bash
docker exec gardener-local-control-plane bash -c 'echo "nameserver 8.8.8.8" >> /etc/resolv.conf'
docker exec gardener-local-control-plane systemctl restart containerd
```

### `helm push` fails with 400 Bad Request

Ensure the registry is running in HTTP mode:
```bash
docker logs kind-registry 2>&1 | grep -i tls
```

If you see TLS-related lines, the registry was started with HTTPS. Delete and recreate it:
```bash
task local-registry:delete
task local-registry
```

### Platform Mesh scripts fail with `wsl.exe: not found`

Verify that Windows System32 is accessible:
```bash
ls /mnt/c/Windows/System32/wsl.exe
```

If the file doesn't exist, your WSL2 may not have Windows drives mounted. Check `/etc/wsl.conf`:
```ini
[automount]
enabled = true
```
