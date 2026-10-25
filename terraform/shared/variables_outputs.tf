variable "region" {
  type    = string
  default = "us-east-1"
}

variable "multi_az" {
  description = "true = a standby DB in a second AZ (production). false = one DB (lab budget)."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email that receives alarms. Empty = no subscription."
  type        = string
  default     = ""
}

output "vpc_id" { value = module.vpc.vpc_id }
output "public_subnet_ids" { value = module.vpc.public_subnets }
output "private_subnet_ids" { value = module.vpc.private_subnets }
output "db_sg_id" { value = aws_security_group.db.id }
output "db_host" { value = aws_db_instance.main.address }
output "db_secret_arn" { value = aws_db_instance.main.master_user_secret[0].secret_arn }
output "ecr_url" { value = aws_ecr_repository.app.repository_url }
output "alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
