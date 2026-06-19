data "aws_iam_policy_document" "external_dns_trust_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::712671171381:oidc-provider/oidc.home.bradandmarsha.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "oidc.home.bradandmarsha.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "oidc.home.bradandmarsha.com:sub"
      values   = ["system:serviceaccount:external-dns:external-dns"]
    }
  }
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid = "ExternalDNSChange"
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    effect    = "Allow"
    resources = [aws_route53_zone.homelab_zone.arn]
  }

  statement {
    sid = "ExternalDNSList"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource"
    ]
    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "external-dns"
  description        = "IRSA role for External DNS"
  assume_role_policy = data.aws_iam_policy_document.external_dns_trust_policy.json
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "ExternalDNSPolicy"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}
