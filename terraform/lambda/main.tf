# Pattern C: Lambda. API Gateway calls the function once per request; nothing runs between requests.
# Same image as the other patterns: the Lambda Web Adapter inside it turns events into HTTP requests.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.70" }
  }
  backend "s3" {
    bucket       = "quickshop-tfstate-315558363288"
    key          = "lambda/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "quickshop", Pattern = "lambda", ManagedBy = "terraform" }
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

# ---------- The function runs inside the VPC so it can reach the private DB
resource "aws_security_group" "fn" {
  name   = "quickshop-lambda"
  vpc_id = local.s.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "fn_out" {
  security_group_id = aws_security_group.fn.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_fn" {
  security_group_id            = local.s.db_sg_id
  referenced_security_group_id = aws_security_group.fn.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_iam_role" "fn" {
  name = "quickshop-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "vpc" {
  role       = aws_iam_role.fn.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole" # ENIs + logs
}

resource "aws_iam_role_policy" "secret" {
  name = "read-db-secret"
  role = aws_iam_role.fn.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = local.s.db_secret_arn }]
  })
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/quickshop"
  retention_in_days = 7
}

resource "aws_lambda_function" "app" {
  function_name = "quickshop"
  role          = aws_iam_role.fn.arn
  package_type  = "Image"
  image_uri     = "${local.s.ecr_url}:${var.image_tag}"
  architectures = ["x86_64"]
  memory_size   = 512
  timeout       = 30
  vpc_config {
    subnet_ids         = local.s.private_subnet_ids
    security_group_ids = [aws_security_group.fn.id]
  }
  environment {
    variables = {
      PLATFORM      = "lambda"
      DB_HOST       = local.s.db_host
      DB_SECRET_ARN = local.s.db_secret_arn
    }
  }
  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy_attachment.vpc]
}

# ---------- HTTP API: every path and method goes to the function
resource "aws_apigatewayv2_api" "http" {
  name          = "quickshop"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "fn" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.app.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "all" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.fn.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# ---------- Monitoring: 5xx answers seen by API Gateway -> SNS
# (an HTTP 500 from the app is a normal Lambda response, so the Lambda "Errors" metric misses it)
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "quickshop-lambda-5xx"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.http.id, Stage = "$default" }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.s.alerts_topic_arn]
}

output "url" { value = aws_apigatewayv2_api.http.api_endpoint }
