data "aws_iam_policy_document" "route53_ddns_trust_policy" {
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
      values   = ["system:serviceaccount:route53-ddns:route53-ddns"]
    }
  }
}

data "aws_iam_policy_document" "route53_ddns" {
  statement {
    sid = "Route53DDNSChange"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets"
    ]
    effect    = "Allow"
    resources = [aws_route53_zone.homelab_zone.arn]
  }

  statement {
    sid = "Route53DDNSList"
    actions = [
      "route53:ListHostedZonesByName"
    ]
    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_role" "route53_ddns" {
  name               = "route53-ddns"
  description        = "IRSA role for Route53 DDNS"
  assume_role_policy = data.aws_iam_policy_document.route53_ddns_trust_policy.json
}

resource "aws_iam_role_policy" "route53_ddns" {
  name   = "Route53DDNSPolicy"
  role   = aws_iam_role.route53_ddns.id
  policy = data.aws_iam_policy_document.route53_ddns.json
}
