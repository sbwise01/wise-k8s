resource "aws_iam_openid_connect_provider" "homelab" {
  url             = "https://${local.oidc.subdomain}.${local.route53.parent_zone}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = local.oidc.thumbprint_list
}
