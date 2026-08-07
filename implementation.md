# Two-cluster EKS lab — build runbook

Terraform builds everything. Region `ap-southeast-1`, AWS CLI profile `AWS`.
Architecture and design rationale: [`assignment/README.md`](assignment/README.md).

Rough cost while running: two EKS control planes ($0.20/hr), one NAT gateway
($0.045/hr), five `t3.medium` plus whatever Karpenter launches, three NLBs, EFS.
Call it **$0.60–0.80/hr**. Tear it down the same day — section 6.

## 0. Prerequisites

- `terraform` ≥ 1.9, `kubectl`, `helm` 3+, `docker` with `buildx`, `aws` CLI v2.
- `aws sts get-caller-identity --profile AWS` must succeed.
- No `terraform.tfvars` is required — the defaults build the lab as it stands.

Both clusters' public API endpoints default to `0.0.0.0/0`. The API still
requires AWS IAM authentication and a matching EKS access entry, so this is
reachability rather than authorisation, and it is what EKS itself defaults to
when public access is enabled. It does place both API servers on the internet.

To restrict them instead, copy `terraform.tfvars.example` to
`terraform.tfvars` in `10-infra` and set:

```hcl
api_public_access_cidrs = ["<your ip>/32"]   # curl -s https://checkip.amazonaws.com
```

`terraform.tfvars` is git-ignored, because that value identifies where you work
from. If you lock it down, re-run `terraform apply` in `10-infra` whenever your
address changes or every `kubectl` call will hang.

## 1. Images

Three images, all multi-arch — `inventory` runs on Graviton, so a single-arch
image would leave its pods in `ImagePullBackOff` with no obvious cause.

```bash
cd terraform/envs/lab/10-infra && terraform init && terraform apply   # creates the ECR repo
REPO=$(terraform output -raw ecr_repository_url)

aws ecr get-login-password --profile AWS --region ap-southeast-1 \
  | docker login --username AWS --password-stdin "${REPO%%/*}"

docker buildx create --name ekslab --use --bootstrap   # once

cd ../../../../assignment/apps
for spec in "sample-microservice:0.1.0" \
            "orders-java:orders-java-0.1.0" \
            "javamelody-collector:javamelody-collector-2.8.0"; do
  docker buildx build --platform linux/amd64,linux/arm64 \
    --provenance=false --sbom=false \
    -t "$REPO:${spec#*:}" --push "${spec%%:*}"
done
```

Verify each tag really is an index with two children:

```bash
docker buildx imagetools inspect "$REPO:0.1.0" | grep Platform
```

> Source files must not carry a UTF-8 BOM. `javac` rejects it outright
> (`illegal character: '﻿'`) and the Maven build fails inside the image
> build, where `-q` hides the reason.

## 2. Infrastructure — `10-infra`

```bash
cd terraform/envs/lab/10-infra
terraform init
terraform apply
```

Creates the VPC, both clusters, managed node groups, EFS, the Karpenter IAM and
interruption queue, and the single `eks-lab` Secrets Manager secret. Takes about
20 minutes, most of it EKS control planes.

Then point kubectl at both:

```bash
for c in eks-workload eks-observability; do
  aws eks update-kubeconfig --profile AWS --region ap-southeast-1 --name $c --alias $c
done
kubectl --context eks-workload get nodes -L workload-class
kubectl --context eks-observability get nodes -L workload-class
```

Expect 3 Ready and 2 Ready. `Unauthorized` means your CLI identity differs from
the one that created the clusters; a hang means `api_public_access_cidrs` was
narrowed and no longer includes your address.

The same applies to the console: the EKS **Nodes** and **Workloads** tabs read
the Kubernetes API, so an account administrator with no access entry sees
`Error loading resources — Unauthorized` there while every IAM-backed tab loads
normally. Only the principal that ran the first `apply` is a Kubernetes admin.
Add others through `cluster_admin_principal_arns`, using the IAM role ARN rather
than the assumed-role session ARN `aws sts get-caller-identity` returns:

```hcl
cluster_admin_principal_arns = [
  "arn:aws:iam::600627340244:role/aws-reserved/sso.amazonaws.com/ap-southeast-1/AWSReservedSSO_Admin_abc123",
]
```

## 3. Platform — `20-platform`

```bash
cd ../20-platform
terraform init
terraform apply
```

Installs, in dependency order: ESO on both clusters → the observability stack →
the workload shippers pointed at its internal NLB → Karpenter, KEDA, Argo CD →
the JavaMelody collector.

> **If `helm_release.resources` fails with `no matches for kind
> "ClusterSecretStore" in version "external-secrets.io/v1"`, re-run `apply`.**
> During this build that error meant the pinned ESO chart was too old to serve
> the `v1` API — fixed by moving to chart 2.8.0. The same message can also
> appear on a genuinely cold cluster, where the Helm provider resolves manifests
> against an API discovery snapshot taken before the release installed its own
> CRDs; a second apply sees them. Everything else converged in one pass.

Outputs:

```bash
terraform output          # telemetry_endpoint, grafana_url, argocd_url
terraform -chdir=../10-infra output -raw grafana_password
terraform -chdir=../10-infra output -raw argocd_password
```

Both UIs are on public NLBs and are credential-gated; the credentials come from
the `eks-lab` secret via ESO, not from either chart's generated default.

## 4. Applications

Nothing here applies the microservices chart. Argo CD syncs it from Git, so the
only step is making sure Git has what you expect:

