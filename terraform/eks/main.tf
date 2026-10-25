# Pattern D: EKS. Everything runs in Kubernetes except the database, which stays on RDS.
# Terraform builds the cluster, the nodes, the add-ons and the IAM; the app itself is Kubernetes YAML (capstone/k8s).

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.70" }
  }
  backend "s3" {
    bucket       = "quickshop-tfstate-315558363288"
    key          = "eks/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "quickshop", Pattern = "eks", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "quickshop-tfstate-315558363288"
    key    = "shared/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  s = data.terraform_remote_state.shared.outputs
}

# ---------- Cluster + managed nodes + add-ons
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name                                     = "quickshop"
  kubernetes_version                       = "1.37"
  endpoint_public_access                   = true # lab: kubectl from your laptop. Production: private + VPN.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = local.s.vpc_id
  subnet_ids = local.s.private_subnet_ids

  addons = {
    vpc-cni                         = { before_compute = true }
    eks-pod-identity-agent          = { before_compute = true }
    kube-proxy                      = {}
    coredns                         = {}
    metrics-server                  = {} # feeds the HPA
    amazon-cloudwatch-observability = {} # Container Insights: node/pod metrics + container logs
  }

  eks_managed_node_groups = {
    general = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      iam_role_additional_policies = {
        cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      }
    }
  }
}

# Pods use the node security group, so the DB lets the nodes in.
resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  security_group_id            = local.s.db_sg_id
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------- Pod Identity: an IAM role for one Kubernetes service account, no keys
locals {
  pod_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role" "app" {
  name               = "quickshop-eks-app"
  assume_role_policy = local.pod_trust
}

resource "aws_iam_role_policy" "app" {
  name = "read-db-secret"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = local.s.db_secret_arn }]
  })
}

resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = module.eks.cluster_name
  namespace       = "quickshop"
  service_account = "quickshop"
  role_arn        = aws_iam_role.app.arn
}

resource "aws_iam_role" "alb_controller" {
  name               = "quickshop-eks-alb-controller"
  assume_role_policy = local.pod_trust
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/alb_controller_policy.json") # v3.6.0 policy from the controller repo
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller.arn
}

output "cluster_name" { value = module.eks.cluster_name }
output "vpc_id" { value = local.s.vpc_id }
output "db_host" { value = local.s.db_host }
output "db_secret_arn" { value = local.s.db_secret_arn }
output "image_repo" { value = local.s.ecr_url }
