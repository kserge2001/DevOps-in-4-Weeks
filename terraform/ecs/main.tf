# Pattern B: ECS on Fargate. Same image, same ALB idea; AWS runs the servers under the containers.
# You own the task definition (CPU, memory, env, roles); there is no OS to patch.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.70" }
  }
  backend "s3" {
    bucket       = "quickshop-tfstate-315558363288"
    key          = "ecs/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "quickshop", Pattern = "ecs", ManagedBy = "terraform" }
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
  s = data.terraform_remote_state.shared.outputs
}

# ---------- Security groups: internet -> ALB:80 -> task:8080 -> DB:5432
resource "aws_security_group" "alb" {
  name   = "quickshop-ecs-alb"
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
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "task" {
  name   = "quickshop-ecs-task"
  vpc_id = local.s.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_out" {
  security_group_id = aws_security_group.task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_task" {
  security_group_id            = local.s.db_sg_id
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------- Load balancer (target type ip: Fargate tasks have their own IP)
resource "aws_lb" "app" {
  name               = "quickshop-ecs"
  load_balancer_type = "application"
  subnets            = local.s.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app" {
  name                 = "quickshop-ecs"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
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

# ---------- Two roles: the execution role is for ECS (pull image, write logs), the task role is for your code
resource "aws_iam_role" "execution" {
  name = "quickshop-ecs-execution"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "quickshop-ecs-task"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "task" {
  name = "read-db-secret"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = local.s.db_secret_arn }]
  })
}

# ---------- Cluster, task definition, service
resource "aws_ecs_cluster" "main" {
  name = "quickshop"
  setting {
    name  = "containerInsights"
    value = "enabled" # CPU, memory, task counts in CloudWatch
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/quickshop/ecs"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "app" {
  family                   = "quickshop"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name         = "app"
    image        = "${local.s.ecr_url}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = 8080 }]
    environment = [
      { name = "PLATFORM", value = "ecs" },
      { name = "DB_HOST", value = local.s.db_host },
      { name = "DB_SECRET_ARN", value = local.s.db_secret_arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = "quickshop"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = local.s.private_subnet_ids
    security_groups = [aws_security_group.task.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true # new tasks keep failing -> ECS goes back to the last working task definition
  }
  depends_on = [aws_lb_listener.http]
  lifecycle {
    ignore_changes = [desired_count] # autoscaling owns it after creation
  }
}

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 6
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "cpu-50"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  policy_type        = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 50
  }
}

# ---------- Monitoring: alarm -> SNS
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "quickshop-ecs-5xx"
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

output "url" { value = "http://${aws_lb.app.dns_name}" }
