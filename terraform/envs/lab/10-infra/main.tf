# Layer 1: everything that is pure AWS.
#
# Split from the platform layer (20-platform) because a Kubernetes or Helm
# provider cannot be configured from a cluster that does not exist yet — the
# provider block would need an endpoint that is still unknown at plan time.
# Creating the clusters here and consuming their outputs there sidesteps that
# entirely, and makes `terraform destroy` run in the right order.

locals {
  tags = {
    Project     = "eks-two-cluster-assignment"
    Environment = "lab"
    ManagedBy   = "Terraform"
    Owner       = "assignment"
  }

  # Every node in the workload cluster is tainted so that nothing lands there by
  # accident; the microservices belong on Karpenter capacity. Anything that must
  # run on the platform nodes repeats this pair.
  platform_node_selector = { workload-class = "platform" }
  platform_tolerations = [{
    key      = "dedicated"
    operator = "Equal"
    value    = "platform"
    effect   = "NoSchedule"
  }]
}

module "vpc" {
  source = "../../../modules/vpc"

  name       = "eks-lab"
  cidr_block = "10.0.0.0/16"
  azs        = var.azs
  # Karpenter runs only on the workload cluster, so the discovery tag carries
  # that cluster's name.
  karpenter_discovery_value = var.workload_cluster_name
  tags                      = local.tags
}

# ------------------------------------------------------------------ registry

resource "aws_ecr_repository" "apps" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # A lab repository should not survive its lab and block the next `apply` on a
  # name that still holds images.
  force_delete = true

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "apps" {
  repository = aws_ecr_repository.apps.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after a day"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------------------ clusters

# Cluster 1. Every node group here is tainted; application pods run on
# Karpenter-provisioned nodes only.
module "workload_cluster" {
  source = "../../../modules/eks-cluster"

  name                = var.workload_cluster_name
  kubernetes_version  = var.kubernetes_version
  subnet_ids          = module.vpc.private_subnet_ids
  public_access_cidrs = [var.operator_cidr]

  node_groups = {
    # Hosts infrastructure only: Prometheus agent, JavaMelody collector,
    # Karpenter, Argo CD, KEDA, ESO, CSI drivers, Alloy.
    # Three t3.medium rather than two t3.large: same money, more CPU, and it
    # respects the t3.medium size cap that the Karpenter pools are held to.
    platform = {
      subnet_ids     = module.vpc.private_subnet_ids
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      instance_types = ["t3.medium"]
      desired_size   = 3
      min_size       = 3
      max_size       = 4
      labels         = local.platform_node_selector
      taints = [{
        key    = "dedicated"
        value  = "platform"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  # CoreDNS would otherwise sit Pending forever on the tainted nodes, and the
  # add-on replaces this block rather than merging it, so the control-plane
  # tolerations have to be restated alongside ours.
  coredns_configuration_values = jsonencode({
    nodeSelector = local.platform_node_selector
    tolerations = concat(local.platform_tolerations, [
      { key = "CriticalAddonsOnly", operator = "Exists" },
      { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" },
    ])
  })

  tags = local.tags
}

# Cluster 2. Untainted: the whole cluster exists to run the observability stack.
module "observability_cluster" {
  source = "../../../modules/eks-cluster"

  name                = var.observability_cluster_name
  kubernetes_version  = var.kubernetes_version
  subnet_ids          = module.vpc.private_subnet_ids
  public_access_cidrs = [var.operator_cidr]

  node_groups = {
    # Pinned to one AZ on purpose: Prometheus, Loki and Tempo all hold EBS
    # PersistentVolumes, and an EBS volume cannot follow a replacement pod into
    # another zone.
    observability = {
      subnet_ids     = [module.vpc.private_subnet_ids[0]]
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      instance_types = ["t3.medium"]
      desired_size   = 2
      min_size       = 2
      max_size       = 3
      labels         = { workload-class = "observability" }
    }
  }

  tags = local.tags
}

# ------------------------------------------------------------------- storage

# EFS is attached to the workload cluster: it backs the microservices' shared
# ReadWriteMany claim. The observability cluster keeps its EBS/gp2 defaults,
# since each of its stores is a single writer.
module "efs" {
  source = "../../../modules/efs"

  name           = "eks-lab"
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block
  subnets_by_az  = module.vpc.private_subnets_by_az
  cluster_name   = module.workload_cluster.cluster_name

  controller_node_selector = local.platform_node_selector
  controller_tolerations   = local.platform_tolerations

  tags = local.tags
}

# ------------------------------------------------------------------ karpenter

module "karpenter" {
  source = "../../../modules/karpenter"

  cluster_name  = module.workload_cluster.cluster_name
  node_role_arn = module.workload_cluster.node_role_arn
  tags          = local.tags
}

# ------------------------------------------------------------------- secrets

module "secrets" {
  source = "../../../modules/secrets"

  secret_name = "eks-lab"
  cluster_names = toset([
    module.workload_cluster.cluster_name,
    module.observability_cluster.cluster_name,
  ])
  tags = local.tags
}
