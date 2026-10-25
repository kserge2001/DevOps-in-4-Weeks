# The pipeline's identity: GitHub Actions gets short-lived AWS credentials through OIDC. No keys in GitHub.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.70" }
  }
  backend "s3" {
    bucket       = "quickshop-tfstate-315558363288"
    key          = "cicd/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "quickshop", ManagedBy = "terraform" }
  }
}

variable "github_repo" {
  description = "owner/name of the GitHub repository that may deploy"
  type        = string
}

variable "create_github_oidc_provider" {
  description = "false if the account already has token.actions.githubusercontent.com (one per account)"
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Give the pipeline access to this EKS cluster's quickshop namespace. Empty = no EKS access."
  type        = string
  default     = ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_caller_identity" "me" {}

locals {
  oidc_arn = "arn:aws:iam::${data.aws_caller_identity.me.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

resource "aws_iam_role" "deploy" {
  name = "quickshop-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # Only this repo: its main branch, or a job that runs in one of its environments
        StringLike = { "token.actions.githubusercontent.com:sub" = [
          "repo:${var.github_repo}:ref:refs/heads/main",
          "repo:${var.github_repo}:environment:*",
        ] }
      }
    }]
  })
  depends_on = [aws_iam_openid_connect_provider.github]
}

# Lab only: Terraform in the pipeline creates IAM roles, load balancers, functions...
# Production: a scoped policy, and a read-only role for `plan` on pull requests.
resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# EKS: an IAM role is not a Kubernetes user. An access entry maps it, here to edit rights in one namespace only.
resource "aws_eks_access_entry" "deploy" {
  count         = var.eks_cluster_name == "" ? 0 : 1
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.deploy.arn
}

resource "aws_eks_access_policy_association" "deploy" {
  count         = var.eks_cluster_name == "" ? 0 : 1
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
  access_scope {
    type       = "namespace"
    namespaces = ["quickshop"]
  }
  depends_on = [aws_eks_access_entry.deploy]
}

output "role_arn" { value = aws_iam_role.deploy.arn }
