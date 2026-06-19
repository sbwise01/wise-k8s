locals {
  region = "us-east-2"
  route53 = {
    parent_zone       = "home.bradandmarsha.com"
    delegation_set_id = "N01520513SWFAR055EX7G"
  }
  oidc = {
    subdomain = "oidc"
    thumbprint_list = [
      "16d069c1cd53a768255ad426bf8025aaff672332",
      "cbcfd09ce3cd22d99d94e58f92e9898fbee51a5e",
      "ab9d0263244dd0326eb67015705a667e79cfe998"
    ]
  }
}
