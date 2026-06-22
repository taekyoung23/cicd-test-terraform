variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  type    = string
  default = "sgp"
}

variable "account_id" {
  type    = string
  default = "455535733131"
}

variable "project_name" {
  type    = string
  default = "securevoice"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "audio_bucket_name" {
  type    = string
  default = "mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an"
}

variable "result_bucket_name" {
  type    = string
  default = "mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an"
}

variable "model_bucket_name" {
  type    = string
  default = "mzc-securevoiceguard-model-dev-455535733131-ap-northeast-2"
}

variable "db_host" {
  type = string
}

variable "db_name" {
  type    = string
  default = "mzmt_db"
}

variable "db_user" {
  type    = string
  default = "mzmt"
}

variable "db_password_secret_arn" {
  type      = string
  sensitive = true
}

variable "jwt_secret_key_secret_arn" {
  type      = string
  sensitive = true
}

variable "api_image_tag" {
  type        = string
  description = "API image tag. Use git SHA tag."
}

variable "worker_image_tag" {
  type        = string
  description = "Worker image tag. Use git SHA tag."
}

variable "ecr_build_image_retention_count" {
  type        = number
  default     = 30
  description = "Number of recent build-* ECR images to retain as a dev rollback buffer."

  validation {
    condition     = var.ecr_build_image_retention_count > 0 && floor(var.ecr_build_image_retention_count) == var.ecr_build_image_retention_count
    error_message = "ecr_build_image_retention_count must be a positive integer."
  }
}

variable "ecr_untagged_image_retention_days" {
  type        = number
  default     = 7
  description = "Number of days to retain untagged ECR images before expiration."

  validation {
    condition     = var.ecr_untagged_image_retention_days > 0 && floor(var.ecr_untagged_image_retention_days) == var.ecr_untagged_image_retention_days
    error_message = "ecr_untagged_image_retention_days must be a positive integer."
  }
}

variable "api_container_port" {
  type    = number
  default = 8000
}

variable "api_desired_count" {
  type    = number
  default = 1
}

variable "free_worker_desired_count" {
  type    = number
  default = 1
}

variable "paid_worker_desired_count" {
  type    = number
  default = 1
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "jenkins_volume_size" {
  type    = number
  default = 30
}

variable "enable_jenkins_webhook_alb_rule" {
  type        = bool
  default     = false
  description = "Set true only after team approval to route /github-webhook/* from the service ALB to Jenkins."
}
