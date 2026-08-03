# Two-cluster EKS assignment: Terraform runbook

> **This is the alternative build path, and it is not the one currently being followed.**
>
> The lab is now built through the AWS Management Console. Use these instead:
>
> - [`../eks-two-cluster-aws-console-implementation-plan.md`](../eks-two-cluster-aws-console-implementation-plan.md) — the end-to-end runbook
> - [`AWS-CONSOLE-GUIDE.md`](AWS-CONSOLE-GUIDE.md) — click-by-click console creation of every AWS resource
>
> **Do not run both.** Terraform has no knowledge of console-created resources; applying it afterwards creates duplicates, and destroying it leaves the console-built lab behind.
>
> This document also predates the cost reduction and the Java service, so several details below are out of date relative to the console path: the observability node is now `t3.large` rather than `t3.xlarge` and pinned to a single subnet, the platform node group is now Spot across `t3.large`/`t3a.large` rather than On-Demand, there is no customer-managed KMS key (EKS 1.28+ encrypts Kubernetes API data with an AWS owned key by default), `orders` now runs a Spring Boot 3 + JavaMelody image, and the PowerShell scripts under `scripts/` are no longer used by the console path.

This directory turns the original plan into a runnable, low-cost lab in AWS account `600627340244`, Region `ap-southeast-1`, using the AWS CLI profile `AWS`.

Terraform owns only:

- Two private subnets and one lab NAT gateway in the existing VPC.
- `eks-workload` with two On-Demand `t3.large` platform nodes.
- `eks-observability` with one On-Demand `t3.xlarge` node.
- CoreDNS, VPC CNI, kube-proxy, and EKS Pod Identity Agent.
- Cluster IAM, security groups, control-plane logs, KMS encryption, and access entries.
- One ECR repository for the sample services.
- An encrypted, versioned S3 Terraform state bucket with native S3 locking.

Karpenter, EBS CSI, EFS CSI, EFS filesystems, their IAM, and their Kubernetes resources are intentionally absent. The scripts only verify the objects that your manual setup must provide.

No AWS resources were applied while preparing this repository.

## Account discovery result

The `AWS` profile was inspected read-only on 2026-08-02:

| Item | Discovered value |
| --- | --- |
| Account | `600627340244` |
| Region | `ap-southeast-1` |
| VPC | `vpc-08d8dfa1dbf84383e`, default VPC, `172.31.0.0/16` |
| Existing subnets | Three public `/20` subnets in `1a`, `1b`, and `1c` |
| Private subnets | None |
| NAT gateways | None |
| Existing EKS clusters | None |
| Existing EFS filesystems | None |

The existing subnets are public because they map public IPs and use a route table with `0.0.0.0/0` through an internet gateway. Terraform therefore adds:

| Purpose | AZ | CIDR |
| --- | --- | --- |
| Private A | `ap-southeast-1a` | `172.31.48.0/20` |
| Private B | `ap-southeast-1b` | `172.31.64.0/20` |
| NAT placement | `ap-southeast-1a` | Existing `subnet-01de873e0d12d027c` |

The cluster API allowlist is your workstation's public IP as `<YOUR_IP>/32`. Recheck it before every session because residential public IPs can change.

## Architecture

```text
eks-workload (Cluster 1)                    eks-observability (Cluster 2)
├─ managed platform nodes                  ├─ managed observability node
│  ├─ Argo CD                              ├─ Prometheus + Grafana
│  ├─ lightweight Prometheus ─ remote ───► ├─ Loki
│  └─ Karpenter controller (manual)        ├─ Tempo
├─ Karpenter mixed nodes (manual)          └─ internal NLB / ingress-nginx
│  └─ frontend, orders, inventory                ▲ metrics/logs/traces
├─ Alloy ────────────────────────────────────────┘
└─ optional EFS RWX mount (manual)
```

All cluster nodes use the new private subnets. One NAT gateway provides outbound package and image access. This is deliberately a disposable two-AZ lab, not a production design.

## Repository map

```text
assignment/
├─ terraform/bootstrap/       # S3 state bucket
├─ terraform/live/            # VPC extension, both clusters, ECR
├─ apps/sample-microservice/  # dependency-free Python image and tests
├─ charts/sample-microservices/
├─ values/                    # pinned third-party chart configuration
├─ k8s/                       # telemetry ingress and Argo Application template
├─ scripts/                   # guarded PowerShell workflow
└─ generated/                 # ignored rendered files
```

## Prerequisites

Install and place in `PATH`:

- AWS CLI v2 with a working `AWS` profile.
- Terraform `>= 1.10`; the configuration was validated with `1.15.8`.
- kubectl compatible with Kubernetes `1.36`.
- Helm 3 or 4; validation used Helm `4.2.0`.
- Docker with permission to build and push images.
- Python 3 for local tests.
- A Git repository readable by Argo CD. A public HTTPS repository is simplest for the lab.

Start each shell with:

```powershell
$env:AWS_PROFILE = "AWS"
$env:AWS_REGION = "ap-southeast-1"
aws sts get-caller-identity
```

Every provided script sets those variables again and refuses to operate if the account is not `600627340244`.

