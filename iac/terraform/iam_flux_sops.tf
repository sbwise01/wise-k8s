# IRSA for Flux controllers to decrypt SOPS-encrypted manifests with AWS KMS
# (alias/sops from wise-aws-terraform-bootstrap). Kustomization/HelmRelease
# resources opt in via spec.decryption.provider: sops.
data "aws_kms_alias" "sops" {
  name = "alias/sops"
}

data "aws_iam_policy_document" "flux_sops_trust_policy" {
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
        "system:serviceaccount:flux-system:kustomize-controller",
        "system:serviceaccount:flux-system:helm-controller",
      ]
    }
  }
}

data "aws_iam_policy_document" "flux_sops" {
  statement {
    sid = "FluxSOPSDecrypt"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    effect    = "Allow"
    resources = [data.aws_kms_alias.sops.target_key_arn]
  }
}

resource "aws_iam_role" "flux_sops" {
  name                 = "flux-sops"
  description          = "IRSA role for Flux SOPS decryption (AWS KMS)"
  assume_role_policy   = data.aws_iam_policy_document.flux_sops_trust_policy.json
  max_session_duration = 43200
}

resource "aws_iam_role_policy" "flux_sops" {
  name   = "FluxSOPSDecryptPolicy"
  role   = aws_iam_role.flux_sops.id
  policy = data.aws_iam_policy_document.flux_sops.json
}
