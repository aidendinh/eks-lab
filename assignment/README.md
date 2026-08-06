# Two-cluster EKS lab — architecture

A workload cluster running JVM microservices, and a separate observability cluster
that receives its metrics, logs and traces. Everything in AWS is provisioned by
Terraform; the microservices themselves are delivered only by Argo CD.

Region `ap-southeast-1`, account `600627340244`.
The build runbook is [`../implementation.md`](../implementation.md).

## Shape

```
                      VPC 10.0.0.0/16  (one NAT, two AZs)
 ┌──────────────────────────────────┐   ┌──────────────────────────────────┐
 │ CLUSTER 1  eks-workload          │   │ CLUSTER 2  eks-observability     │
 │                                  │   │                                  │
 │ managed node group `platform`    │   │ managed node group               │
 │ 3x t3.medium, tainted            │   │ 2x t3.medium, untainted          │
 │   Karpenter  Argo CD  KEDA       │   │   Prometheus  (remote-write rcvr)│
 │   ESO  CSI drivers  Prometheus   │   │   Grafana     Loki    Tempo      │
 │   Alloy  JavaMelody collector    │   │   ingress-nginx (internal NLB)   │
 │                                  │   │                                  │
 │ Karpenter nodes (apps only)      │   │                                  │
 │  pool 1  spot amd64   frontend   │   │                                  │
 │  pool 2  graviton     inventory  │   │                                  │
 │  pool 3  1 OD : 3 spot  orders   │   │                                  │
 └───────────────┬──────────────────┘   └──────────────▲───────────────────┘
                 │  metrics  remote_write /api/v1/write │
                 │  logs     Alloy      /loki/api/v1/push
                 └──────────  traces    Alloy      /v1/traces
```

Both clusters share one VPC, so all telemetry crosses on private addresses
through an **internal** NLB. Nothing on the ingestion path is internet-facing.

## Terraform layout

`terraform/modules/` — one module per concern:

| Module | Owns |
| --- | --- |
| `vpc` | VPC, subnets, NAT, route tables, the `karpenter.sh/discovery` tags |
| `eks-cluster` | Cluster, IAM, add-ons, managed node groups, optional EBS CSI. Called twice |
| `efs` | Filesystem, mount targets, security group, EFS CSI driver + Pod Identity |
| `karpenter` | Controller IAM, SQS interruption queue, EventBridge rules |
| `secrets` | The single `eks-lab` Secrets Manager secret and ESO's IAM |
| `karpenter-controller` | Karpenter Helm release + EC2NodeClass + the three NodePools |
| `external-secrets` | ESO Helm release, ClusterSecretStore, ExternalSecrets. Called twice |
| `keda` | KEDA Helm release |
| `gitops` | Argo CD Helm release + the Application |
| `observability-stack` | Prometheus, Grafana, Loki, Tempo, ingress-nginx, telemetry Ingress |
| `telemetry-agents` | Workload-side Prometheus forwarder + Alloy |
| `javamelody-collector` | The aggregating collector server |

`terraform/envs/lab/` is split into two roots:

- **`10-infra`** — pure AWS. Both clusters, VPC, EFS, IAM, SQS, Secrets Manager.
- **`20-platform`** — everything inside the clusters, reading `10-infra`'s outputs.

The split is not cosmetic. A Kubernetes or Helm provider must be configured with
a cluster endpoint, and that value is unknown until the cluster exists — a
provider cannot be configured from a resource created in the same apply. Two
roots make the dependency explicit and make `destroy` unwind in the right order.

## How each requirement is met

| Requirement | Where |
| --- | --- |
| Modular Terraform, both clusters | `terraform/modules/*`, `terraform/envs/lab/{10-infra,20-platform}` |
| Managed node group hosts infra only | `platform` group is tainted `dedicated=platform:NoSchedule`; every platform component carries the matching toleration |
| Karpenter pool 1 — Spot, amd64, ≤ t3.medium | NodePool `general-spot-amd64` |
| Karpenter pool 2 — Graviton arm64, ≤ t4g.medium | NodePool `graviton-arm64` |
| Karpenter pool 3 — On-Demand + Spot 1:3 | NodePools `microservices-spot` (weight 100) + `microservices-on-demand` (weight 10) |
| PVs backed by EFS, dynamic provisioning | `efs` module + `efs-rwx` StorageClass, `provisioningMode: efs-ap` |
| Topology spread **and** pod anti-affinity | `charts/sample-microservices/templates/deployments.yaml` |
| Microservices only via Argo CD | `gitops` module registers the Application; nothing else applies the chart |
| KEDA for workload autoscaling | `keda` module + `templates/scaledobjects.yaml` |
| Central Prometheus/Grafana/Loki/Tempo | `observability-stack` |
| Metrics / logs / traces shipped cluster 1 → 2 | `telemetry-agents` |
| JavaMelody monitoring the JVMs | `javamelody-collector` + `orders` self-registration |
| All secrets in one `eks-lab` secret, synced by ESO | `secrets` + `external-secrets` |

## Where the 1:3 ratio comes from

The assignment requires the On-Demand:Spot ratio to *emerge from Kubernetes
scheduling*, not from a hardcoded fleet. It does:

1. `orders` asks for **4 replicas**, pinned to amd64, with pod anti-affinity on
   `kubernetes.io/hostname` and `minDomains: 4` on the hostname spread
   constraint. No two replicas may share a node, so four nodes are required.
2. Both halves of pool 3 can satisfy those pods, but `microservices-spot` has
   `weight: 100` against `microservices-on-demand`'s `10`, so Karpenter reaches
   for Spot first.
3. `microservices-spot` has `limits.cpu: 6`. At 2 vCPU per `t3.medium` that is
   three nodes. The fourth replica is still Pending, and the only remaining pool
   that can take it is On-Demand — which is capped at `limits.cpu: 2`, one node.

Result: 1 On-Demand + 3 Spot. Nothing anywhere names a fleet or an instance
count — change `replicaCount` and the shape changes with it. The vCPU limits are
capacity ceilings, the same knob you would set to bound spend; they are not a
list of machines to launch.

## Deliberate choices

- **Pod Identity, not IRSA.** No per-role OIDC trust policy and no service
  account annotations; the association is a first-class API object.
- **One Secrets Manager secret.** Secrets Manager bills per secret and ESO can
  address any JSON property via `remoteRef.property`, so grouping costs nothing.
- **EFS over EBS for the app claim.** One `ReadWriteMany` claim is shared by three
  Deployments spread over two AZs. EBS is zonal and `ReadWriteOnce`.
- **Terraform owns platform Helm releases; Argo CD owns applications.** The
  cluster is reproducible from `terraform apply`, and the GitOps constraint —
  no kubectl-applied app manifests — still holds for everything in
  `charts/sample-microservices`.
- **`t3.medium` everywhere**, including the managed node groups. Three
  `t3.medium` cost slightly less than two `t3.large` and give more vCPU, while
  respecting the size cap the Karpenter pools are held to.

## Applications

Three services, same HTTP contract (`/work`, `/healthz`, `/readyz`, `/metrics`):

- **frontend** (Python) — entry point, calls the other two. KEDA scales it.
- **inventory** (Python) — runs on Graviton; proves the images are multi-arch.
- **orders** (Java, Spring Boot 3 + JavaMelody) — the JVM under observation.

All three mount the same EFS-backed `ReadWriteMany` volume at `/data`.
