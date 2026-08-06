# EFS for the microservice PersistentVolumes.
#
# EBS cannot serve this claim: the three Deployments share one volume, their
# replicas spread across nodes in two AZs, and an EBS volume is both zonal and
# ReadWriteOnce. EFS is regional and ReadWriteMany, so one claim backs every
# replica wherever Karpenter happens to place it.

data "aws_partition" "current" {}

resource "aws_efs_file_system" "this" {
  creation_token = var.name
  encrypted      = true

  # Elastic scales throughput with demand instead of with provisioned size.
  # Bursting on a near-empty filesystem earns almost no credits, and the lab
  # writes little but writes it from every replica.
  throughput_mode = "elastic"

  # Nothing here is worth Standard storage after a week; the lab is torn down
  # long before, but the policy costs nothing and stops a forgotten filesystem
  # billing at full rate.
  lifecycle_policy {
    transition_to_ia = "AFTER_7_DAYS"
  }

  tags = merge(var.tags, { Name = var.name })
}

# Mount targets are per-AZ and each gets an ENI in that subnet. A pod can only
# reach the filesystem through the mount target in its own AZ, so every subnet
# that can host a pod needs one.
# Keyed by AZ, not by subnet id: subnet ids are only known after apply, and a
# for_each over unknown keys cannot be planned.
resource "aws_efs_mount_target" "this" {
  for_each = var.subnets_by_az

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.this.id]
}

resource "aws_security_group" "this" {
  name        = "${var.name}-efs"
  description = "NFS from cluster nodes to the EFS mount targets"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-efs" })
}

# Scoped to the VPC CIDR rather than to a cluster security group: Karpenter
# nodes come and go and attach the cluster SG, but the mount targets must also
# be reachable from the managed node groups of both clusters. One private-range
# rule covers all of them without a dependency cycle between the SGs.
resource "aws_vpc_security_group_ingress_rule" "nfs" {
  security_group_id = aws_security_group.this.id
  description       = "NFS from inside the VPC"
  cidr_ipv4         = var.vpc_cidr_block
  from_port         = 2049
  to_port           = 2049
  ip_protocol       = "tcp"
}

# ------------------------------------------------------- CSI driver identity

resource "aws_iam_role" "csi" {
  name = "${var.name}-efs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      # TagSession is required by Pod Identity; without it the association
      # fails to vend credentials and the controller logs AccessDenied.
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "csi" {
  role       = aws_iam_role.csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.csi.arn
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The controller only schedules where the platform nodes are, and those are
  # tainted; the node DaemonSet must tolerate everything or pods on Karpenter
  # nodes can never mount.
  configuration_values = jsonencode({
    controller = {
      nodeSelector = var.controller_node_selector
      tolerations  = var.controller_tolerations
    }
    node = {
      tolerations = [{ operator = "Exists" }]
    }
  })

  tags = var.tags

  depends_on = [
    aws_eks_pod_identity_association.csi,
    aws_iam_role_policy_attachment.csi,
    aws_efs_mount_target.this,
  ]
}
