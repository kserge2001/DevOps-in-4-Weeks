#!/bin/bash
# Runs once, on the first boot of each instance.
set -euo pipefail

dnf install -y docker
systemctl enable --now docker

aws ecr get-login-password --region ${region} | docker login --username AWS --password-stdin ${registry}

docker run -d --name quickshop --restart always -p 8080:8080 \
  -e PLATFORM=ec2 \
  -e AWS_DEFAULT_REGION=${region} \
  -e DB_HOST=${db_host} \
  -e DB_SECRET_ARN=${db_secret_arn} \
  --log-driver awslogs \
  --log-opt awslogs-region=${region} \
  --log-opt awslogs-group=${log_group} \
  ${image}
