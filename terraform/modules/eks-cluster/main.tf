# One reusable cluster. Called twice from the lab root: once for the workload
# cluster (tainted platform nodes) and once for the observability cluster.

data "aws_partition" "current" {}

# ---------------------------------------------------------------- cluster role

resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ------------------------------------------------------------------- cluster

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    # Locked to the operator's address. Terraform, kubectl and helm all run from
    # there; nothing in-cluster uses the public endpoint.
    public_access_cidrs = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = var.enabled_log_types

  # No encryption_config: since 1.28 EKS envelope-encrypts secrets with an
  # AWS-owned key by default, and a customer-managed KMS key is a per-month
  # charge plus a teardown footgun for a lab.

  tags = merge(var.tags, { Name = var.name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    # Must exist first. With control-plane logging enabled EKS creates this log
    # group itself the moment the cluster starts, with no retention set — and
    # then Terraform's own create fails with ResourceAlreadyExists. Creating it
    # up front means EKS finds it and the retention below actually applies.
    aws_cloudwatch_log_group.cluster,
  ]
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# --------------------------------------------------------------- node IAM role

resource "aws_iam_role" "node" {
  name = "${var.name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    # PullOnly, not the full PowerUser policy: nodes never push images.
    "AmazonEC2ContainerRegistryPullOnly",
    # Lets SSM reach the node for debugging without opening SSH or a bastion.
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.key}"
}

# Karpenter-launched nodes register with this same role, so it needs an access
# entry of type EC2_LINUX for their kubelets to authenticate.
resource "aws_eks_access_entry" "node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

# ------------------------------------------------------------------- admins

# bootstrap_cluster_creator_admin_permissions above grants Kubernetes admin to
# exactly one principal: whoever ran the first `apply`. Everyone else — a second
# operator, a CI role, or the same human whose console sign-in resolves to a
# different principal than their CLI profile — authenticates fine at the IAM
# layer and is then Unauthorized by Kubernetes RBAC. These entries are how any
# other identity gets in; there is no aws-auth ConfigMap under
# authentication_mode = "API".
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = var.tags
}

# An entry on its own authenticates but authorises nothing; the policy
# association is what carries the permissions.
resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ------------------------------------------------------------- managed nodes

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  # EBS volumes are zonal: a node group pinned to one subnet can always replace
  # a node in the AZ where its volumes already live.
  subnet_ids = each.value.subnet_ids

  ami_type       = each.value.ami_type
  capacity_type  = each.value.capacity_type
  instance_types = each.value.instance_types
  disk_size      = each.value.disk_size

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  labels = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(var.tags, each.value.tags)

  # Replacing a node group in place is a long, disruptive operation; let a new
  # one come up first.
  lifecycle {
    create_before_destroy = true
    # desired_size drifts as things scale; adopting that drift on every apply
    # would fight whatever scaled it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ------------------------------------------------------------------- add-ons

# Pod Identity replaces IRSA here: no OIDC trust JSON per role, and the
# association is a first-class API object instead of a service-account
# annotation. Installed before the others because the CSI drivers use it.
resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  depends_on = [aws_eks_node_group.this]
}

# CoreDNS must come up *after* nodes exist, and on the workload cluster every
# node is tainted — so the add-on needs a matching nodeSelector/tolerations or
# its pods sit Pending and cluster DNS is dead. Add-on configuration replaces
# rather than merges, so the defaults are restated in the caller's value.
# EBS CSI, for the clusters that host stateful components. The observability
# cluster needs it (Prometheus, Loki and Tempo each keep a PersistentVolume);
# the workload cluster does not, because its only claim is the shared EFS one.
resource "aws_iam_role" "ebs_csi" {
  count = var.enable_ebs_csi ? 1 : 0

  name = "${var.name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.enable_ebs_csi ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  count = var.enable_ebs_csi ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi[0].arn
}

resource "aws_eks_addon" "ebs_csi" {
  count = var.enable_ebs_csi ? 1 : 0

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  depends_on = [
    aws_eks_node_group.this,
    aws_eks_pod_identity_association.ebs_csi,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values        = var.coredns_configuration_values
  tags                        = var.tags

  depends_on = [aws_eks_node_group.this]
}
