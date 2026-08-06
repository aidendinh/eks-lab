# 2026-08-07 — Terraform IaC + closing the requirement gaps

## Context

Twelve commits of prior work built the lab **through the AWS console** (`ManagedBy=AWSConsole`),
with `implementation.md` and `AWS-CONSOLE-GUIDE.md` as the build record. The Java apps, the
Helm chart, the observability values and the JavaMelody wiring are real and debugged — they stay.

Starting state verified on 2026-08-07:

- `aws eks list-clusters` → **empty**. The console build was torn down, so Terraform is a
  clean create: no `import` blocks needed.
- Survivors from the teardown: IAM roles `eks-lab-cluster-role`,
  `eks-lab-workload-node-role`, `eks-lab-observability-node-role`, and ECR repo
  `eks-lab-sample`. Terraform will own these names, so the orphans are deleted in phase 1.
- The working tree had 38 tracked files deleted (unstaged). Restored; the one genuine
  uncommitted change (collector userinfo log-scrubbing) was committed first as `bdfacbf`.

## Gap analysis (requirement → current state)

| # | Requirement | State before this plan |
|---|---|---|
| 1 | Modular Terraform for both clusters + shared infra | **Absent.** Console-built; `terraform` appears only in `.gitignore` and prose |
| 2 | KEDA for workload autoscaling | **Absent entirely** — no manifest, no chart, no mention |
| 3 | Microservices mount PVs backed by **EFS**, dynamic provisioning | **Not implemented.** `persistence.enabled: false`, `efs-rwx` StorageClass never created, EBS/gp3 used instead |
| 4 | Karpenter pool 2 = Graviton arm64, t4g.medium or smaller | **Wrong resource.** Graviton is a *managed node group* (`graviton-spot`); only two NodePools exist, both amd64 |
| 5 | Topology Spread **and** Pod Anti-Affinity | **Half done.** Spread constraints present; no `affinity:` block anywhere in the chart |
| 6 | All secrets in a single Secrets Manager secret named `eks-lab` | Secret is named `eks-lab/credentials` |

Two further items, not requirement violations but blockers for a Terraform-provisioned lab:

- `karpenter/nodeclass-nodepools.yaml` hardcodes `subnet-09710a86b3db80644` /
  `sg-01e88b1541f7415e4`. Argo CD syncs that file from Git, so it cannot carry Terraform
  outputs → switch to `karpenter.sh/discovery` tag selectors, applied by the VPC module.
- `implementation.md` documents a console build and will contradict the Terraform deliverable
  once it lands → rewrite as the Terraform runbook; keep the console guide as a labelled
  manual-fallback appendix.

## Decision log

- **Clean create, not import.** Nothing is running; AGENT.md forbids migration scaffolding.
- **Live apply.** User chose full apply + verify over plan-only (real spend, ~$5–10/session).
- **Terraform owns Helm releases** for platform/observability components, so the cluster is
  reproducible from `terraform apply`. Argo CD still owns *application* delivery — the
  microservices chart is never `helm install`ed, per the GitOps constraint.
- **Pool 3's 1:3 ratio stays scheduling-derived.** The ratio emerges from `minDomains: 4` on the
  hostname spread plus per-NodePool cpu limits (Spot capacity exhausts at 3, the 4th replica
  falls to On-Demand). No static fleet or instance list. Documented explicitly so the mechanism
  is not mistaken for a hardcoded shape.
- **EFS over EBS** for the microservice PVC: the claim is shared RWX across three Deployments
  spread over multiple nodes and AZs; EBS is zonal and RWO and cannot satisfy it.

## Phases

1. **Terraform foundation** — `vpc`, `iam`, `ecr` modules + `envs/lab` root; delete orphan
   console IAM roles; apply. Exit: `terraform apply` clean, VPC + NAT + tagged subnets exist.
2. **Clusters** — `eks-cluster` module called twice (workload, observability) + managed node
   groups (platform, observability). Exit: both clusters Active, nodes Ready, CoreDNS scheduled.
