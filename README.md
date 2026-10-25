# QuickShop: one app, four platforms

The capstone of the Utrains *DevOps in 4 Weeks* interview prep. One container image runs on:

| Pattern | Folder | Front door |
|---|---|---|
| A. EC2 + Auto Scaling group | `terraform/ec2` | ALB |
| B. ECS Fargate | `terraform/ecs` | ALB |
| C. Lambda (same image, via Lambda Web Adapter) | `terraform/lambda` | API Gateway HTTP API |
| D. EKS (everything but the database) | `terraform/eks` + `k8s/` | ALB from the Ingress |

All four share `terraform/shared` (VPC, RDS PostgreSQL, ECR, SNS alerts) and one pipeline,
`.github/workflows/deploy.yml`, which tests, builds one image, and deploys it to the target you pick.

Order: `app` (run locally) → `terraform/shared` → push the image → one or more patterns → `terraform/cicd` → the pipeline.
Replace the account ID in every `backend "s3"` block with yours. Destroy everything when you're done: the shared stack goes last.
