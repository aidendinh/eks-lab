# One Secrets Manager secret, named exactly `eks-lab`, holding every credential
# the lab uses. External Secrets Operator projects individual properties out of
# it into Kubernetes Secrets on both clusters.
#
# Single secret, not one per credential: Secrets Manager bills per secret, and
# ESO can address any property of a JSON secret via remoteRef.property, so the
# grouping costs nothing in flexibility.

data "aws_partition" "current" {}

resource "random_password" "grafana" {
  length  = 24
  special = false # keeps the value safe to paste into a browser prompt
}

resource "random_password" "argocd" {
  length  = 24
  special = false
}

# JavaMelody sends this as HTTP Basic userinfo inside a URL, so ':' and '@'
# would corrupt the parse.
resource "random_password" "javamelody" {
  length  = 24
  special = false
}

# bcrypt() re-salts on every evaluation, so hashing inline would show a diff on
# every plan and rewrite the secret forever. Pinning it in terraform_data and
# ignoring changes freezes the hash to the first apply.
# ponytail: rotate by tainting this resource.
resource "terraform_data" "argocd_bcrypt" {
  input = bcrypt(random_password.argocd.result)

  lifecycle {
    ignore_changes = [input]
  }
}

resource "aws_secretsmanager_secret" "this" {
  name        = var.secret_name
  description = "All credentials for the two-cluster EKS lab"

  # A lab is rebuilt often and the default 30-day recovery window makes the
  # name unusable for a month after a destroy.
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id

  secret_string = jsonencode({
    grafana-username = "admin"
    grafana-password = random_password.grafana.result
    argocd-username  = "admin"
    argocd-password  = random_password.argocd.result
    argocd-bcrypt    = terraform_data.argocd_bcrypt.output
    # user:password, consumed both as the collector's authorized-users list and
    # as the userinfo half of the collector URL the apps register with.
    javamelody-auth = "collector:${random_password.javamelody.result}"
  })
}

# ------------------------------------------------------------ ESO identity

# ESO runs on both clusters, so each gets its own role and association.
resource "aws_iam_role" "eso" {
  for_each = var.cluster_names

  name = "${each.key}-external-secrets"

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

# Read-only, and scoped to this one secret's ARN rather than to a prefix
# wildcard: ESO never needs to see anything else in the account.
data "aws_iam_policy_document" "eso" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.this.arn]
  }
}

resource "aws_iam_role_policy" "eso" {
  for_each = var.cluster_names

  name   = "read-eks-lab-secret"
  role   = aws_iam_role.eso[each.key].id
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_eks_pod_identity_association" "eso" {
  for_each = var.cluster_names

  cluster_name    = each.key
  namespace       = var.eso_namespace
  service_account = var.eso_service_account
  role_arn        = aws_iam_role.eso[each.key].arn
}
