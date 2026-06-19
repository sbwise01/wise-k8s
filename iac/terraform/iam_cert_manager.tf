data "aws_iam_policy_document" "cert_manager_trust_policy" {
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
      values = [
        "system:serviceaccount:cert-manager:cert-manager",
        "system:serviceaccount:cert-manager:cert-manager-cainjector",
        "system:serviceaccount:cert-manager:cert-manager-webhook"
      ]
    }
  }
}

data "aws_iam_policy_document" "cert_manager" {
  statement {
    sid = "certManagerGetChange"
    actions = [
      "route53:GetChange"
    ]
    effect    = "Allow"
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid = "certManagerChange"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets"
    ]
    effect    = "Allow"
    resources = [aws_route53_zone.homelab_zone.arn]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }

  statement {
    sid = "certManagerList"
    actions = [
      "route53:ListHostedZonesByName"
    ]
    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_role" "cert_manager" {
  name               = "cert-manager"
  description        = "IRSA role for Certificate Manager"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_trust_policy.json
}

resource "aws_iam_role_policy" "cert_manager" {
  name   = "CertificateManagerPolicy"
  role   = aws_iam_role.cert_manager.id
  policy = data.aws_iam_policy_document.cert_manager.json
}