```bash
git push origin main
kubectl --context eks-workload -n argocd get application sample-microservices
```

`Synced / Healthy` is the goal. Karpenter then launches nodes as the Pending
pods appear — watch with:

```bash
kubectl --context eks-workload get nodes \
  -L workload-tier,karpenter.sh/capacity-type,kubernetes.io/arch -w
```

## 5. Verification

Each command below maps to one requirement.

**Modular Terraform**

```bash
ls terraform/modules            # vpc eks-cluster efs karpenter secrets ...
terraform -chdir=terraform/envs/lab/10-infra validate
terraform -chdir=terraform/envs/lab/20-platform validate
```

**Managed node group runs infrastructure only** — every pod on a `platform`
node should be a system component, and no `sample` pod should appear:

```bash
kubectl --context eks-workload get pods -A -o wide \
  --field-selector spec.nodeName=$(kubectl --context eks-workload get nodes \
    -l workload-class=platform -o jsonpath='{.items[0].metadata.name}')
```

**Three Karpenter pools**

```bash
kubectl --context eks-workload get nodepool
kubectl --context eks-workload get nodepool graviton-arm64 \
  -o jsonpath='{.spec.template.spec.requirements}' | jq
```

**Pool 3 is 1 On-Demand : 3 Spot, and it came from scheduling**

```bash
kubectl --context eks-workload get nodes -l workload-tier=mixed \
  -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

Then confirm nothing hardcoded it — the NodePools name no fleet, only a vCPU
ceiling, and the four nodes exist because four `orders` replicas cannot share
one:

```bash
grep -A3 "limits:" terraform/modules/karpenter-controller/chart/templates/nodepools.yaml
kubectl --context eks-workload -n sample get pods -l app.kubernetes.io/component=orders -o wide
```

**EFS-backed PersistentVolume, dynamically provisioned**

```bash
kubectl --context eks-workload get sc efs-rwx
kubectl --context eks-workload -n sample get pvc,pv
kubectl --context eks-workload -n sample exec deploy/orders -- sh -c 'mount | grep /data'
```

The PV must have no matching pre-created object in Terraform — it is created by
the CSI driver as an EFS access point when the claim is made.

**Topology spread and pod anti-affinity**

```bash
kubectl --context eks-workload -n sample get deploy orders -o jsonpath='{.spec.template.spec.affinity}' | jq
kubectl --context eks-workload -n sample get pods -o wide --sort-by .spec.nodeName
```

No two replicas of one service should share a node.

**Argo CD is the only delivery path**

```bash
helm --kube-context eks-workload list -A | grep sample-microservices
```

The only release is `sample-microservices-app` in `argocd` — the Application
object itself. The workloads in `sample` belong to Argo CD, not Helm.

**KEDA**

```bash
kubectl --context eks-workload -n sample get scaledobject,hpa
```

Drive load at the frontend and watch replicas climb:

```bash
kubectl --context eks-workload -n sample run load --rm -it --image=busybox --restart=Never \
  -- sh -c 'while true; do wget -q -O- http://frontend:8080/work >/dev/null; done'
```

**Metrics, logs and traces reaching cluster 2** — in Grafana, or from the CLI:

```bash
kubectl --context eks-observability -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090 &
curl -s 'localhost:9090/api/v1/query?query=up{cluster="eks-workload"}' | jq '.data.result | length'
```

A non-zero count proves remote-write. For logs and traces, query Loki for
`{cluster="eks-workload"}` and open any trace in Tempo.

**JavaMelody**

```bash
kubectl --context eks-workload -n sample exec deploy/orders -- \
  wget -qO- 'localhost:8080/monitoring?format=prometheus' | head
```

The collector aggregates all four `orders` JVMs; its UI is on the NLB in front
of `javamelody-collector` in `monitoring`, behind Basic auth whose credentials
live in the `eks-lab` secret.

**One secret, synced by ESO**

```bash
aws secretsmanager list-secrets --profile AWS --region ap-southeast-1 \
  --query "SecretList[].Name"
kubectl --context eks-workload get externalsecret -A
kubectl --context eks-observability get externalsecret -A
```

Exactly one lab secret, named `eks-lab`. Every ExternalSecret should report
`SecretSynced`.

## 6. Teardown

Order matters — Kubernetes objects hold AWS resources that Terraform does not
know about (NLBs from Services, EC2 instances from Karpenter).

```bash
# 1. Let Argo CD remove the applications, and Karpenter release its nodes.
kubectl --context eks-workload -n argocd delete application sample-microservices
kubectl --context eks-workload delete nodepool --all
kubectl --context eks-workload get nodes -l workload-tier   # wait until empty

# 2. Platform layer: deletes the Helm releases, and with them the three NLBs.
terraform -chdir=terraform/envs/lab/20-platform destroy

# 3. Infrastructure.
terraform -chdir=terraform/envs/lab/10-infra destroy
```

If step 3 stalls on the VPC, an NLB or its ENIs outlived step 2 — find them in
EC2 → Network Interfaces, filtered by the VPC, and delete them before retrying.

Confirm nothing is left billing:

```bash
aws ec2 describe-nat-gateways --profile AWS --region ap-southeast-1 \
  --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws ec2 describe-addresses --profile AWS --region ap-southeast-1 --query "Addresses[].PublicIp"
aws efs describe-file-systems --profile AWS --region ap-southeast-1 --query "FileSystems[].FileSystemId"
```

All three should be empty.
