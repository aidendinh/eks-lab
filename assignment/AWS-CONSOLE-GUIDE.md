# AWS Console guide — two-cluster EKS lab

**This is the complete build, in the order the work actually happens.** Sections 1–4: free prep (network, IAM). Section 5: ECR and the container images — done **before** any cluster exists, because they need none and the meter has not started. Sections 6–8: the clusters, through the console. Section 9: everything the console cannot do (kubectl, Helm, Argo CD, validation). Section 12: teardown. Work top to bottom; each section depends on the ones before it.

**Do not mix with Terraform.** `assignment/terraform/` builds the same resources; running both creates duplicates and orphans. Following this guide means ignoring that directory.

**Three checkpoints are yours to build** — EBS CSI (9.3), Karpenter (9.8), optionally EFS (9.9). The first two are hard blockers; read 9.0 before creating anything billable.

Region: **`ap-southeast-1`**, account **`600627340244`** — check both before every section. Paths are relative to the repo root; run all commands from there.

---

## 0. Cost discipline

Everything bills per hour of existence, not usage. One-sitting build ≈ **$5–7**; left running ≈ **$450–500/month**. Control planes cannot be paused, only deleted.

Hourly lines: two control planes $0.20, NAT $0.06 + $0.06/GB, unattached EIP $0.005, four managed nodes $0.08–0.15 (two now On-Demand), NLB $0.03, four Karpenter nodes $0.05–0.12, EBS ~$0.08/GB-month.

Build, validate, capture evidence, tear down — one sitting. Teardown keeps the free skeleton (subnets, route table, IAM roles, empty ECR repo) so a rebuild starts at section 6. If you must stop partway, delete in order of burn: clusters, NAT + EIP, EC2 instances.

The section ordering is itself cost discipline: sections 1–5 are free or cents and can be done days ahead; the hourly clock starts at section 6 and everything after it is one sitting.

---

## 1. Before you open the console

### 1.1 Identity and IP

```powershell
$env:AWS_PROFILE = "AWS"
$env:AWS_REGION  = "ap-southeast-1"
aws sts get-caller-identity
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
```

Expect account `600627340244`. Note the IP — both cluster endpoints get locked to `<YOUR_IP>/32`. Residential IPs change; if kubectl later times out, re-check this first. Sign in to the console with the **same SSO role** as the `AWS` profile — mismatching them is the usual cause of kubectl `Unauthorized` (9.2).

### 1.2 Tags — apply on every resource

| Key | Value |
| --- | --- |
| `Project` | `eks-two-cluster-assignment` |
| `Environment` | `lab` |
| `ManagedBy` | `AWSConsole` |
| `Owner` | `assignment` |

### 1.3 Existing inventory

**VPC → Your VPCs** → `vpc-08d8dfa1dbf84383e`, CIDR `172.31.0.0/16`. Capture the **Resource map** (before-state evidence).

| Subnet ID | AZ | CIDR | Role |
| --- | --- | --- | --- |
| `subnet-01de873e0d12d027c` | `ap-southeast-1a` | `172.31.16.0/20` | Public — NAT goes here |
| `subnet-057c957d73093257d` | `ap-southeast-1b` | `172.31.32.0/20` | Public — untouched |
| `subnet-000163333befba9dc` | `ap-southeast-1c` | `172.31.0.0/20` | Public — untouched |

Confirm `rtb-030293eb7e6fd8f3a` routes `0.0.0.0/0` to an IGW, and no NAT gateway already exists in the VPC. **Do not modify the existing subnets, route table, or IGW** — everything here is additive.

---

## 2. Private network

### 2.1 Private subnet A

**VPC → Subnets → Create subnet**

| Field | Value |
| --- | --- |
| VPC | `vpc-08d8dfa1dbf84383e` |
| Name | `eks-lab-private-a` |
| AZ | `ap-southeast-1a` |
| CIDR | `172.31.48.0/20` |

Add tags, create. Then two settings the wizard skips:

1. **Actions → Edit subnet settings** → confirm auto-assign public IPv4 is **off**.
2. **Tags** → add `kubernetes.io/role/internal-elb` = `1`. Without this the internal NLB in 9.4 has nowhere to go and the Service sits `<pending>` forever.

Record the ID as `PRIVATE_SUBNET_A_ID`.

### 2.2 Private subnet B

Repeat with name `eks-lab-private-b`, AZ `ap-southeast-1b`, CIDR `172.31.64.0/20`. Same auto-assign check, same `internal-elb` tag. Record `PRIVATE_SUBNET_B_ID`.

Two AZs is mandatory — EKS refuses cluster creation with subnets in fewer than two.

### 2.3 NAT gateway

**VPC → NAT gateways → Create NAT gateway**

| Field | Value |
| --- | --- |
| Name | `eks-lab-nat` |
| Subnet | `subnet-01de873e0d12d027c` (**public** `1a`) |
| Connectivity | Public |
| Elastic IP | **Allocate Elastic IP** |

Tags, create, wait for **Available**. The NAT lives in a *public* subnet; the route pointing at it lives in the *private* route table — that is the whole mechanism. One NAT for both AZs is a deliberate lab cost compromise (production: one per AZ). Bills ~$0.06/hr from now — if you are doing the free prep days ahead, this is the one resource in sections 1–5 to defer to build day.

### 2.4 Private route table

**VPC → Route tables → Create route table** — name `eks-lab-private`, same VPC, tags.

- **Routes → Edit routes**: add `0.0.0.0/0` → NAT `eks-lab-nat`.
- **Subnet associations**: tick **only** the two private subnets. Associating a public subnet by accident kills the NAT's own egress — check the list before saving.

### 2.5 Checkpoint — all must be true

- [ ] NAT state **Available**
- [ ] Both private subnets: auto-assign public IPv4 = **No**
- [ ] Both associated with `eks-lab-private`
- [ ] `eks-lab-private` has `0.0.0.0/0 → nat-...` and **no** IGW route
- [ ] Both carry `kubernetes.io/role/internal-elb = 1`
- [ ] The three public subnets still use `rtb-030293eb7e6fd8f3a` with their IGW route

---

## 3. IAM roles

Three roles, all free, all kept at teardown.

### 3.1 Cluster service role

**IAM → Roles → Create role** → AWS service → **EKS - Cluster** (auto-attaches `AmazonEKSClusterPolicy`; add nothing else) → name `eks-lab-cluster-role`, tags. Confirm trust principal is `eks.amazonaws.com`. Shared by both clusters.

### 3.2 Workload node role

AWS service → **EC2**, attach exactly three policies:

- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryPullOnly`
- `AmazonEKS_CNI_Policy`

Name `eks-lab-workload-node-role`, tags. Trust: `ec2.amazonaws.com`.

**Attach nothing else, ever.** A node-role permission is a permission for every container on the node. Application permissions go through Pod Identity per service account. (`AmazonEKS_CNI_Policy` on the node role is itself a lab simplification — the cleaner pattern gives the CNI its own Pod Identity.)

### 3.3 Observability node role

Identical, named `eks-lab-observability-node-role`.

---

## 4. Encryption: do nothing, deliberately

**Create no KMS key; leave secrets-encryption empty in both wizards.** Since 1.28 EKS envelope-encrypts all Kubernetes API data with an AWS owned key automatically — it will not appear in your KMS console, and that is expected, not a gap. A customer-managed key buys key-policy control and CloudTrail auditability at ~$1/month; this lab needs neither. Scope note: this covers API-stored data only, not EBS/EFS.

---

## 5. ECR repository and images

Everything here is free (the repo) or cents (image storage) and **needs no cluster** — finish all three images now, before the first control plane starts the hourly meter. If an image build surfaces a problem (slow `/work` timings, a metrics 404), you debug it with zero AWS resources burning. Docker Desktop must be running.

### 5.1 Repository

**ECR → Private → Create repository**: name `eks-lab-sample`, **Mutable** tags, **AES-256**, tags (1.2). Enable basic **scan on push** (repository wizard or registry Settings, depending on console version); leave enhanced/Inspector scanning off.

Mutable is load-bearing, not a lab shortcut: buildx re-PUTs the tag on every retry and rebuild, and against an immutable tag ECR answers an opaque `400 Bad Request` that looks like a broken registry, not a policy. If the repo already exists as immutable, flip it — `aws ecr put-image-tag-mutability --repository-name eks-lab-sample --image-tag-mutability MUTABLE`.

**Lifecycle policy → Create rule**: priority 1, untagged images, older than 1 day, expire — every rebuild orphans the previous image as untagged, and untagged layers still bill.

One repository, three images by tag (`values.yaml` in the chart carries per-service repository/tag overrides if you ever split them):

| Tag | Contents |
| --- | --- |
| `0.1.0` | Python service (`frontend`, `inventory`) |
| `orders-java-0.1.0` | Spring Boot 3 + JavaMelody (`orders`) |
| `javamelody-collector-2.8.0` | JavaMelody collector server |

URI: `600627340244.dkr.ecr.ap-southeast-1.amazonaws.com/eks-lab-sample`

### 5.2 Login and builder

```powershell
aws ecr get-login-password --profile AWS --region ap-southeast-1 | docker login --username AWS --password-stdin 600627340244.dkr.ecr.ap-southeast-1.amazonaws.com
```

**All three images must be multi-arch manifests (amd64 + arm64)** — the `graviton-spot` node group (7.4) is arm64, and the topology spread (9.10) will place replicas there; a single-arch image dies with `exec format error`. Build with buildx: `--push` publishes the manifest directly (`--load` cannot handle two platforms), and `--provenance=false --sbom=false` keeps each index to exactly two child manifests (attestation manifests render as confusing `unknown/unknown` rows in the ECR console). Docker Desktop's containerd image store builds multi-platform on the default builder; only if `--push` complains about multiple platforms, create one:

```powershell
docker buildx create --name eks-lab --use
```

### 5.3 Test `orders` locally first

Build a throwaway native-arch image and prove the service before paying for the slow two-platform build:

```powershell
docker build --pull -t orders-local assignment\apps\orders-java
docker run --rm -p 8080:8080 -e DATA_DIR=/tmp/data orders-local
```

```powershell
curl.exe -s -o NUL -w "%{time_total}s`n" http://localhost:8080/work
curl.exe -s "http://localhost:8080/monitoring?format=prometheus" | Select-Object -First 20
```

- **Timing is critical:** `frontend` calls `orders` with a hard 2s timeout, and `/work` runs a deliberately expensive join. Expect well under 0.5s; if slow, reduce the row count in `assignment/apps/orders-java/src/main/resources/data.sql` (the join is quadratic in it).
- Metrics curl empty/404 → try removing `/monitoring.*` from `url-exclude-pattern` in `application.yaml`.

### 5.4 Build and push all three

**Python** (`frontend`, `inventory`):

```powershell
docker buildx build --pull --platform linux/amd64,linux/arm64 --provenance=false --sbom=false -t 600627340244.dkr.ecr.ap-southeast-1.amazonaws.com/eks-lab-sample:0.1.0 --push assignment\apps\sample-microservice
```

**Java** (`orders`) — Spring Boot 3 + JavaMelody, same HTTP contract/env/log shape as the Python service; multi-stage Dockerfile. The arm64 Maven stage runs under QEMU emulation — expect this build to take several times the native one; the Temurin base images are multi-arch, so no Dockerfile changes:

```powershell
docker buildx build --pull --platform linux/amd64,linux/arm64 --provenance=false --sbom=false -t 600627340244.dkr.ecr.ap-southeast-1.amazonaws.com/eks-lab-sample:orders-java-0.1.0 --push assignment\apps\orders-java
```

**Collector server** — no official image exists; the Dockerfile wraps the official 2.8.0 WAR:

```powershell
docker buildx build --pull --platform linux/amd64,linux/arm64 --provenance=false --sbom=false -t 600627340244.dkr.ecr.ap-southeast-1.amazonaws.com/eks-lab-sample:javamelody-collector-2.8.0 --push assignment\apps\javamelody-collector
```

### 5.5 Verify

**ECR → eks-lab-sample**: three tags with scan results; each tag's details page shows an **Image index** with two child images (amd64, arm64).

Chart facts already handled for the JVM: `orders` gets 512Mi/768Mi (vs 64/128 for Python) with `-XX:MaxRAMPercentage=70.0`, and a `startupProbe` allowing up to 150s — without it the default liveness probe kills a warming JVM and fakes a CrashLoopBackOff.

---

## 6. Create `eks-observability`

**The hourly meter starts here.** Build this cluster first — it hosts the telemetry endpoint the workload cluster pushes to.

**EKS → Clusters → Create cluster** → choose **Custom configuration**, Auto Mode **off** (Auto Mode removes the node-group/Karpenter mechanics this lab exists to exercise, and bills a surcharge).

### 6.1 Configure cluster

| Field | Value |
| --- | --- |
| Name | `eks-observability` |
| Version | `1.36` |
| Service role | `eks-lab-cluster-role` |
| Bootstrap administrator | **Enabled** — without it you build a cluster you cannot talk to |
| Authentication mode | `EKS API` (or `EKS API and ConfigMap`) |
| Upgrade policy | Standard |
| Auto Mode | Disabled |
| Secrets encryption | Empty (section 4) |

Leave zonal shift, hybrid nodes, remote networks off.

### 6.2 Networking

| Field | Value |
| --- | --- |
| VPC | `vpc-08d8dfa1dbf84383e` |
| Subnets | **Only** the two private subnets |
| Security groups | None — let EKS create the cluster SG |
| IP family / Service CIDR | IPv4 / default |
| Private endpoint | Enabled |
| Public endpoint | Enabled, allowlist `<YOUR_IP>/32` — never `0.0.0.0/0` |

Public+private is the lab pragmatic: private for nodes, public for your laptop. Production would be private-only via bastion/VPN.

### 6.3 Observability

Enable **all five** control-plane log types (API server, Audit, Authenticator, Controller manager, Scheduler). Retention gets capped in 6.5, and audit logs cannot be enabled retroactively. Leave Container Insights and Prometheus scraping **off** — this lab builds its own stack.

### 6.4 Add-ons

Exactly four: **VPC CNI, CoreDNS, kube-proxy, EKS Pod Identity Agent** — console-recommended versions for 1.36. Deselect everything else, **including EBS/EFS CSI** (those are your checkpoints, 9.3 and 9.9).

### 6.5 Create and set log retention

Review, **Create** (~10–15 min; billing starts). Once Active: **CloudWatch → Log groups** → `/aws/eks/eks-observability/cluster` → retention **7 days** (default is never-expire).

### 6.6 Observability node group

**EKS → eks-observability → Compute → Add node group**

| Field | Value |
| --- | --- |
| Name | `observability` |
| Node IAM role | `eks-lab-observability-node-role` |
| Label | `workload-class` = `observability` — load-bearing; every values file pins to it |
| Taints | None |
| AMI | AL2023 x86-64 standard |
| Capacity | **On-Demand** |
| Instance type | `t3.large` only |
| Disk | 20 GiB |
| Min/Desired/Max | 1 / 1 / 1 |
| Max unavailable | 1 |
| Subnets | **`eks-lab-private-a` only** |

Two decisions worth understanding:

- **On-Demand** because this node holds three EBS-backed PVCs; a Spot reclamation means a volume re-attach dance for ~$0.08/hr of savings.
- **One subnet** because **EBS volumes are zonal**: with both subnets, a replacement node in `1b` cannot attach volumes created in `1a` and Prometheus/Loki/Tempo sit Pending with `volume node affinity conflict`. One subnet removes the failure mode; the cluster still spans two AZs, which is all EKS requires.

No SSH access. Create, wait for **Active**.

---

## 7. Create `eks-workload`

Same wizard; differences only. The cluster's compute is **three pools** built in this order: the platform node group (7.2, console, now), the Graviton Spot node group (7.4, console, now), and the 1:3 On-Demand:Spot Karpenter pool (9.8, CLI, later — it cannot exist before the cluster and its controller do). The recap table in 7.5 shows the finished shape.

### 7.1 Control plane

| Field | Value |
| --- | --- |
| Name | `eks-workload` |
| Everything else | As 6.1–6.4: same role, subnets, `/32` endpoint, five logs, empty encryption, Auto Mode off, four add-ons |

After Active: set `/aws/eks/eks-workload/cluster` retention to **7 days**.

### 7.2 Node group 1 — `platform` (On-Demand)

| Field | Value |
| --- | --- |
| Name | `platform` |
| Node IAM role | `eks-lab-workload-node-role` |
| Label | `workload-class` = `platform` |
| Taint | `dedicated` = `platform`, effect `NoSchedule` |
| AMI | AL2023 x86-64 standard |
| Capacity | **On-Demand** |
| Instance types | `t3.large` and `t3a.large` |
| Disk | 20 GiB |
| Min/Desired/Max | 2 / 2 / 2 |
| Max unavailable | 1 |
| Subnets | **Both** private subnets |

The taint reserves these nodes for platform components; every values file targeting this cluster carries the matching toleration. On-Demand because this is the control layer of the whole demo — Argo CD, the workload Prometheus forwarder, CoreDNS, and the Karpenter controller all live here, and a Spot reclamation that takes the scheduler-of-schedulers down turns every other debugging session into noise. Spot risk belongs on the microservice pools (7.5), which are stateless and PDB-protected. Both subnets is right here — no zonal state, and it lets pods spread across AZs.

### 7.3 CoreDNS toleration — required

Do this immediately after the `platform` node group is Active: the cluster's only nodes are tainted, CoreDNS has no toleration and will sit **Pending**, breaking DNS in confusing ways.

**EKS → eks-workload → Add-ons → CoreDNS → Edit** → keep version, paste into optional configuration:

```json
{
  "nodeSelector": {
    "workload-class": "platform"
  },
  "tolerations": [
    {
      "key": "CriticalAddonsOnly",
      "operator": "Exists"
    },
    {
      "key": "node-role.kubernetes.io/control-plane",
      "operator": "Exists",
      "effect": "NoSchedule"
    },
    {
      "key": "dedicated",
      "operator": "Equal",
      "value": "platform",
      "effect": "NoSchedule"
    }
  ]
}
```

The first two tolerations restate CoreDNS defaults — add-on configuration **replaces**, it does not merge. Save, wait for **Active**.

### 7.4 Node group 3 — `graviton-spot`

**EKS → eks-workload → Compute → Add node group**

| Field | Value |
| --- | --- |
| Name | `graviton-spot` |
| Node IAM role | `eks-lab-workload-node-role` |
| Label | `workload-tier` = `mixed` |
| Taint | `dedicated` = `microservices`, effect `NoSchedule` |
| AMI | **AL2023 ARM64 standard** |
| Capacity | **Spot** |
| Instance types | `t4g.medium` and `t4g.large` |
| Disk | 20 GiB |
| Min/Desired/Max | 1 / 1 / 1 |
| Max unavailable | 1 |
| Subnets | **Both** private subnets |

Graviton is arm64: everything scheduled here must ship an arm64 image — which the section 5 multi-arch manifests already guarantee; a plain amd64 image would land here and die with `exec format error`. The label and taint deliberately match Karpenter's microservice nodes (9.8), so the sample chart treats this node as just another member of the mixed fleet and the topology spread (9.10) counts it when balancing replicas. Graviton Spot is the cheapest compute in the region — this node also demonstrates the arch dimension in `kubectl get nodes -L kubernetes.io/arch`.

### 7.5 Workload compute — the three-pool shape

| Pool | Mechanism | Capacity | Arch | Nodes | Built |
| --- | --- | --- | --- | --- | --- |
| 1 — `platform` | Managed node group (7.2) | On-Demand | x86-64 | 2 | now |
| 2 — microservices mixed | Karpenter NodePools (9.8) | **1 On-Demand : 3 Spot** | x86-64 | 4 | after CLI setup |
| 3 — `graviton-spot` | Managed node group (7.4) | Spot | arm64 | 1 | now |

Why pool 2 is NodePools and not a managed node group: **a managed node group cannot mix On-Demand and Spot** — capacity type is group-wide. The 1:3 ratio is therefore expressed as two constrained Karpenter NodePools (one capped at a single On-Demand node, one at three Spot), which doubles as the assignment's Karpenter demonstration. Seven worker nodes total once 9.8 is done; pools 2 and 3 share the `workload-tier=mixed` label and `dedicated=microservices` taint, so the sample workloads see one five-node fleet to spread across.

---

## 8. Verify what you built

For each cluster: **Overview** Active at 1.36 · **Networking** two private subnets, both endpoint types, `/32` not `0.0.0.0/0` · **Add-ons** exactly four, Active (no CSI drivers yet) · **Access** creator has `AmazonEKSClusterAdminPolicy` · **Observability** five log types, log groups at 7-day retention. No KMS key anywhere — correct (section 4).

| Cluster | Node group | Size | Capacity | Types |
| --- | --- | --- | --- | --- |
| `eks-workload` | `platform` | 2/2/2 | On-Demand | `t3.large`, `t3a.large` |
| `eks-workload` | `graviton-spot` | 1/1/1 | Spot | `t4g.medium`, `t4g.large` |
| `eks-observability` | `observability` | 1/1/1 | On-Demand | `t3.large` |

**EC2 → Instances** (filter `Project = eks-two-cluster-assignment`): exactly four instances (one a `t4g`), all in the private subnets, **no public IPs** (if one has an IP, fix the subnet's auto-assign — 2.1), IMDSv2 Required with hop limit 1.

---

## 9. After the console: kubectl and Helm

The console cannot install Helm charts — everything below is CLI, run from the repo root, in this order. Each step depends on the previous one.

### 9.0 Prerequisites

- Tooling: `aws` CLI (profile `AWS`), `kubectl`, `helm`, and a Git remote — 9.10 deploys via Argo CD reading your repository. (Docker already did its work in section 5.)
- **Your checkpoints:** EBS CSI + `gp3` (9.3) blocks all of 9.4; Karpenter (9.8) blocks all of 9.10; EFS (9.9) is optional.
- **Ordering constraints:** the NLB (9.4) must exist before templates render (9.5); Karpenter (9.8) before Argo CD syncs (9.10).
- **Read each values file before running its install** — they are short and hold the actual decisions.

### 9.1 Kubeconfig

```powershell
aws eks update-kubeconfig --profile AWS --region ap-southeast-1 --name eks-workload --alias eks-workload
aws eks update-kubeconfig --profile AWS --region ap-southeast-1 --name eks-observability --alias eks-observability
```

Every command below names its cluster with `--context`/`--kube-context` — with two clusters open, running the right command against the wrong one is the easiest mistake to make.

### 9.2 Base health

```powershell
kubectl --context eks-workload get nodes -o wide
kubectl --context eks-workload -n kube-system get pods -o wide
kubectl --context eks-observability get nodes -o wide
kubectl --context eks-observability -n kube-system get pods -o wide
```

Expect: 3 Ready nodes (two `t3` platform, one `t4g` graviton) / 1 Ready node; CoreDNS, VPC CNI, kube-proxy, Pod Identity Agent Running — the DaemonSets run on the arm64 node too, proving the ARM AMI is healthy; workload CoreDNS on `workload-class=platform` nodes (7.3 worked). On `Unauthorized`: **EKS → cluster → Access** — the entry must use the IAM **role** ARN, not an assumed-role session ARN.

### 9.3 EBS CSI + `gp3` StorageClass — your build, hard blocker

Build it on `eks-observability` yourself. Three pieces: an IAM role for the driver, the driver itself (add-on), then the StorageClass (kubectl only, no console UI for this resource).

**A. IAM role for the driver**

**IAM → Roles → Create role** → AWS service, use case **EKS - Pod Identity** if offered; otherwise **Custom trust policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
```

