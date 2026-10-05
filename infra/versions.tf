terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # The bucket is passed at init time (make init STATE_BUCKET=...), so a fresh clone can
  # use its own; backend blocks cannot read variables.
  backend "s3" {
    key          = "kv-cache-demo/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = var.project
    }
  }
}
