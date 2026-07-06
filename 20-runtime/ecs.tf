resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project_name}-${var.env}-api"
  retention_in_days = 14

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "free_worker" {
  name              = "/ecs/${var.project_name}-${var.env}-free-worker"
  retention_in_days = 14

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "paid_worker" {
  name              = "/ecs/${var.project_name}-${var.env}-paid-worker"
  retention_in_days = 14

  tags = local.common_tags
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.env}-cluster"

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project_name}-${var.env}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 512
  memory = 1024

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.api_task.arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = local.api_image
      essential = true

      portMappings = [
        {
          containerPort = var.api_container_port
          hostPort      = var.api_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_NAME", value = "voice-auth-api-service" },
        { name = "APP_ENV", value = "prod" },
        { name = "API_PREFIX", value = "/api" },
        { name = "AWS_REGION", value = var.aws_region },

        { name = "INPUT_BUCKET", value = var.audio_bucket_name },
        { name = "RESULT_BUCKET", value = var.result_bucket_name },

        { name = "FREE_QUEUE_URL", value = aws_sqs_queue.free.url },
        { name = "PAID_QUEUE_URL", value = aws_sqs_queue.paid.url },

        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = "3306" },
        { name = "DB_USER", value = var.db_user },
        { name = "DB_NAME", value = var.db_name },

        { name = "JWT_ALGORITHM", value = "HS256" },
        { name = "JWT_ACCESS_TOKEN_EXPIRE_MINUTES", value = "60" }
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = var.db_password_secret_arn
        },
        {
          name      = "JWT_SECRET_KEY"
          valueFrom = var.jwt_secret_key_secret_arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "api"
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_service" "api" {
  name            = "${var.project_name}-${var.env}-api-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.api_container_port
  }

  depends_on = [
    aws_lb_listener_rule.api
  ]

  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "free_worker" {
  family                   = "${var.project_name}-${var.env}-free-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 4096
  memory = 8192

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.worker_task.arn

  container_definitions = jsonencode([
    {
      name      = "free-worker"
      image     = local.worker_image
      essential = true

      healthCheck = {
        command     = ["CMD-SHELL", "python /workspace/healthcheck.py || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }

      environment = [
        { name = "APP_ENV", value = "prod" },
        { name = "WORKER_MODE", value = "aws" },
        { name = "AWS_REGION", value = var.aws_region },

        { name = "QUEUE_TYPE", value = "free" },
        { name = "FREE_QUEUE_URL", value = aws_sqs_queue.free.url },
        { name = "PAID_QUEUE_URL", value = aws_sqs_queue.paid.url },

        { name = "MODEL_S3_BUCKET", value = var.model_bucket_name },
        { name = "MODEL_S3_KEY", value = "models/wav2LM_Nes2Net_X.pth" },
        { name = "MODEL_DIR", value = "/models" },
        { name = "MODEL_PATH", value = "/models/wav2LM_Nes2Net_X.pth" },

        { name = "XLSR_MODEL_S3_KEY", value = "models/xlsr2_300m.pt" },
        { name = "XLSR_MODEL_PATH", value = "/workspace/xlsr2_300m.pt" },

        { name = "MODEL_NAME", value = "wav2vec2_Nes2Net_X" },
        { name = "MODEL_VERSION", value = "v1" },
        { name = "TEST_MODE", value = "4s" },

        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = "3306" },
        { name = "DB_USER", value = var.db_user },
        { name = "DB_NAME", value = var.db_name }
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = var.db_password_secret_arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.free_worker.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "free-worker"
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_service" "free_worker" {
  name            = "${var.project_name}-${var.env}-free-worker-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.free_worker.arn
  desired_count   = var.free_worker_desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "paid_worker" {
  family                   = "${var.project_name}-${var.env}-paid-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 4096
  memory = 8192

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.worker_task.arn

  container_definitions = jsonencode([
    {
      name      = "paid-worker"
      image     = local.worker_image
      essential = true

      healthCheck = {
        command     = ["CMD-SHELL", "python /workspace/healthcheck.py || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }

      environment = [
        { name = "APP_ENV", value = "prod" },
        { name = "WORKER_MODE", value = "aws" },
        { name = "AWS_REGION", value = var.aws_region },

        { name = "QUEUE_TYPE", value = "paid" },
        { name = "FREE_QUEUE_URL", value = aws_sqs_queue.free.url },
        { name = "PAID_QUEUE_URL", value = aws_sqs_queue.paid.url },

        { name = "MODEL_S3_BUCKET", value = var.model_bucket_name },
        { name = "MODEL_S3_KEY", value = "models/wav2LM_Nes2Net_X.pth" },
        { name = "MODEL_DIR", value = "/models" },
        { name = "MODEL_PATH", value = "/models/wav2LM_Nes2Net_X.pth" },

        { name = "XLSR_MODEL_S3_KEY", value = "models/xlsr2_300m.pt" },
        { name = "XLSR_MODEL_PATH", value = "/workspace/xlsr2_300m.pt" },

        { name = "MODEL_NAME", value = "wav2vec2_Nes2Net_X" },
        { name = "MODEL_VERSION", value = "v1" },
        { name = "TEST_MODE", value = "4s" },

        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = "3306" },
        { name = "DB_USER", value = var.db_user },
        { name = "DB_NAME", value = var.db_name }
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = var.db_password_secret_arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.paid_worker.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "paid-worker"
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_service" "paid_worker" {
  name            = "${var.project_name}-${var.env}-paid-worker-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.paid_worker.arn
  desired_count   = var.paid_worker_desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = local.common_tags
}
