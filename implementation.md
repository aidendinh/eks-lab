# Two-cluster EKS lab — replication guide

Step-by-step to rebuild this project from scratch. Region `ap-southeast-1`, all console work unless a command is shown. Full explanations live in `assignment/AWS-CONSOLE-GUIDE.md` — this is the checklist version.

## 0. Prerequisites

- Tools: `aws` CLI (SSO profile `AWS`), `kubectl`, `helm`, Docker Desktop, Git.
- Verify identity: `aws sts get-caller-identity --profile AWS` — note your IP (`checkip.amazonaws.com`); both cluster endpoints get locked to `<YOUR_IP>/32`.
- Tag every resource: `Project=eks-two-cluster-assignment`, `Environment=lab`, `ManagedBy=AWSConsole`, `Owner=assignment`.
- Cost: ~$5–7 for a one-sitting build; teardown same day.

## 1. Network (free until the NAT)

- Use the default VPC; create two **private** subnets (one per AZ, e.g. `1a`, `1b`), auto-assign public IP **off**, tag `kubernetes.io/role/internal-elb=1`.
- Create NAT gateway `eks-lab-nat` in a **public** subnet, allocate an Elastic IP, wait Available.
- Create route table `eks-lab-private`: route `0.0.0.0/0 → NAT`, associate **only** the two private subnets.
- Checkpoint: private subnets have no public-IP auto-assign, no IGW route; NAT sits in a public subnet — a NAT in a private subnet routes to itself and nothing works.

## 2. IAM roles (free, kept at teardown)

