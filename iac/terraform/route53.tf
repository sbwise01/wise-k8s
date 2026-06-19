resource "aws_route53_zone" "homelab_zone" {
  name              = "home.bradandmarsha.com"
  delegation_set_id = "N01520513SWFAR055EX7G"
}
