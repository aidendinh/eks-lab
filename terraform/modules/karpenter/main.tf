# AWS-side prerequisites for Karpenter: the controller's identity, and the
# interruption queue that tells it a Spot node is about to disappear.
#
# The controller itself (Helm) and the NodePools live in the platform layer —
# they need a Kubernetes provider, which cannot be configured until the cluster
# exists.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  queue_name = "${var.cluster_name}-karpenter"
}

# ------------------------------------------------------------ interruption

# Spot reclaim gives ~2 minutes' notice. Karpenter reads these events and
# cordons + drains the node before EC2 pulls it, which is what keeps the Spot
# side of pool 3 from dropping requests. Retention is short: an interruption
# notice is worthless by the time it is minutes old.
resource "aws_sqs_queue" "interruption" {
  name                      = local.queue_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "EventBridgeAndHealthPublish"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.interruption.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }

  # SQS defaults allow plaintext; deny it explicitly.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.interruption.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy    = data.aws_iam_policy_document.queue.json
}

# Four event sources, all draining to the one queue. Spot interruption is the
# one that matters for pool 3; the others let Karpenter react to a node being
# retired or rebalanced instead of discovering it as a NotReady node later.
locals {
  event_rules = {
    spot-interruption = {
      source      = "aws.ec2"
      detail_type = "EC2 Spot Instance Interruption Warning"
    }
    rebalance = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance Rebalance Recommendation"
    }
    state-change = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance State-change Notification"
    }
    scheduled-change = {
      source      = "aws.health"
      detail_type = "AWS Health Event"
    }
  }
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.event_rules

  name        = "${var.cluster_name}-karpenter-${each.key}"
  description = "Karpenter interruption handling: ${each.value.detail_type}"

  event_pattern = jsonencode({
    source        = [each.value.source]
    "detail-type" = [each.value.detail_type]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.event_rules

  rule = aws_cloudwatch_event_rule.this[each.key].name
  arn  = aws_sqs_queue.interruption.arn
}

# ------------------------------------------------------- controller identity

resource "aws_iam_role" "controller" {
  name = "${var.cluster_name}-karpenter-controller"

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

data "aws_iam_policy_document" "controller" {
  statement {
    sid    = "Ec2AndPricingRead"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "pricing:GetProducts",
      # Karpenter resolves the AL2023 AMI alias through an SSM public parameter.
      "ssm:GetParameter",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Ec2Write"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  # Karpenter hands the node role to the instances it launches.
  statement {
    sid       = "PassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.node_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Karpenter manages the instance profile for the node role itself.
  # ListInstanceProfiles is the one people leave out; without it the controller
  # cannot reconcile the EC2NodeClass and it never goes Ready.
  statement {
    sid    = "InstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfiles",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "InterruptionQueue"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.interruption.arn]
  }

  statement {
    sid       = "EksRead"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_role_policy" "controller" {
  name   = "karpenter-controller"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller.json
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.controller.arn
}
