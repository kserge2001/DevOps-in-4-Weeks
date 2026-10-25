# Shared by all four patterns: the network, the database, the image registry, the alert topic.
# Only the compute hop changes between patterns, so everything else lives here.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.70" }
  }
  backend "s3" {
    bucket       = "quickshop-tfstate-315558363288"
    key          = "shared/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "quickshop", ManagedBy = "terraform" }
  }
}

# ---------- Network: public subnets for load balancers, private for compute, isolated for the DB
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name             = "quickshop"
  cidr             = "10.20.0.0/16"
  azs              = ["${var.region}a", "${var.region}b"]
  public_subnets   = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnets  = ["10.20.10.0/24", "10.20.11.0/24"]
  database_subnets = ["10.20.20.0/24", "10.20.21.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # budget choice: one NAT. Production: one per AZ.

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# ---------- Database: PostgreSQL on RDS. Each pattern adds its own ingress rule to this SG.
resource "aws_security_group" "db" {
  name        = "quickshop-db"
  description = "PostgreSQL, reachable only from the app security groups"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_db_instance" "main" {
  identifier                  = "quickshop"
  engine                      = "postgres"
  engine_version              = "18"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_encrypted           = true
  db_name                     = "quickshop"
  username                    = "shop"
  manage_master_user_password = true # RDS keeps the password in Secrets Manager
  db_subnet_group_name        = module.vpc.database_subnet_group_name
  vpc_security_group_ids      = [aws_security_group.db.id]
  multi_az                    = var.multi_az
  backup_retention_period     = 1
  skip_final_snapshot         = true # lab only: production keeps a final snapshot
}

# ---------- Registry: one image for all four patterns
resource "aws_ecr_repository" "app" {
  name                 = "quickshop"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # lab only
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lambda pulls the image with its own service principal, so the repository must allow it.
resource "aws_ecr_repository_policy" "lambda_pull" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaPull"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    }]
  })
}

# ---------- Alerts: every pattern sends its alarms here
resource "aws_sns_topic" "alerts" {
  name = "quickshop-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
