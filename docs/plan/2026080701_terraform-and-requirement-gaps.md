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

## Out of scope

- Multi-environment promotion (`envs/` holds `lab` only — YAGNI until a second env exists).
- Terraform remote state/locking; local state is correct for a single-operator lab.
- CI pipelines, cluster upgrades, cross-account or production hardening.
- Rewriting the Java/Python apps or the debugged observability values.