## Phase 1: verify the inputs

Get your current public IP:

```powershell
$myIp = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
"$myIp/32"
```

Update `public_access_cidrs` in `assignment/terraform/live/terraform.tfvars` if it differs. Also review the VPC, NAT public subnet, CIDRs, cluster version, instance types, and tags in that file.

Run the local checks after Terraform has initialized once:

```powershell
.\\assignment\\scripts\\validate.ps1
```

## Phase 2: create remote Terraform state

First create and review the bootstrap plan:

```powershell
.\\assignment\\scripts\\terraform-bootstrap.ps1
```

It plans one S3 bucket named `eks-lab-tfstate-600627340244-ap-southeast-1`. The bucket has versioning, encryption, public-access blocking, a TLS-only bucket policy, and `prevent_destroy`.

After reviewing the output:

```powershell
.\\assignment\\scripts\\terraform-bootstrap.ps1 -Apply
```

The live backend uses `use_lockfile = true`; no DynamoDB lock table is needed.

## Phase 3: plan and apply the EKS infrastructure

Create a saved plan:

```powershell
.\\assignment\\scripts\\terraform-plan.ps1
```

Review especially:

- Exactly two new private subnets and one NAT gateway.
- Two EKS clusters at Kubernetes `1.36`.
- One managed node group per cluster with the expected sizes.
- No Karpenter, EBS CSI, EFS CSI, or EFS resources.
- EKS public API endpoints limited to your `/32`.
- No unexpected destroys.

Apply only the saved reviewed plan:

```powershell
.\\assignment\\scripts\\terraform-apply.ps1 -Approve
```

EKS creation commonly takes 20–40 minutes. This creates chargeable resources: two EKS control planes, three EC2 instances, one NAT gateway, and associated logs/storage.

Connect both contexts:

```powershell
.\\assignment\\scripts\\connect-clusters.ps1
kubectl config get-contexts
```

Expected contexts are `eks-workload` and `eks-observability`.

## Phase 4: satisfy the manual EBS checkpoint

On `eks-observability`, complete your own EBS setup. This repository expects only:

- A healthy CSI driver registered as `ebs.csi.aws.com`.
- A default or selectable StorageClass named `gp3` using `ebs.csi.aws.com`.

Verify your work:

```powershell
kubectl --context eks-observability get csidriver ebs.csi.aws.com
kubectl --context eks-observability get storageclass gp3 -o yaml
```

The observability values request one 20 GiB Prometheus PVC and 10 GiB each for Loki and Tempo. `install-observability.ps1` stops before Helm if either manual prerequisite is absent.

## Phase 5: install Cluster 2 observability

```powershell
.\\assignment\\scripts\\install-observability.ps1
```

Pinned chart versions, validated on 2026-08-02:

| Component | Chart version |
| --- | --- |
| kube-prometheus-stack | `88.0.1` |
| Loki single binary | `18.7.1` |
| Tempo single binary | `2.2.3` |
| ingress-nginx | `4.15.1` |

The script installs one internal ingress/NLB and applies these routes:

| Path | Target |
| --- | --- |
| `/api/v1/write` | Prometheus remote-write receiver |
| `/loki/api/v1/push` | Loki gateway |
| `/v1/traces` | Tempo OTLP/HTTP |

Wait for the internal hostname:

```powershell
kubectl --context eks-observability -n ingress-nginx get svc ingress-nginx-controller -w
```

Use port-forwarding for the Grafana UI, so no second load balancer is created:

```powershell
kubectl --context eks-observability -n monitoring port-forward svc/monitoring-grafana 3000:80
```

## Phase 6: render and install Cluster 1 platform services

Replace the example URL with the Git repository you will push this assignment to:

```powershell
.\\assignment\\scripts\\render-cluster-config.ps1 `
  -GitRepositoryUrl "https://github.com/YOUR_USER/YOUR_REPOSITORY.git"
