terraform {
  required_version = "~> 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "brad-tf-state"
    key    = "wise-k8s/terraform.tfstate"
    region = "us-east-2"
  }
}
