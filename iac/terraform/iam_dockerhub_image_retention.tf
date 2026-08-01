data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "dockerhub_image_retention_trust_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.homelab.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc.subdomain}.${local.route53.parent_zone}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc.subdomain}.${local.route53.parent_zone}:sub"
      values   = ["system:serviceaccount:dockerhub-image-retention:dockerhub-image-retention"]
    }
  }
}

data "aws_iam_policy_document" "dockerhub_image_retention" {
  statement {
    sid = "DockerHubSSMRead"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    effect = "Allow"
    resources = [
      "arn:aws:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter/dockerhub/api/username",
      "arn:aws:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter/dockerhub/api/token",
    ]
  }
}

resource "aws_iam_role" "dockerhub_image_retention" {
  name                 = "dockerhub-image-retention"
  description          = "IRSA role for dockerhub-image-retention CronJob (SSM read)"
  assume_role_policy   = data.aws_iam_policy_document.dockerhub_image_retention_trust_policy.json
  max_session_duration = 43200
}

resource "aws_iam_role_policy" "dockerhub_image_retention" {
  name   = "DockerHubImageRetentionPolicy"
  role   = aws_iam_role.dockerhub_image_retention.id
  policy = data.aws_iam_policy_document.dockerhub_image_retention.json
}