Attach the AWS-managed policy `AmazonEBSCSIDriverPolicy` (`arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy`). Name `eks-lab-ebs-csi-role`, tags (1.2). Same reasoning as 3.2: the driver gets its own scoped Pod Identity role, not node-role permissions.

**B. Install the add-on and bind the role**

**EKS → eks-observability → Add-ons → Get more add-ons** → **Amazon EBS CSI Driver**, version `v1.63.1-eksbuild.1` (default for 1.36 at time of writing — console may offer newer). Under **Pod Identity association**, select `eks-lab-ebs-csi-role` for the `kube-system` / `ebs-csi-controller-sa` service account. If your console version doesn't offer that inline, install the add-on first, then **EKS → eks-observability → Access → Pod Identity associations → Create** with the same namespace/service account/role. Wait for the add-on to reach **Active**.

```powershell
kubectl --context eks-observability -n kube-system get pods -l app=ebs-csi-controller
kubectl --context eks-observability -n kube-system get pods -l app=ebs-csi-node
```

Expect the controller deployment pods Running and an `ebs-csi-node` DaemonSet pod Running on the `observability` node.

**C. `gp3` StorageClass**

No console UI for this. Apply `assignment/k8s/gp3-storageclass.yaml`:

```powershell
kubectl --context eks-observability apply -f assignment/k8s/gp3-storageclass.yaml
```