```

This reads the internal NLB hostname and writes ignored, environment-specific files under `assignment/generated/`.

Install workload Prometheus, Alloy, and Argo CD on the tainted managed platform nodes:

```powershell
.\\assignment\\scripts\\install-workload-platform.ps1
```

Pinned versions are kube-prometheus-stack `88.0.1`, Alloy `1.11.0`, and Argo CD `10.2.2`.

## Phase 7: build and push the sample image

Terraform creates `600627340244.dkr.ecr.ap-southeast-1.amazonaws.com/eks-lab-sample`. Build one image reused by all three services:

```powershell
.\\assignment\\scripts\\build-push-sample.ps1 -Tag "0.1.0"
```

The image runs as UID `10001`, has no third-party runtime dependencies, and provides:

- `/healthz` and `/readyz` probes.
- `/metrics` in Prometheus text format.
- `/work` for downstream calls, trace propagation, and shared-data writes.
- JSON logs on stdout.
- OTLP/HTTP spans forwarded through Alloy.
- Graceful SIGTERM handling.

The Helm chart deploys `frontend` (2 replicas), `orders` (4 replicas), and `inventory` (2 replicas). `orders` supplies the four-replica spread/PDB demonstration required by the assignment.

## Phase 8: satisfy the manual Karpenter checkpoint

Install Karpenter and its AWS prerequisites yourself on `eks-workload`. Because Terraform enables EKS Pod Identity Agent and does not create an OIDC provider, use Pod Identity for the Karpenter controller or deliberately add your own identity design.

Your manually created capacity must meet this chart contract:

- Karpenter controller schedules on `workload-class=platform` and tolerates `dedicated=platform:NoSchedule`.
- The microservice NodePools add label `workload-tier=mixed`.
- Those nodes add taint `dedicated=microservices:NoSchedule`.
- The one On-Demand plus three Spot demo ratio is represented by separate capacity-constrained NodePools.
- EC2NodeClass subnet/security-group selectors use the private subnet IDs and workload node security group from `terraform output`.

Inspect the needed Terraform outputs:

```powershell
terraform -chdir=assignment/terraform/live output private_subnet_ids
terraform -chdir=assignment/terraform/live output workload_cluster
```

Verify your manual setup:

```powershell
kubectl --context eks-workload -n karpenter get deployment,pods
kubectl --context eks-workload get ec2nodeclass,nodepool,nodeclaim
```

## Phase 9: optional manual EFS checkpoint

The application works immediately with per-pod `emptyDir` storage. Shared persistence defaults off. If you want to complete the EFS acceptance item, manually provide:

- EFS CSI on `eks-workload`.
- An encrypted filesystem with mount targets in both private subnets.
- Network access on TCP/2049 from workload nodes.
- A dynamic RWX StorageClass named `efs-rwx`.
- An access point/POSIX policy compatible with UID `10001` and GID `2000`.

Then change `persistence.enabled` to `true` in `charts/sample-microservices/values.yaml`, commit, and push. The chart will create one `ReadWriteMany` PVC; it does not create EFS infrastructure or a StorageClass.

## Phase 10: deploy only through Argo CD

Commit and push the chart, application source, and Terraform code to the Git URL used during rendering. Do not commit `assignment/generated/` or Terraform state.

Create the Argo CD Application:

```powershell
.\\assignment\\scripts\\deploy-sample-with-argocd.ps1
```

The script checks that the manually installed Karpenter controller is available, then applies only the Argo CD `Application`. Argo CD performs the Helm deployment.

Watch it:

```powershell
kubectl --context eks-workload -n argocd get application sample-microservices -w
kubectl --context eks-workload -n sample get pods -o wide -w
kubectl --context eks-workload get nodes -L workload-tier,karpenter.sh/capacity-type,kubernetes.io/arch
```

Access Argo CD without a load balancer:

```powershell
kubectl --context eks-workload -n argocd port-forward svc/argocd-server 8080:443
```

## Phase 11: validate the assignment

```powershell
.\\assignment\\scripts\\validate.ps1 -Live
kubectl --context eks-workload -n sample get pdb,pvc
kubectl --context eks-workload -n sample get pods -o wide
```

For EFS, call `/work` on one replica and inspect `/data` from another. For disruption, drain one Spot node and confirm each PDB permits at most one unavailable pod. PDBs cover voluntary eviction, not sudden instance loss.

In Grafana, verify:

- Prometheus has metrics with external label `cluster=eks-workload`.
- Loki shows JSON container logs with the workload cluster label.
- Tempo finds traces for `frontend`, `orders`, and `inventory`.

## Teardown order

Do not leave this lab running.

1. Delete the Argo CD Application and let its finalizer remove sample resources.
2. Uninstall workload Helm releases, including ingress-producing resources.
3. Remove your manual Karpenter NodePools/controller/prerequisites and wait for nodes to terminate.
4. Remove your manual EFS/EBS resources after their PVCs are gone.
5. Uninstall Cluster 2 ingress-nginx and verify its NLB is deleted.
6. Run `terraform plan -destroy` in `terraform/live`, review it, then apply that destroy plan.
7. Delete the bootstrap state bucket only after retaining any state you need; `prevent_destroy` intentionally requires a deliberate configuration change.

Before destroying Terraform, confirm there are no Kubernetes-created load balancers, volumes, security groups, or ENIs that would block subnet/VPC cleanup.

## Troubleshooting

- `Unauthorized` from kubectl: rerun `connect-clusters.ps1` with the same SSO identity that applied Terraform.
- API timeout: update the `/32` allowlist and apply a new Terraform plan.
- Platform pods Pending: confirm the `dedicated=platform` toleration in their Helm values and that managed nodes are Ready.
- Sample pods Pending: verify the Karpenter NodePool label and taint contract exactly.
- PVC Pending on Cluster 2: verify your manual EBS CSI IAM, controller pods, AZ topology, and `gp3` StorageClass.
- No remote telemetry: resolve the internal NLB hostname from a workload pod and check ingress-nginx logs/routes.
- Argo CD repository error: make the repository public for the lab or add repository credentials to Argo CD manually.

To build the same lab entirely through the AWS Management Console instead — including the subnets, NAT gateway, IAM roles, both clusters, and teardown — see [AWS-CONSOLE-GUIDE.md](AWS-CONSOLE-GUIDE.md), which is the path the current plan follows.
