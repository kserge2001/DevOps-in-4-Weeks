# Pattern A: EC2. An ALB in front of an Auto Scaling group; each instance runs the image with Docker.
# You own the servers: the OS, Docker, patching, the disk.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.70" }
  }
  backend "s3" {
    bucket       = "quickshop-tfstate-315558363288"
    key          = "ec2/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "quickshop", Pattern = "ec2", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image_tag" {
  description = "Tag of the quickshop image in ECR"
  type        = string
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
  s     = data.terraform_remote_state.shared.outputs
  image = "${local.s.ecr_url}:${var.image_tag}"
}

# ---------- Security groups: internet -> ALB:80 -> app:8080 -> DB:5432
resource "aws_security_group" "alb" {
  name   = "quickshop-ec2-alb"
  vpc_id = local.s.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_out" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "app" {
  name   = "quickshop-ec2-app"
  vpc_id = local.s.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_out" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0" # ECR, Secrets Manager, CloudWatch through the NAT; the DB inside the VPC
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = local.s.db_sg_id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------- Load balancer
resource "aws_lb" "app" {
  name               = "quickshop-ec2"
  load_balancer_type = "application"
  subnets            = local.s.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app" {
  name                 = "quickshop-ec2"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = local.s.vpc_id
  deregistration_delay = 30
  health_check {
    path    = "/health"
    matcher = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------- Instance role: pull the image, read the DB secret, write logs, allow SSM Session Manager
resource "aws_iam_role" "instance" {
  name = "quickshop-ec2-instance"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.instance.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "app" {
  name = "quickshop-app"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = local.s.db_secret_arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.app.arn}:*" },
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "quickshop-ec2-instance"
  role = aws_iam_role.instance.name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/quickshop/ec2"
  retention_in_days = 7
}

# ---------- Launch template + Auto Scaling group
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "app" {
  name_prefix            = "quickshop-ec2-"
  image_id               = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }
  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # +1 hop so the container can reach the instance role
  }
  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    region        = var.region
    registry      = split("/", local.s.ecr_url)[0]
    image         = local.image
    db_host       = local.s.db_host
    db_secret_arn = local.s.db_secret_arn
    log_group     = aws_cloudwatch_log_group.app.name
  }))
}

resource "aws_autoscaling_group" "app" {
  name                      = "quickshop-ec2"
  min_size                  = 2
  max_size                  = 4
  desired_capacity          = 2
  vpc_zone_identifier       = local.s.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120
  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }
  instance_refresh {
    strategy = "Rolling" # a new launch template version replaces instances a few at a time
    preferences {
      min_healthy_percentage = 50
    }
  }
  tag {
    key                 = "Name"
    value               = "quickshop-ec2"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "cpu-50"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

# ---------- Monitoring: alarm -> SNS
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "quickshop-ec2-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.app.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.s.alerts_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  alarm_name          = "quickshop-ec2-unhealthy-hosts"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.app.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [local.s.alerts_topic_arn]
}

output "url" { value = "http://${aws_lb.app.dns_name}" }
