# ECR lifecycle policies control image retention for cost and repository hygiene.
# They are separate from vulnerability scanning features such as ECR Scan on Push or Trivy.
#
# Keeping the most recent build-* images provides a conservative dev rollback buffer,
# but does not absolutely protect an older image that is still running. Production
# environments should additionally use protected tags such as stable or rollback-protected.
resource "aws_ecr_lifecycle_policy" "api" {
  repository = data.aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after the configured retention period."
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_image_retention_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep recent build-* images as a dev rollback buffer."
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["build-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_build_image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "worker" {
  repository = data.aws_ecr_repository.worker.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after the configured retention period."
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_image_retention_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep recent build-* images as a dev rollback buffer."
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["build-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_build_image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
