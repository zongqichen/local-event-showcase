[![banner](https://raw.githubusercontent.com/platform-mesh/.github/main/profile/banner.svg)](https://platform-mesh.io)

[![REUSE status](https://api.reuse.software/badge/github.com/openmcp-project/local-event-showcase)](https://api.reuse.software/info/github.com/openmcp-project/local-event-showcase)

# local-event-showcase

> **Disclaimer:** The content of this repository is purely meant for showcase and demonstration purposes. It is not recommended for production use.

This repository contains scripts and documentation for setting up a local platform combining **Gardener**, **OpenMCP**, and **Platform Mesh** — suitable for conferences, events, and development demos.

The demo wires together an OpenMCP onboarding cluster with a [Platform Mesh](https://platform-mesh.io) KCP installation so that every new account workspace gets a dedicated MCP instance. Users onboard tools (Crossplane, KRO, Flux, OCM Controller) through dedicated UIs that guide them through activation and configuration.

```mermaid
graph TB
    platform["OpenMCP - Platform\n(kind cluster)"]
    gardener["gardener-local\n(kind cluster)"]
    onboarding["OpenMCP - Onboarding\n(kind cluster)"]

    subgraph pmesh["platform-mesh-system (kind cluster)"]
        aw["Account Workspace\n(KCP)"]
    end

    mcp["OpenMCP - MCP\n(kind cluster, per account)"]

    onboarding -- "requests clusters" --> platform
    platform -- "creates clusters" --> mcp
    aw -- "order MCPs\nconfigure tools" --> onboarding
    mcp -- "sync crossplane resources" --> aw
    mcp -- "reconcile flux/kro/ocm" --> aw
    aw -- "create projects" --> gardener
    aw -- "create shoots" --> mcp
    mcp -- "create shoots" --> gardener
```

### Related Projects

| Project | Documentation |
|---------|---------------|
| **Platform Mesh** | [platform-mesh.io](https://platform-mesh.io) |
| **OpenControlPlanes** | [openmcp-project](https://github.com/openmcp-project) |
| **Gardener** | [gardener.cloud](https://gardener.cloud) |

---

## Requirements

- A machine with at least **8 CPU Cores** and **32 GB RAM** (120 GB+ disk space for Docker)
- [Docker](https://docs.docker.com/get-docker/) (>= 29.x) — with at least 8 CPUs and 8 GB memory allocated
- [kind](https://kind.sigs.k8s.io/)
- [Task](https://taskfile.dev/)
- [Helm](https://helm.sh/)
- [Flux CLI](https://fluxcd.io/flux/cmd/)
- [OCM CLI](https://ocm.software/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [kubectl-kcp plugin](https://docs.kcp.io/kcp/main/setup/kubectl-plugin/) — for KCP workspace management
- [mkcert](https://github.com/FiloSottile/mkcert) — for generating local SSL certificates (required by Platform Mesh)
- [openssl](https://www.openssl.org/) — typically pre-installed on macOS/Linux
- [Go](https://go.dev/) and [Make](https://www.gnu.org/software/make/) — required for building Gardener locally

> **Note:** The setup involves multiple kind clusters and local builds. See the upstream documentation for additional requirements:
> - [Platform Mesh local setup](https://github.com/platform-mesh/helm-charts/tree/main/local-setup)
> - [Gardener local setup](https://gardener.cloud/docs/gardener/deployment/getting_started_locally/)
>
> **Running on WSL2?** See the [WSL2 Setup Guide](docs/wsl2-setup.md) for detailed step-by-step instructions, explanations of every command, and the 6 automatic fixes applied by the scripts.

---

## Setup Instructions

0. **Delete any existing kind clusters** that could conflict with this setup:
   ```bash
   task delete-clusters
   ```
   > **Warning:** This deletes **all** kind clusters on your machine. If you have other kind clusters you want to keep, skip this step and manually delete only the conflicting ones (`platform`, `platform-mesh`, `gardener-local`).

1. **Create the shared kind Docker network** with ICC enabled (required once, before any cluster setup):
   ```bash
   task kind-network
   ```
   > Docker >= 29.x defaults ICC (inter-container communication) to `false` on user-created bridge networks. Without this, containers on the kind network cannot talk to each other, breaking DNS resolution and registry caches.

   The task is idempotent — if the `kind` network already exists with ICC enabled, it's a no-op. If the network exists **without** ICC, the task will fail and ask you to recreate it.

2. **Download the OpenMCP distro** (takes longer, run when necessary):
   ```bash
   task openmcp:clone-distro
   ```

3. **Set up Gardener, Platform Mesh, OpenMCP, and run the integration**:
   ```bash
   task gardener:local platform-mesh:local openmcp:local integrate
   ```

   This single command:
   - Clones Gardener into `demo/external/gardener`, creates a `gardener-local` kind cluster, and starts Gardener
   - Checks out Platform Mesh helm-charts and creates the `platform-mesh` kind cluster with KCP
   - Creates the `platform` kind cluster with Flux, mirrors Crossplane artifacts to the local registry, and deploys OpenMCP
   - Runs the integration script that wires everything together (KCP workspaces, operators, init-agent)

### After Setup

Once the setup completes, you have a running platform with the following kind clusters:

| Cluster | Purpose |
|---------|---------|
| `platform` | Core OpenMCP infrastructure (Flux, openmcp-operator) |
| `platform-mesh` | Runs KCP and the platform portal |
| `gardener-local` | Runs Gardener and the gardener-init-operator |
| `onboarding.*` | Hosts the openmcp-init-operator (created dynamically) |
| `mcp-worker-*` | MCP clusters provisioned per account workspace |

### Useful Tasks

| Task | Description |
|------|-------------|
| `task openmcp:create-mcp` | Manually create an MCP with Crossplane in an account workspace |
| `task openmcp:local:iterate` | Re-render and re-apply openmcp manifests (skips cluster creation) |
| `task platform-mesh:local:iterate` | Update platform-mesh without full rebuild |
| `task deploy-ui` | Build and redeploy only the onboarding UI |
| `task openmcp:export-onboarding-kubeconfig` | Export the onboarding cluster kubeconfig |
| `task openmcp:export-mcp-kubeconfig` | Export the MCP worker cluster kubeconfig |
| `task install-flux` | Install Flux on all MCP worker clusters |
| `task delete-clusters` | Delete all kind clusters |

---

## Examples

The `demo/manifests/examples/` directory contains ready-to-use manifests that demonstrate how to work with the platform tools available in a KCP account workspace. They are structured in two layers:

| Directory | Description |
|-----------|-------------|
| `kustomize/basic-app` | A simple Deployment + Service, deployable to a shoot cluster via Flux |
| `kustomize/basic-shoot` | A Gardener `Shoot` resource that provisions a cluster through KRO |
| `kustomize/basic-kro` | KRO `ResourceGraphDefinition`s for the Shoot and GraphQL Gateway lifecycle |
| `kustomize/basic-ocm` | OCM `Repository`, `Component`, and `Resource` objects for resolving platform-mesh artifacts |
| `kustomize/basic-graphql-gateway` | A `GraphQLGateway` resource that deploys the kubernetes-graphql-gateway into a shoot via the KRO + OCM pipeline |
| `flux/` | Flux `GitRepository` and `Kustomization` resources that deploy the above kustomize overlays onto target clusters, with dependency ordering (e.g. the gateway waits for the shoot, KRO definitions, and OCM components) |
| `shoot-manual/` | A step-by-step manual shoot creation flow using Crossplane `Object` resources and a `GardenerProject` — useful for understanding the underlying mechanics without KRO |

To use the Flux-based examples, apply the `GitRepository` first, then the `Kustomization` resources. The Flux kustomizations encode their dependencies via `dependsOn`, so the intended apply order is:

1. `basic-kro` and `basic-ocm` — no dependencies, can be applied first
2. `basic-shoot` — depends on `basic-kro` (needs the Shoot RGD)
3. `basic-app` — depends on `basic-shoot` (deploys into the provisioned shoot cluster)
4. `basic-graphql-gateway` — depends on `basic-shoot`, `basic-kro`, and `basic-ocm`

---

## Architecture

### Preconditions

The following must be in place before running the integration:

| Component | Description |
|-----------|-------------|
| `platform` kind cluster | Core OpenMCP infrastructure (Flux installed during integration) |
| `onboarding` kind cluster | Hosts the `openmcp-init-operator` |
| `platform-mesh` kind cluster | Runs KCP and the platform portal |
| `platform-mesh` resource | Must be in `Ready` state inside the `platform-mesh` cluster |
| `gardener-local` kind cluster | Runs Gardener and the `gardener-init-operator` (local setup via `hack/setup-gardener-local.sh`) |

### 1. Installation Phase (one-time setup)

```mermaid
sequenceDiagram
    actor Admin as Admin/User
    participant Script as Integration Script<br/>(hack/integrate-openmcp-platform-mesh.sh)
    participant PlatformMesh as platform-mesh cluster<br/>(KCP host)
    participant KCP as KCP<br/>(logical workspaces)
    participant Onboarding as Onboarding Cluster
    participant Platform as Platform Cluster
    participant GardenerLocal as Gardener-Local Cluster

    Admin->>Script: run hack/integrate-openmcp-platform-mesh.sh

    rect rgb(230, 240, 255)
        Note over Script,KCP: Configure KCP workspace hierarchy

        Script->>PlatformMesh: verify platform-mesh resource is Ready
        Script->>KCP: create workspace root:providers
        Script->>KCP: create workspace root:providers:opencp
        Script->>KCP: create workspace root:providers:gardener
        Script->>PlatformMesh: patch platform-mesh extraDefaultAPIBindings<br/>(opencp.cloud → root:providers:opencp, gardener.cloud → root:providers:gardener)
    end

    rect rgb(235, 230, 255)
        Note over Script,KCP: Register OpenMCP as a provider in KCP

        Script->>KCP: lookup identityHash from core.platform-mesh.io APIExport
        Script->>KCP: apply APIExport, RBAC, ProviderMetadata<br/>to root:providers:opencp workspace
        Script->>KCP: apply gardener.cloud APIExport, RBAC<br/>to root:providers:gardener workspace
    end

    rect rgb(230, 255, 230)
        Note over Script,Platform: Deploy infrastructure & operator

        Script->>Platform: install Flux (source, kustomize, helm, notification controllers)
        Script->>Onboarding: create namespace openmcp-system
        Script->>Onboarding: create secret kcp-openmfp-system-kubeconfig
        Script->>Script: build openmcp-init-operator Docker image
        Script->>Onboarding: load image into kind cluster
        Script->>Onboarding: helm install openmcp-init-operator<br/>(namespace: openmcp-system)
        Onboarding-->>Script: operator deployment Ready
        Script->>GardenerLocal: create namespace openmcp-system
        Script->>GardenerLocal: create secret kcp-openmfp-system-kubeconfig<br/>(pointing to root:providers:gardener)
        Script->>Script: build gardener-init-operator Docker image
        Script->>GardenerLocal: load image into kind cluster
        Script->>GardenerLocal: helm install gardener-init-operator<br/>(namespace: openmcp-system)
        GardenerLocal-->>Script: operator deployment Ready
    end
```

### 2. Usage Phase (per new account workspace)

```mermaid
sequenceDiagram
    actor User as User
    participant Portal as Platform Portal
    participant UI as openmcp-onboarding-ui
    participant GQL as kubernetes-graphql-gateway
    participant KCP as KCP<br/>(logical workspaces)
    participant InitAgent as init-agent
    participant Operator as openmcp-init-operator
    participant Onboarding as Onboarding Cluster
    participant MCP as MCP Cluster<br/>(provisioned per account)

    User->>Portal: create account
    Portal->>KCP: create account workspace (type: root:account)

    rect rgb(255, 245, 220)
        Note over KCP,InitAgent: Workspace Initialization (init-agent)

        KCP->>InitAgent: LogicalCluster detected (Initializing state)
        Note over KCP: APIBinding to opencp.cloud already created<br/>via extraDefaultAPIBindings on workspace type.<br/>This enables the ManagedControlPlane and Crossplane APIs in the workspace.
        InitAgent->>KCP: create ManagedControlPlane resource in workspace
        InitAgent->>KCP: remove openmcp initializer from LogicalCluster
        KCP-->>KCP: workspace transitions to Ready
    end

    rect rgb(230, 240, 255)
        Note over KCP,MCP: MCP Provisioning (ManagedControlPlaneReconciler)

        KCP->>Operator: ManagedControlPlane detected

        Note over Operator: CreateMCPSubroutine
        Operator->>Onboarding: create ManagedControlPlane
        Onboarding-->>Operator: MCP cluster provisioned & kubeconfig available
        Operator->>KCP: update ManagedControlPlane status (phase: MCPReady)

        Note over Operator: SetupSyncAgentSubroutine
        Operator->>KCP: create APIExports in workspace<br/>(crossplane/kro/flux/ocm.services.opencp.cloud)
        Operator->>MCP: create Secret kcp-kubeconfig
        Operator->>MCP: helm install api-syncagent<br/>(bridges MCP ↔ KCP workspace)
        Operator->>KCP: update ManagedControlPlane status (phase: Ready)
    end

    rect rgb(235, 230, 255)
        Note over User,KCP: Crossplane Onboarding (openmcp-onboarding-ui)

        User->>Portal: navigate to OpenMCP → Crossplane
        Portal->>UI: load openmcp-onboarding-ui
        UI->>GQL: check APIBinding to crossplane.services.opencp.cloud
        GQL->>KCP: get APIBinding
        KCP-->>GQL: not found
        GQL-->>UI: not found

        UI-->>User: show "Start using Crossplane" button
        User->>UI: click "Start using Crossplane"
        UI->>GQL: create APIBinding to crossplane.services.opencp.cloud
        GQL->>KCP: create APIBinding
        KCP-->>GQL: created
        GQL-->>UI: Crossplane APIs now available in workspace

        UI->>GQL: check Crossplane resource
        GQL->>KCP: get Crossplane
        KCP-->>GQL: not found
        GQL-->>UI: not found
        UI-->>User: show Crossplane configuration<br/>(version: v1.20.1, provider: provider-kubernetes v0.15.0)
        User->>UI: confirm and save
        UI->>GQL: create Crossplane resource
        GQL->>KCP: create Crossplane
    end

    rect rgb(230, 255, 230)
        Note over KCP,MCP: Crossplane Setup (CrossplaneReconciler)

        KCP->>Operator: Crossplane resource detected in account workspace

        Note over Operator: CreateCrossplaneSubroutine
        Operator->>Onboarding: create Crossplane resource<br/>(copies provider spec from KCP)
        Onboarding-->>Operator: Crossplane Ready

        Note over Operator: InitializePublishedResourcesSubroutine
        Operator->>MCP: create PublishedResource: k8s-ProviderConfig
        Operator->>MCP: create PublishedResource: k8s-Object
        Operator->>MCP: create PublishedResource: k8s-ObservedObjectCollection
        MCP-->>KCP: api-syncagent publishes resources to workspace
        Note over KCP: crossplane.services.opencp.cloud APIExport<br/>now includes Crossplane resource APIs

        Note over Operator: DeployContentConfigurationsSubroutine
        Operator->>KCP: create ContentConfigurations for published APIs<br/>(renders ProviderConfig, Object, ObservedObjectCollection<br/>via generic resource UI)
    end
```

### 3. Gardener Provisioning Phase (user-driven per account workspace)

```mermaid
sequenceDiagram
    actor User as User
    participant KCP as KCP<br/>(logical workspaces)
    participant Operator as gardener-init-operator<br/>(on gardener-local)
    participant Gardener as Gardener<br/>(gardener-local)

    Note over KCP: APIBinding to gardener.cloud created<br/>via extraDefaultAPIBindings (from root:providers:gardener)
    Note over User,KCP: GardenerProject is NOT auto-created by init-agent.<br/>Users create it explicitly (e.g. via Crossplane compositions or directly).

    User->>KCP: create GardenerProject resource in workspace

    rect rgb(255, 235, 235)
        Note over KCP,Gardener: Gardener Project Provisioning (GardenerProjectReconciler)

        KCP->>Operator: GardenerProject detected

        Note over Operator: CreateGardenerProjectSubroutine
        Operator->>Gardener: create Project (core.gardener.cloud/v1beta1)
        Gardener-->>Operator: Project Ready, namespace garden-<clusterID> exists
        Operator->>Gardener: create ServiceAccount openmcp in garden-<clusterID>
        Operator->>Gardener: create RoleBinding (admin) for SA
        Operator->>KCP: update GardenerProject status (phase: ProjectReady)

        Note over Operator: SetupGardenerAccessSubroutine
        Operator->>Gardener: create SA token Secret
        Gardener-->>Operator: token available
        Operator->>Operator: build kubeconfig (Gardener API + bearer token)
        Operator->>KCP: store Secret gardener-project-kubeconfig in workspace
        Operator->>KCP: update GardenerProject status (phase: Ready)
    end
```

### 4. Tool Provisioning Phase (KRO, Flux, OCM Controller)

```mermaid
sequenceDiagram
    actor User as User
    participant Portal as Platform Portal
    participant UI as Tool Onboarding UI<br/>(KRO / Flux / OCM)
    participant GQL as kubernetes-graphql-gateway
    participant KCP as KCP<br/>(logical workspaces)
    participant Operator as openmcp-init-operator
    participant MCP as MCP Cluster<br/>(provisioned per account)

    User->>Portal: navigate to OpenMCP → KRO / Flux / OCM Controller
    Portal->>UI: load tool onboarding UI (Angular WebComponent)
    UI->>GQL: check tool availability
    GQL-->>UI: available versions (hardcoded in UI assets)

    UI-->>User: show tool configuration (version selector)
    User->>UI: select version and confirm
    UI->>GQL: create tool enablement resource (KRO / Flux / OCMController)
    GQL->>KCP: create resource in account workspace
    KCP-->>GQL: created
    GQL-->>UI: tool enablement resource created

    rect rgb(230, 255, 230)
        Note over KCP,MCP: Tool Setup (KROReconciler / FluxReconciler / OCMControllerReconciler)

        KCP->>Operator: tool enablement resource detected in account workspace

        Note over Operator: DeployAPIResourceSchemasSubroutine
        Operator->>KCP: deploy APIResourceSchemas and update APIExport<br/>in user's KCP workspace
        KCP-->>Operator: schemas registered, APIExport updated

        Note over Operator: InstallToolSubroutine
        Operator->>MCP: helm install tool<br/>(kubeconfig points to user's KCP workspace)
        MCP-->>Operator: tool controller running, targeting KCP workspace

        Note over Operator: DeployToolContentConfigurationsSubroutine
        Operator->>KCP: create ContentConfigurations for tool APIs<br/>(UI navigation entries in portal)
        Operator->>KCP: update tool resource status (phase: Ready)
    end
```

---

## Key Participants

| Participant | Role |
|-------------|------|
| **Integration Script** | One-time bootstrap: creates KCP workspaces, deploys operator, wires platform-mesh |
| **KCP** | Multi-tenant control plane; hosts logical workspaces, ManagedControlPlane, and Crossplane resources per account |
| **platform-mesh cluster** | Runs KCP and the platform portal; owns the `platform-mesh` resource |
| **init-agent** | Watches LogicalClusters, creates ManagedControlPlane resource per workspace (no longer creates GardenerProject) |
| **openmcp-init-operator** | Reconciles ManagedControlPlane, Crossplane, KRO, Flux, and OCMController resources |
| **openmcp-onboarding-ui** | Angular micro-frontend: guides users through Crossplane, KRO, Flux, and OCM Controller activation and configuration |
| **Onboarding Cluster** | Hosts the `openmcp-init-operator` and `ManagedControlPlane` resources |
| **MCP Cluster** | Provisioned per account; runs Crossplane, tool controllers, and the KCP api-syncagent |
| **Platform Cluster** | Core OpenMCP infrastructure; Flux is installed here during setup |
| **gardener-init-operator** | Reconciles GardenerProject resources: creates Gardener projects, sets up access. Runs on gardener-local cluster. |
| **Gardener (gardener-local)** | Local Gardener installation; provides project-based resource isolation |

---

## Architecture Notes

- The **init-agent** is the [KCP init-agent](https://github.com/kcp-dev/init-agent), deployed by platform-mesh. It is configured via `InitTemplate` and `InitTarget` resources to create a `ManagedControlPlane` resource in each new account workspace. It does **not** create GardenerProject resources — those are user-driven.
- The **openmcp-init-operator** reconciles `ManagedControlPlane`, `Crossplane`, `KRO`, `Flux`, and `OCMController` resources. It runs on the onboarding cluster.
- The **gardener-init-operator** reconciles `GardenerProject` resources. It uses `unstructured.Unstructured` to interact with the Gardener API to avoid pulling in the massive Gardener Go dependency tree. It runs on the **gardener-local** cluster (not the onboarding cluster), giving it direct access to the Gardener API via in-cluster config.
- Gardener is an **independent provider** with its own KCP workspace (`root:providers:gardener`) and APIExport (`gardener.cloud`). This decouples Gardener from the OpenMCP provider workspace.
- `ManagedControlPlane` is the domain resource that triggers MCP provisioning. It carries status phases (`MCPReady`, `Ready`) giving clear visibility into provisioning progress.
- The **openmcp-onboarding-ui** is an Angular micro-frontend with web components for each tool. It detects Crossplane state by checking for the APIBinding to `crossplane.services.opencp.cloud` and the existence of a `Crossplane` resource. It drives a two-step onboarding: activate the tool (creates APIBinding or enablement resource), then configure it.
- Crossplane onboarding is **user-driven** — the operator does not create Crossplane resources automatically. The UI creates the APIBinding and Crossplane resource based on user choices.
- After Crossplane is ready and PublishedResources are created, the api-syncagent adds the published Crossplane resource APIs (ProviderConfig, Object, ObservedObjectCollection) to the `crossplane.services.opencp.cloud` APIExport, making them available in the workspace.
- Network routing from MCP clusters to KCP uses `hostAliases` to map `localhost` to the `platform-mesh` Docker container IP, since KCP listens on `localhost:31000` (NodePort) inside the kind network.
- Published resources (`ProviderConfig`, `Object`, `ObservedObjectCollection`) are only initialized once the target Crossplane on the onboarding cluster reports all `*Ready` conditions as `True`.
- **Crossplane vs. KRO/Flux/OCM architecture**: Crossplane uses a sync-agent bridge — the `api-syncagent` runs on the MCP cluster and bridges resources between KCP and MCP via a dynamic `crossplane.services.opencp.cloud` APIExport. KRO, Flux, and OCM Controller use a simpler direct pattern: the operator deploys APIResourceSchemas into the user's KCP workspace and updates the tool's APIExport, then installs the tool controller on the MCP cluster with a kubeconfig that points at that KCP workspace. The tool controller reconciles against KCP directly, with no sync-agent in between.
- Each tool API group is a separate KCP service domain: `kro.services.opencp.cloud`, `flux.services.opencp.cloud`, and `ocm.services.opencp.cloud`. All three are published via the existing `opencp.cloud` APIExport.

---

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/openmcp-project/local-event-showcase/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/openmcp-project/local-event-showcase/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/SAP/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2026 SAP SE or an SAP affiliate company and local-event-showcase contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/openmcp-project/local-event-showcase).
