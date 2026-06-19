resource "aws_route53_zone" "homelab_zone" {
  name              = local.route53.parent_zone
  delegation_set_id = local.route53.delegation_set_id
}