- `eks-lab-cluster-role` — EKS - Cluster use case, `AmazonEKSClusterPolicy` only. Shared by both clusters.
- `eks-lab-workload-node-role` — EC2 trust, exactly: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly`, `AmazonEKS_CNI_Policy`. Nothing else, ever.
- `eks-lab-observability-node-role` — identical.
- No KMS key anywhere — EKS envelope-encrypts with an AWS-owned key since 1.28.

## 3. ECR and images (before any cluster exists)

- Create private repo `eks-lab-sample`, **Mutable** tags, scan on push, lifecycle rule: expire untagged after 1 day.
- Login: `aws ecr get-login-password --profile AWS --region ap-southeast-1 | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.ap-southeast-1.amazonaws.com`
- Build all three images **multi-arch** (`--platform linux/amd64,linux/arm64 --provenance=false --sbom=false --push`):
  - `:0.1.0` from `assignment/apps/sample-microservice` (Python — frontend, inventory)
  - `:orders-java-0.1.0` from `assignment/apps/orders-java` (Spring Boot + JavaMelody)
  - `:javamelody-collector-2.8.0` from `assignment/apps/javamelody-collector`
- Verify each tag shows an image index with amd64 + arm64 children.

## 4. Cluster `eks-observability` (hourly meter starts)

- EKS → Create cluster, **Custom configuration**, Auto Mode **off**:
  - Version 1.36, service role `eks-lab-cluster-role`, bootstrap admin **on**, auth mode `EKS API`, secrets encryption empty.
  - VPC: the two private subnets only; private endpoint on; public endpoint on, allowlist `<YOUR_IP>/32`.
  - All five control-plane log types on; Container Insights off.
  - Add-ons: exactly VPC CNI, CoreDNS, kube-proxy, Pod Identity Agent. **No CSI drivers.**
- After Active: CloudWatch log group `/aws/eks/eks-observability/cluster` retention → 7 days.
- Node group `observability`: role `eks-lab-observability-node-role`, label `workload-class=observability`, no taints, AL2023 x86-64, **On-Demand**, `t3.large`, 20 GiB, 1/1/1, **one subnet only** (EBS volumes are zonal — two subnets means a replacement node can't attach volumes from the other AZ).

## 5. Cluster `eks-workload`

- Same wizard as section 4, name `eks-workload`; log retention 7 days after Active.
- Node group `platform`: role `eks-lab-workload-node-role`, label `workload-class=platform`, taint `dedicated=platform:NoSchedule`, AL2023 x86-64, On-Demand, `t3.large`+`t3a.large`, 20 GiB, 2/2/2, both private subnets.
- **Immediately after `platform` is Active**: EKS → Add-ons → CoreDNS → Edit → optional configuration — add nodeSelector `workload-class: platform` and tolerations (`CriticalAddonsOnly Exists`, `node-role.kubernetes.io/control-plane Exists NoSchedule`, `dedicated=platform NoSchedule`). Add-on config replaces, not merges — restate the defaults. Without this CoreDNS sits Pending and DNS is broken.
- Node group `graviton-spot`: same role, label `workload-tier=mixed`, taint `dedicated=microservices:NoSchedule`, **AL2023 ARM64**, **Spot**, `t4g.medium`+`t4g.large`, 20 GiB, 1/1/1, both private subnets.
- Final compute shape: pool 1 `platform` (2 On-Demand x86), pool 2 Karpenter 1 On-Demand + 3 Spot x86 (step 10), pool 3 `graviton-spot` (1 Spot arm64).

## 6. Kubeconfig and base health

```
aws eks update-kubeconfig --profile AWS --region ap-southeast-1 --name eks-workload --alias eks-workload
aws eks update-kubeconfig --profile AWS --region ap-southeast-1 --name eks-observability --alias eks-observability
kubectl --context eks-workload get nodes -o wide
kubectl --context eks-observability get nodes -o wide
```

- Expect 3 Ready nodes / 1 Ready node. `Unauthorized` = your CLI identity has no access entry — add one with the IAM **role** ARN, not the assumed-role session ARN.
- No nodes at all = node groups CREATE_FAILED on `Ec2SubnetInvalidConfiguration` = the NAT/private-route work from step 1 is missing or wrong.

## 7. EBS CSI + `gp3` StorageClass (on `eks-observability`)

- IAM role `eks-lab-ebs-csi-role`: custom trust for `pods.eks.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`), attach `AmazonEBSCSIDriverPolicy`.
- EKS → Add-ons → Amazon EBS CSI Driver; Pod Identity association: namespace `kube-system`, SA `ebs-csi-controller-sa`, that role.
- `kubectl --context eks-observability apply -f assignment/k8s/gp3-storageclass.yaml`
- Gate: `get csidriver ebs.csi.aws.com` and `get storageclass gp3` both succeed.

## 8. Observability stack (on `eks-observability`)

- Add helm repos: `prometheus-community`, `grafana`, `grafana-community`, `ingress-nginx`, `argo`; create namespaces `monitoring`, `ingress-nginx`.
- Install, each with `--wait --timeout 15m` and its values file from `assignment/values/`:
  - kube-prometheus-stack 88.0.1 → release `monitoring` (remote-write receiver on, pinned to the observability node)
  - loki 18.7.1 (`grafana-community` repo, SingleBinary, 10 GiB)
  - tempo 2.2.3 (single-binary, OTLP 4317/4318, 10 GiB)
  - ingress-nginx 4.15.1 (internal NLB via annotations)
- `kubectl --context eks-observability apply -f assignment/k8s/telemetry-ingress.yaml`
- Wait for the NLB hostname: `kubectl --context eks-observability -n ingress-nginx get svc ingress-nginx-controller` — stuck `<pending>` = missing `internal-elb` subnet tag.

## 9. Render templates, then workload platform (on `eks-workload`)

- Copy each `.tmpl` into `assignment/generated/` (git-ignored) minus the suffix; replace `__TELEMETRY_ENDPOINT__` with the NLB hostname and `__GIT_REPOSITORY_URL__` with your fork's URL.
- Create namespaces `monitoring`, `argocd`; install with `--wait --timeout 15m`:
  - kube-prometheus-stack 88.0.1 → release `workload-monitoring` with `generated/prometheus-workload.yaml` (a forwarder: 2h retention, remote-writes to the NLB)
  - alloy 1.11.0 with `generated/alloy.yaml` (logs → Loki, traces → Tempo)
  - argo-cd 10.2.2 with `values/argocd.yaml`
- All nodes here are tainted — every component needs the `dedicated=platform` toleration, **including kube-prometheus-stack's admission-webhook patch job** (`prometheusOperator.admissionWebhooks.patch.*`); missing it = install times out on a Pending hook job.
- JavaMelody collector: `kubectl --context eks-workload apply -f assignment/k8s/javamelody-collector.yaml`, wait for rollout.

## 10. Karpenter (on `eks-workload`)

- IAM role `eks-lab-karpenter-controller-role`: Pod Identity trust, inline policy from `assignment/karpenter/controller-policy.json` (must include `iam:ListInstanceProfiles`).
- SQS queue `eks-workload-karpenter`, retention 5 min, access policy allowing EventBridge/SQS to send.
- Four EventBridge rules → the queue: Spot interruption warning, rebalance recommendation, instance state-change, AWS Health event.
- EKS → Access → Pod Identity association: role above, namespace `karpenter`, SA `karpenter`.
- Install controller: `helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --kube-context eks-workload --namespace karpenter --create-namespace --version 1.14.0 --values assignment/karpenter/helm-values.yaml --wait --timeout 10m`
- `kubectl --context eks-workload apply -f assignment/karpenter/nodeclass-nodepools.yaml` — EC2NodeClass on the private subnets + cluster SG; two NodePools (On-Demand capped `cpu: 2`, Spot capped `cpu: 6`), both amd64 `t3.medium`/`t3a.medium`, labeled `workload-tier=mixed`, tainted `dedicated=microservices:NoSchedule`.
- Gate: controller Running, EC2NodeClass Ready, both NodePools Ready at 0 nodes.

## 11. Deploy the sample app via Argo CD

- Commit and push everything except `assignment/generated/`.
- `kubectl --context eks-workload apply -f assignment/generated/app.yaml` — Argo CD syncs `assignment/charts/sample-microservices` from Git; never `helm install` the chart directly.
- Karpenter launches the 1+3 nodes as pods go Pending; watch with `kubectl --context eks-workload get nodes -L workload-tier,karpenter.sh/capacity-type,kubernetes.io/arch`.

## 12. Validate

- Placement: platform pods on platform nodes; sample pods only on `workload-tier=mixed`; four `orders` replicas on four different hostnames; at least one sample pod on the arm64 node.
- Resiliency: every multi-replica deployment has a PDB with allowed disruptions ≥ 1; drain a Spot node — at most one replica of any service evicted; uncordon after.
- Telemetry: port-forward Grafana on the observability cluster — workload metrics (`cluster=eks-workload`), logs in Loki, traces in Tempo.
- JavaMelody: generate traffic via frontend `/work`; `orders` `/monitoring?format=prometheus` returns metrics; collector UI lists exactly four `orders` nodes.

## 13. Teardown (same day)

- Kubernetes first: delete the Argo CD Application, collector, workload helm releases; delete Karpenter NodePools and **wait for its instances to terminate** before removing the controller; then observability releases; wait until the NLB disappears from EC2.
- Delete node groups, then clusters (workload first), waiting for each.
- Delete: ECR image tags, NAT gateway, **release the Elastic IP**, surviving EBS volumes, orphaned ENIs/SGs/target groups, Karpenter SQS/EventBridge/IAM leftovers if not rebuilding.
- Keep (free): private subnets, `eks-lab-private` route table (blackhole NAT route is expected), the IAM roles, the empty ECR repo.
- Never touch the pre-existing VPC, public subnets, their route table, or the IGW.