`volumeBindingMode: WaitForFirstConsumer` matters even with the single-subnet node group from 6.6 — it defers volume creation until a pod is actually scheduled, avoiding `volume node affinity conflict`.

Resume only when both succeed:

```powershell
kubectl --context eks-observability get csidriver ebs.csi.aws.com
kubectl --context eks-observability get storageclass gp3
```

The values files request `gp3` PVCs: Prometheus 20 GiB, Loki 10 GiB, Tempo 10 GiB. Missing/misnamed StorageClass = three Pending pods in 9.4.

### 9.4 Observability stack on `eks-observability`

**Billing accelerates here** — the NLB is ~$0.03/hr and the EBS volumes bill once bound.

```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl --context eks-observability create namespace monitoring
kubectl --context eks-observability create namespace ingress-nginx
```

**kube-prometheus-stack** — `values/prometheus-observability.yaml`: Alertmanager off, pinned to `workload-class=observability`, 3-day retention on 20 GiB gp3, external label `cluster=eks-observability`, and `enableRemoteWriteReceiver: true` (the switch that accepts Cluster 1's pushed metrics):

```powershell
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --kube-context eks-observability --namespace monitoring --version 88.0.1 --values assignment\values\prometheus-observability.yaml --wait --timeout 15m
```

`--wait` turns values mistakes into a timeout here instead of a silent failure later.

**Loki** — SingleBinary mode, 10 GiB gp3, 72h retention (`grafana-community` repo, not `grafana`):

```powershell
helm upgrade --install loki grafana-community/loki --kube-context eks-observability --namespace monitoring --version 18.7.1 --values assignment\values\loki.yaml --wait --timeout 15m
```

**Tempo** — single-binary, OTLP on gRPC 4317 / HTTP 4318, 10 GiB gp3, 72h:

```powershell
helm upgrade --install tempo grafana-community/tempo --kube-context eks-observability --namespace monitoring --version 2.2.3 --values assignment\values\tempo.yaml --wait --timeout 15m
```

**ingress-nginx → internal NLB** — the values set `type: LoadBalancer` with `aws-load-balancer-scheme: internal` + `aws-load-balancer-type: nlb`; the in-tree cloud controller provisions the NLB (no AWS LB Controller in this lab):

```powershell
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --kube-context eks-observability --namespace ingress-nginx --version 4.15.1 --values assignment\values\ingress-nginx.yaml --wait --timeout 15m
```

**Telemetry routing** — `k8s/telemetry-ingress.yaml` fans three paths to three backends: `/api/v1/write` → Prometheus, `/loki/api/v1/push` → Loki, `/v1/traces` → Tempo:

```powershell
kubectl --context eks-observability apply -f assignment\k8s\telemetry-ingress.yaml
kubectl --context eks-observability -n ingress-nginx get svc ingress-nginx-controller -w
```

Wait for the NLB hostname (minutes). Stuck `<pending>` = missing `internal-elb` tag (2.1). Verify in console per 10.1.

### 9.5 Render the templates

```powershell
kubectl --context eks-observability -n ingress-nginx get svc ingress-nginx-controller -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

Copy each `.tmpl` into `assignment/generated/` (create it; git-ignored) minus the suffix, replace the placeholder by hand:

| Template | Placeholder | Used for |
| --- | --- | --- |
| `values/prometheus-workload.yaml.tmpl` | `__TELEMETRY_ENDPOINT__` | `remoteWrite` URL `http://<NLB>/api/v1/write` |
| `values/alloy.yaml.tmpl` | `__TELEMETRY_ENDPOINT__` | Loki push + OTLP trace endpoints |
| `k8s/app.yaml.tmpl` | `__GIT_REPOSITORY_URL__` | Argo CD Application source (9.10) |

Never commit `assignment/generated/`.

### 9.6 Platform services on `eks-workload`

```powershell
kubectl --context eks-workload create namespace monitoring
kubectl --context eks-workload create namespace argocd
```

**Workload Prometheus** — a forwarder, not a store: no storage spec, Grafana/Alertmanager off, external label `cluster=eks-workload`, and the `dedicated=platform:NoSchedule` toleration on every component:

```powershell
helm upgrade --install workload-monitoring prometheus-community/kube-prometheus-stack --kube-context eks-workload --namespace monitoring --version 88.0.1 --values assignment\generated\prometheus-workload.yaml --wait --timeout 15m
```

**Alloy** — DaemonSet: tails container logs → Loki, receives OTLP traces → Tempo, both via the NLB:

```powershell
helm upgrade --install alloy grafana/alloy --kube-context eks-workload --namespace monitoring --version 1.11.0 --values assignment\generated\alloy.yaml --wait --timeout 15m
```

**Argo CD** — platform nodeSelector + toleration, single replicas, Dex off:

```powershell
helm upgrade --install argocd argo/argo-cd --kube-context eks-workload --namespace argocd --version 10.2.2 --values assignment\values\argocd.yaml --wait --timeout 15m
```

Confirm all pods landed on the two platform nodes:

```powershell
kubectl --context eks-workload get pods -n monitoring -o wide
kubectl --context eks-workload get pods -n argocd -o wide
```

### 9.7 JavaMelody collector server

JavaMelody counters live inside each JVM — four `orders` replicas means four quarter-views. The collector polls registered nodes and aggregates. Pod IPs are dynamic, so each pod **registers itself** (`CollectorServerRegistrar.java`, Downward-API pod IP), re-registering every 60s (the collector loses its list on restart — `emptyDir`) and logging failures without throwing.

```powershell
kubectl --context eks-workload apply -f assignment\k8s\javamelody-collector.yaml
kubectl --context eks-workload -n monitoring rollout status deployment/javamelody-collector
kubectl --context eks-workload -n monitoring logs deployment/javamelody-collector | Select-String -Pattern "port|Started|Listening"
```

Confirm port 8080 from the log; if different, fix the manifest's ports and `collectorUrl` in `assignment/charts/sample-microservices/values.yaml`. Filesystem/permission error at startup → the WAR needs another writable `emptyDir` besides `/tmp`; mount one over the named directory.

### 9.8 Karpenter — your build, hard blocker

Install Karpenter on `eks-workload`: IAM, interruption queue, EventBridge rules (all console), then controller, EC2NodeClass, NodePools (CLI — the console cannot run Helm or create CRs). This completes pool 2 of the 7.5 shape. The contract the manifests in `assignment/karpenter/` already encode:

- Controller on `workload-class=platform` nodes, tolerating `dedicated=platform:NoSchedule`.
- Only the microservice NodePools carry label `workload-tier=mixed`; their nodes taint `dedicated=microservices:NoSchedule` — identical to the `graviton-spot` node group (7.4), so the two pools present as one fleet.
- Demonstration shape: **1 On-Demand + 3 Spot** via separate constrained NodePools — a managed node group cannot express the ratio because capacity type is group-wide. The cap is CPU limits: `cpu: 2` = one 2-vCPU On-Demand node, `cpu: 6` = three Spot; a mistake cannot scale past four nodes.
- Both NodePools constrained to `kubernetes.io/arch: amd64` and `t3.medium`/`t3a.medium` — the arm64 slot is the managed `graviton-spot` group's job, and four `orders` JVMs at 512Mi forced onto four separate nodes by the `maxSkew: 1` hostname spread need at least a `medium`.
- EC2NodeClass selects the two private subnets and the cluster SG by ID, reuses `eks-lab-workload-node-role`, IMDSv2 hop limit 1, encrypted gp3 root.

**A. Controller IAM role — IAM → Roles → Create role**

1. Trusted entity: **Custom trust policy**, paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
```

2. Attach **no** managed policies → name `eks-lab-karpenter-controller-role`, tags (1.2) → Create.
3. Open the role → **Add permissions → Create inline policy → JSON** → paste the contents of `assignment/karpenter/controller-policy.json` → name `karpenter-controller`.

The policy is scoped: `iam:PassRole` only to the node role, SQS only to the interruption queue, `eks:DescribeCluster` only to this cluster. It must include `iam:ListInstanceProfiles` — the controller's instance-profile garbage collector polls it and spams `AccessDenied` reconcile errors without it, burying real provisioning failures.

**B. Interruption queue — SQS → Create queue**

- Type **Standard**, name `eks-workload-karpenter`, **Message retention 5 minutes** (interruption warnings are useless after two).
- **Access policy → Advanced**, replace the default with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": ["events.amazonaws.com", "sqs.amazonaws.com"] },
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:ap-southeast-1:600627340244:eks-workload-karpenter"
    }
  ]
}
```

**C. Four EventBridge rules — EventBridge → Rules → Create rule**

Each: default event bus, **Rule with an event pattern → Custom pattern (JSON editor)**, target **SQS queue** `eks-workload-karpenter`.

| Rule name | Event pattern |
| --- | --- |
| `karpenter-spot-interruption` | `{"source":["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning"]}` |
| `karpenter-rebalance` | `{"source":["aws.ec2"],"detail-type":["EC2 Instance Rebalance Recommendation"]}` |
| `karpenter-state-change` | `{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"]}` |
| `karpenter-scheduled-change` | `{"source":["aws.health"],"detail-type":["AWS Health Event"]}` |

**D. Pod Identity — EKS → eks-workload → Access → Pod Identity associations → Create**

- IAM role `eks-lab-karpenter-controller-role`, namespace `karpenter`, service account `karpenter` (exactly — the chart's default SA name; a typo here is the classic silent auth failure).
- No node access entry needed: `eks-lab-workload-node-role` already has the auto-created `EC2_LINUX` entry from the managed node groups, and Karpenter nodes reuse the same role.

**E. Controller — CLI**

```powershell
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --kube-context eks-workload --namespace karpenter --create-namespace --version 1.14.0 --values assignment/karpenter/helm-values.yaml --wait --timeout 10m
```

The values pin the controller to the platform nodes and set `AWS_REGION` explicitly — the nodes' IMDS hop limit of 1 (7.2) means pods cannot discover the region themselves, and without it the controller crashloops on startup. A 403 pulling the chart = stale anonymous token: `helm registry logout public.ecr.aws` and retry.

**F. EC2NodeClass + NodePools — CLI**

```powershell
kubectl --context eks-workload apply -f assignment/karpenter/nodeclass-nodepools.yaml
```

**G. Verify** — resume after:

```powershell
kubectl --context eks-workload -n karpenter get deployment,pods
kubectl --context eks-workload get ec2nodeclass,nodepool,nodeclaim
```

Controller `1/1 Running` on a platform node; EC2NodeClass `mixed` **Ready True** (not-ready = `describe ec2nodeclass mixed` names the failing subnet/SG/AMI selector); both NodePools **Ready True** at 0 nodes — correct, nodes launch only when 9.10's sync creates pending pods. Tail the controller log for `AccessDenied` before moving on: IAM noise here buries real errors later.

### 9.9 EFS — optional, your build

Chart defaults to `emptyDir` and works without it. For the shared-storage item: EFS CSI, encrypted filesystem, mount targets in both private subnets, NFS SG rules, `efs-rwx` StorageClass; access point must allow UID `10001` / GID `2000`. Then set `persistence.enabled: true` in the chart values, commit, push. Verify:

```powershell
kubectl --context eks-workload get csidriver efs.csi.aws.com
kubectl --context eks-workload get storageclass efs-rwx
```

### 9.10 Deploy via Argo CD

**Chart scheduling contract — verify before pushing.** These settings are what the drain test in 9.11 exercises; without them the chart deploys fine and fails the availability requirement invisibly:

- Every sample Deployment carries `topologySpreadConstraints` with `maxSkew: 1` on `kubernetes.io/hostname` **and** on `topology.kubernetes.io/zone`, so replicas land evenly across the five mixed worker nodes and both AZs. `orders` keeps `whenUnsatisfiable: DoNotSchedule` on hostname (hard: four replicas, four separate nodes — this is also what forces Karpenter to launch the 1+3 shape); the other services use `ScheduleAnyway` plus preferred `podAntiAffinity`, so a temporarily tight cluster degrades to co-location instead of Pending.
- Every Deployment with **≥ 2 replicas** ships a **PodDisruptionBudget** with `maxUnavailable: 1`, so node drains, Spot reclamations, and Karpenter consolidation evict one replica at a time instead of all at once. Never put a PDB on a single-replica Deployment (the collector) — `maxUnavailable: 1` there is meaningless and `minAvailable: 1` makes its node undrainable.

1. Commit and push (never `assignment/generated`, `.terraform`, plans, state).
2. Verify the Karpenter prerequisites — without them Argo CD syncs fine and every pod sits Pending, which looks like an Argo CD bug and is not:

```powershell
kubectl --context eks-workload get crd nodepools.karpenter.sh
kubectl --context eks-workload -n karpenter get deployment
kubectl --context eks-workload get nodepool
```

3. Apply the Application — the last imperative act; desired state now lives in Git:

```powershell
kubectl --context eks-workload apply -f assignment\generated\app.yaml
```

4. Watch:

```powershell
kubectl --context eks-workload -n argocd get application sample-microservices -w
kubectl --context eks-workload -n sample get deploy,pods,pdb,pvc -o wide
kubectl --context eks-workload get nodes -L workload-tier,karpenter.sh/capacity-type,kubernetes.io/arch
```

Must deploy **through Argo CD**, not `helm install` on the chart.

### 9.11 End-to-end validation

No script — these checks are the validation.

**Placement:**

```powershell
kubectl --context eks-workload get pods -A -o wide
kubectl --context eks-workload get nodes -L workload-class,workload-tier,karpenter.sh/capacity-type
```

Platform pods on the two `platform` nodes; sample pods only on `workload-tier=mixed` (the four Karpenter nodes **plus** the graviton node); four `orders` replicas on four hostnames; capacity columns show 1 On-Demand + 3 Spot (Karpenter) + 1 Spot/arm64 (`graviton-spot`). No mixed node should hold two replicas of the same service — that is the `maxSkew: 1` spread working. At least one sample pod Running on the arm64 node proves the multi-arch build. `orders` at `0/1 Running` for up to 150s is the startupProbe, not a failure.

**Resiliency:**

```powershell
kubectl --context eks-workload -n sample get pdb
kubectl --context eks-workload drain <EXACT_SPOT_NODE_NAME> --ignore-daemonsets --delete-emptydir-data
```

Every multi-replica Deployment must show a PDB with `ALLOWED DISRUPTIONS` ≥ 1, and the drain must evict no more than one replica of any service at a time — evicted pods reschedule onto the remaining mixed nodes (the spread's `ScheduleAnyway`/preferred anti-affinity is what lets them land). Then `kubectl --context eks-workload uncordon <node>`.

**Telemetry:**

```powershell
kubectl --context eks-observability -n monitoring port-forward svc/monitoring-grafana 3000:80
```

Grafana must show: metrics labelled `cluster=eks-workload`; Cluster 1 JSON logs in Loki; traces for all three services in Tempo.

**JavaMelody step 1 — Prometheus path first** (never debug both at once). Generate traffic:

```powershell
kubectl --context eks-workload -n sample port-forward svc/frontend 8080:8080
```

```powershell
1..40 | ForEach-Object { curl.exe -s http://localhost:8080/work | Out-Null }
```

```powershell
kubectl --context eks-workload -n sample port-forward deploy/orders 8081:8080
curl.exe -s "http://localhost:8081/monitoring?format=prometheus" | Select-Object -First 30
```

Read the output: the chart's `metricRelabelings` rewrites dotted names (`javamelody.used_memory_sys`) to underscores for Prometheus 3.x. If names are already underscored, the rule matches nothing (harmless; `metrics.normalizeDotsInMetricNames: false` drops it). Then in Grafana:

```promql
{__name__=~"javamelody.*", cluster="eks-workload"}
```

Four series per metric — one per `orders` pod.

**JavaMelody step 2 — collector:**

```powershell
kubectl --context eks-workload -n sample logs -l app.kubernetes.io/component=orders --tail=50 | Select-String -Pattern "collector_"
kubectl --context eks-workload -n monitoring port-forward svc/javamelody-collector 8082:8080
```

Expect `collector_registered` per pod (`collector_registration_failed` = Service name/port mismatch in `values.yaml`). At `http://localhost:8082`, `orders` lists **exactly four nodes**:

- Count climbing past four → duplicates; make the `@Scheduled` method early-return while `registered.get()` is true.
- Listed but graphs empty → node URL must be the app root (`http://<pod-ip>:8080`); the collector appends `/monitoring`. Override `JAVAMELODY_NODE_URL`.

Worth looking at: **SQL** (the cartesian join tops slowest-queries), **JDBC** (HikariCP pool, cap 10), **Spring** (per-method stats — powered by the AOP starter), **HTTP** (probes absent, filtered by `url-exclude-pattern`).

Capture section 14 evidence, then **tear down the same day** (section 12).

---

## 10. Console checks for Kubernetes-created resources

### 10.1 The internal NLB (after 9.4)

**EC2 → Load Balancers**: one NLB named after `ingress-nginx-controller`, scheme **Internal** (internet-facing = annotation didn't apply), Active in the private subnets, targets Healthy. Record the DNS name for 9.5. No NLB at all = missing `internal-elb` tag (2.1); unhealthy targets = ingress-nginx logs + node SG.

### 10.2 EBS volumes (after 9.4)

**EC2 → Volumes**, filter tag `kubernetes.io/created-for/pvc/name`: three In-use gp3 (20/10/10 GiB), all in `ap-southeast-1a`. Any in another AZ = the 6.6 single-subnet decision wasn't applied.

### 10.3 Karpenter nodes (during 9.8–9.11)

**EC2 → Instances**, filter by your Karpenter tag: 1 On-Demand + 3 Spot, all x86. Alongside them the `graviton-spot` node group's `t4g` Spot instance (filter `Project` tag) completes the three-pool shape. Screenshot promptly — they bill from launch.

### 10.4 EFS (if built)

Encrypted, Available, mount targets in both private subnets; mount-target SG allows NFS 2049 from the workload node SG only.

---

## 11. Cost watching

**Cost Explorer**, region Singapore, group by Service (cost-allocation tags lag up to 24h, so the tag filter is useless same-day). Expect EC2-Other (NAT), EC2-Instances, EKS as top lines. Data lags hours — the reliable live meter is the list of resources you know you created.

---

## 12. Teardown — same day

**This section decides whether the lab cost $6 or $500.** Order matters: Kubernetes-created resources (LB ENIs, volumes, mount targets) block deleting subnets and SGs beneath them.

### 12.1 Kubernetes resources first (kubectl)

1. Delete the Argo CD Application; its finalizer removes the sample resources.
2. `kubectl --context eks-workload delete -f assignment\k8s\javamelody-collector.yaml`
3. Uninstall workload releases: Argo CD, Alloy, workload Prometheus.
4. Remove Karpenter NodePools and controller — **wait for the Karpenter instances to actually terminate**; deleting the controller first orphans nodes that bill until found by hand.
5. Remove your EFS/EBS Kubernetes resources once PVCs are gone.
6. Uninstall observability releases: ingress-nginx, Tempo, Loki, Prometheus.
7. **EC2 → Load Balancers**: wait until the NLB and target group disappear (asynchronous, minutes).

### 12.2 Node groups, then clusters

Delete node groups `platform` and `graviton-spot` → cluster `eks-workload` → node group `observability` → cluster `eks-observability`, waiting for each. Billing stops at deletion completion, not at the click.

### 12.3 Delete what bills; keep what is free

Delete:

1. ECR images inside `eks-lab-sample` (the empty repo is free).
2. NAT `eks-lab-nat` — wait for **Deleted**.
3. **Release the Elastic IP** — the single most forgotten charge in this lab.
4. Any surviving EBS volumes (cluster deletion does not delete `Retain`-policy PVs).
5. Any surviving Karpenter instances.
6. Orphaned lab SGs, ENIs, target groups, Karpenter/EFS leftovers.
7. Optionally the log groups (7-day retention already caps them).

Keep (free; rebuild restarts at section 6 — or 2.3 for the NAT): both private subnets, route table `eks-lab-private` (its NAT route shows **blackhole** after deletion — expected; repoint it at the next build's NAT), all three IAM roles, and the empty `eks-lab-sample` repository with its lifecycle policy.

**Never delete** the pre-existing VPC, public subnets, `rtb-030293eb7e6fd8f3a`, or IGW.

### 12.4 Final sweep

- [ ] EKS clusters empty · EC2 instances clear · LBs/target groups gone · EIPs released
- [ ] Volumes/snapshots clear · NAT gone · **no orphaned ENIs in the private subnets** (the check people skip — a leftover ENI silently blocks future subnet deletion)
- [ ] EFS clear (if built) · IAM/SQS/EventBridge clear of Karpenter artifacts

---

## 13. Troubleshooting

### 13.1 Console / AWS

| Symptom | Cause | Fix |
| --- | --- | --- |
| ECR push fails `400 Bad Request` on manifest PUT | Repo has immutable tags; buildx re-PUTs on retry | 5.1 — set tag mutability to Mutable |
| NAT stuck **Failed** | Subnet lacks IGW route or free IPs | Public subnet's route table |
| Nodes never Ready | No outbound path | Private RT `0.0.0.0/0 → nat-...`; NAT Available |
| Node group fails on IAM | Missing policy or wrong trust | Role's Permissions/Trust tabs (3.2) |
| kubectl `Unauthorized` | Console vs CLI identity mismatch | Access entry with the **role** ARN, not session ARN |
| kubectl times out (was fine) | Your public IP changed | Re-check IP; update both allowlists |
| CoreDNS Pending on workload | Missing platform toleration | 7.3 |
| ingress Service `<pending>` | Missing `internal-elb` tag | 2.1 |
| PVC Pending, `volume node affinity conflict` | Node and volume in different AZs | 6.6 — one subnet |
| Spot capacity failure | Instance pool too narrow | 7.4 / 9.8 — keep two instance types per Spot pool |
| Pod on graviton node in `CrashLoopBackOff`, `exec format error` | Single-arch (amd64) image | 5.4 — rebuild with buildx `--platform linux/amd64,linux/arm64` |
| Cannot delete subnet | ENI/LB/mount target references it | VPC → Network interfaces, filter by subnet |

### 13.2 kubectl / Helm / app

| Symptom | Cause | Fix |
| --- | --- | --- |
| Helm times out at `--wait` | Unsatisfiable nodeSelector/toleration, or missing StorageClass | `kubectl describe pod` — the event names it |
| Observability pods Pending, `no persistent volumes` | `gp3` missing/misnamed | 9.3 |
| All sample pods Pending post-sync | Karpenter absent or NodePools lack `workload-tier=mixed` | 9.8 — check `get nodepool` before blaming Argo CD |
| Sample pods Pending, Karpenter running | Instances too small for 512Mi JVMs + spread | 9.8 — `t3.medium`+ |
| Drain evicts all replicas of a service at once | Missing PDB | 9.10 — chart scheduling contract |
| Replicas piled on one node | Missing/soft topology spread | 9.10 — `maxSkew: 1` on hostname |
| `orders` "CrashLoopBackOff" on first boot | JVM warming; startupProbe allows 150s | Wait, then read logs |
| `frontend` 502s calling `orders` | `/work` exceeds the 2s timeout | 5.3 — reduce `data.sql` rows |
| No workload metrics in Grafana | `__TELEMETRY_ENDPOINT__` unsubstituted or NLB changed | 9.5; check the `remoteWrite` URL |
| `javamelody.*` missing in Prometheus | Dotted-name relabeling mismatch | 9.11 — curl the pod and compare |
| Collector listed, graphs empty | Node URL includes `/monitoring` | 9.7 — `JAVAMELODY_NODE_URL` = app root |
| Collector count grows past 4 | Non-idempotent re-registration | 9.7 — early-return in the registrar |

---

## 14. Evidence checklist

- [ ] VPC Resource map: three public + two private subnets
- [ ] `eks-lab-private` route table with `0.0.0.0/0 → nat-...`; NAT Available with EIP
- [ ] ECR: three tags + scan results, each a multi-arch image index (amd64 + arm64)
- [ ] Both cluster Overview (Active, 1.36), Networking (`/32`), Compute, Add-ons (four), Access, Observability (five logs, 7-day retention) tabs
- [ ] EC2: four managed nodes (incl. the `t4g` graviton), private subnets, no public IPs
- [ ] Internal NLB, healthy targets
- [ ] Three EBS volumes backing the observability PVCs
- [ ] Three-pool compute in EC2: 1 On-Demand + 3 Spot (Karpenter) + 1 Graviton Spot
- [ ] `kubectl get pods -o wide`: replicas spread one-per-node across the mixed fleet, ≥1 sample pod on arm64
- [ ] `kubectl get pdb` plus the drain test output — no service drops more than one replica
- [ ] JavaMelody collector UI: `orders` with four nodes
- [ ] Grafana: metrics, logs, traces from `eks-workload`
- [ ] Teardown: empty EKS, EC2, NAT, EIP pages

---

## 15. Acceptance checklist

Section 14 is what to screenshot; this is what must be true.

- [ ] Two clusters in the existing VPC, on the two new private subnets only
- [ ] Public API endpoints restricted to your `/32`
- [ ] Five control-plane log types on, 7-day retention
- [ ] Default EKS envelope encryption (AWS owned key); no customer KMS key
- [ ] `eks-workload` runs the three-pool shape (7.5): node group 1 `platform` On-Demand, pool 2 Karpenter NodePools at 1:3 On-Demand:Spot, node group 3 `graviton-spot` arm64 Spot · `eks-observability`: one On-Demand `t3.large` pinned to subnet A
- [ ] Replicas distributed evenly across worker nodes via `topologySpreadConstraints` (`maxSkew: 1` hostname + zone) and pod anti-affinity
- [ ] Every multi-replica Deployment covered by a PDB (`maxUnavailable: 1`); drain/scale-in never takes a service below N−1 replicas
- [ ] All three images are multi-arch manifests; at least one sample pod Running on the Graviton node
- [ ] Only the four base add-ons created here; Karpenter/EBS/EFS built separately by you
- [ ] ECR holds all three image tags; `orders` serves JavaMelody at `/monitoring`
- [ ] `javamelody_*` series for all four `orders` pods reach the observability Prometheus
- [ ] Collector server shows `orders` with four registered nodes
- [ ] Sample chart deployed by Argo CD, running only on `workload-tier=mixed` nodes
- [ ] Prometheus, Loki, Tempo all receive Cluster 1 telemetry
- [ ] All hourly resources deleted same day; only subnets, route table, IAM roles, and the empty ECR repo remain

---

## Official references

- [EKS cluster IAM role](https://docs.aws.amazon.com/eks/latest/userguide/cluster-iam-role.html)
- [EKS node IAM role](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html)
- [Control-plane logging](https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html)
- [Default envelope encryption](https://docs.aws.amazon.com/eks/latest/userguide/envelope-encryption.html)
- [Access entries](https://docs.aws.amazon.com/eks/latest/userguide/grant-k8s-access.html)
- [Managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [Subnet requirements and tagging](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html)
- [Public NAT gateway routing](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-scenarios.html#public-nat-gateway-routing)
- [kubeconfig for EKS](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html)
- [EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [EFS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html)
- [Karpenter getting started](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)
- [Argo CD Application spec](https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/)
- [Pushing to ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html)