3. **Storage + compute** — `efs` module (filesystem, mount targets, SG, CSI driver, StorageClass)
   and `karpenter` module (IAM, SQS, EventBridge, controller). Three NodePools incl. Graviton.
   Exit: `efs-rwx` SC present, EC2NodeClass + 3 NodePools Ready.
4. **Platform + observability** — `eso` (Secrets Manager `eks-lab` + operator), `keda`,
   Argo CD, kube-prometheus-stack ×2, Loki, Tempo, Alloy, ingress-nginx, JavaMelody collector.
   Exit: remote-write, log and trace pipelines carrying data cluster 1 → cluster 2.
5. **Chart changes** — pod anti-affinity, EFS persistence enabled, KEDA `ScaledObject`,
   ESO refs repointed at the `eks-lab` secret. Delivered via Argo CD only.
   Exit: Argo CD Application Synced/Healthy, 1:3 node shape observed.
6. **Verify + document** — per-requirement verification commands with captured output; rewrite
   `implementation.md` as the Terraform runbook.

## Exit criteria

Every row of the gap table closed and verified against running infrastructure, with the
command and its real output recorded in the docs.

## Outcome — 2026-08-07

All six gaps closed and verified live; captured output in
[`../verification-2026-08-07.md`](../verification-2026-08-07.md).

| # | Gap | Verified by |
| --- | --- | --- |
| 1 | Terraform | 80 resources in `10-infra`, 14 in `20-platform`, both applied |
| 2 | KEDA | ScaledObject `Ready=True/Active=True`; frontend scaled 2 → 4 under load |
| 3 | EFS | PVC `Bound`, `RWX`, `efs-rwx`; apps write `/data/frontend-events.jsonl` |
| 4 | Graviton pool | NodePool `graviton-arm64` Ready; `inventory` running on arm64 Spot |
| 5 | Pod anti-affinity | `requiredDuringScheduling…` on hostname; 8 replicas on 8 distinct nodes |
| 6 | Secret name | One secret, `eks-lab`; 4 ExternalSecrets `SecretSynced` across both clusters |

Pool 3 emerged as **1 On-Demand : 3 Spot** from scheduling alone, as required.

### Defects found and fixed along the way

- **UTF-8 BOM** in `AppProperties.java` (and five other files) broke the Maven build
  inside the Docker build, where `-q` hid the cause. Stripped repo-wide.
- **ESO chart 0.14.4 does not serve `external-secrets.io/v1`**, which every manifest in
  this repo targets. Pinned to 2.8.0.
- **CloudWatch log group race**: EKS auto-creates the group when control-plane logging is
  on, so Terraform's create lost with `ResourceAlreadyExists`. The cluster now depends on
  the log group, so retention actually applies.
- **Argo CD `selfHeal` vs KEDA**: the chart shipped `replicas` for a KEDA-managed
  Deployment, so every scale event was reverted on the next reconcile. `replicas` is now
  omitted when `autoscaling.enabled`.
- **KEDA trigger address**: kube-prometheus-stack truncates its Service name to
  `<release>-kube-p-prometheus`; the wrong name left the ScaledObject `Ready=False`.
- **Pool 1 vCPU ceiling** was too low for the frontend's `maxReplicas` under required
  anti-affinity — scaled pods would have sat Pending. Raised to 8.

### Known rough edge

`20-platform` may need a second `apply` on a cold cluster: the Helm provider resolves a
release's manifests against an API discovery snapshot that can predate CRDs installed
earlier in the same apply. Documented in the runbook rather than papered over.

## Out of scope

- Multi-environment promotion (`envs/` holds `lab` only — YAGNI until a second env exists).
- Terraform remote state/locking; local state is correct for a single-operator lab.
- CI pipelines, cluster upgrades, cross-account or production hardening.
- Rewriting the Java/Python apps or the debugged observability values.
