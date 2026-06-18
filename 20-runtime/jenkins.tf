data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_subnet" "jenkins" {
  id = data.terraform_remote_state.network.outputs.private_app_subnet_ids[0]
}

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-${var.env}-jenkins-sg"
  description = "Jenkins EC2 security group"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "Jenkins webhook from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-jenkins-sg"
    Role = "cicd"
  })
}

resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-${var.env}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Role = "cicd"
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "jenkins_deploy" {
  name = "${var.project_name}-${var.env}-jenkins-deploy-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:ListImages",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = [
          data.aws_ecr_repository.api.arn,
          data.aws_ecr_repository.worker.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeClusters",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeTasks"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.api_task.arn,
          aws_iam_role.worker_task.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTargetGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_deploy" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.jenkins_deploy.arn
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-${var.env}-jenkins-instance-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = data.aws_subnet.jenkins.id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = false

  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    dnf update -y
    dnf install -y docker git python3 python3-pip awscli
    dnf install -y docker-compose-plugin || true
    systemctl enable --now docker

    if ! docker compose version; then
      mkdir -p /usr/local/lib/docker/cli-plugins
      COMPOSE_VERSION="2.29.7"
      curl -fsSL "https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/docker-compose-linux-x86_64" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
      chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
      docker compose version
    fi

    mkdir -p /var/jenkins_home

    ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
    ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)"
    JENKINS_HOME_DEVICE="$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vx "$ROOT_DISK" | head -n 1 || true)"

    if [ -z "$JENKINS_HOME_DEVICE" ]; then
      echo "Could not discover Jenkins home EBS by excluding root disk. Falling back to known device names."
    fi

    for i in $(seq 1 30); do
      if [ -n "$JENKINS_HOME_DEVICE" ] && [ -b "$JENKINS_HOME_DEVICE" ]; then
        break
      fi

      for candidate in /dev/nvme1n1 /dev/nvme2n1 /dev/xvdf; do
        if [ -b "$candidate" ] && [ "$candidate" != "$ROOT_DISK" ]; then
          JENKINS_HOME_DEVICE="$candidate"
          break
        fi
      done
      if [ -n "$JENKINS_HOME_DEVICE" ] && [ -b "$JENKINS_HOME_DEVICE" ]; then
        break
      fi
      sleep 2
    done

    if [ -n "$JENKINS_HOME_DEVICE" ]; then
      if ! blkid "$JENKINS_HOME_DEVICE"; then
        mkfs -t xfs "$JENKINS_HOME_DEVICE"
      fi
      JENKINS_HOME_UUID="$(blkid -s UUID -o value "$JENKINS_HOME_DEVICE")"
      if ! grep -q "/var/jenkins_home" /etc/fstab; then
        echo "UUID=$JENKINS_HOME_UUID /var/jenkins_home xfs defaults,nofail 0 2" >> /etc/fstab
      fi
      mount -a
    else
      echo "Jenkins home EBS device was not found. Continuing with root volume path /var/jenkins_home."
    fi
    chown -R 1000:1000 /var/jenkins_home

    mkdir -p /opt/jenkins
    cat > /opt/jenkins/Dockerfile <<'DOCKERFILE'
    FROM jenkins/jenkins:lts-jdk17

    USER root
    RUN apt-get update && \
        apt-get install -y --no-install-recommends \
          awscli \
          git \
          python3 \
          python3-pip \
          python3-venv \
          ca-certificates \
          curl \
          tar \
          gzip && \
        rm -rf /var/lib/apt/lists/*

    RUN curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz -o /tmp/docker.tgz && \
        tar -xzf /tmp/docker.tgz -C /tmp && \
        mv /tmp/docker/docker /usr/local/bin/docker && \
        chmod +x /usr/local/bin/docker && \
        rm -rf /tmp/docker /tmp/docker.tgz

    RUN mkdir -p /usr/local/lib/docker/cli-plugins && \
        curl -fsSL https://github.com/docker/buildx/releases/download/v0.34.1/buildx-v0.34.1.linux-amd64 \
          -o /usr/local/lib/docker/cli-plugins/docker-buildx && \
        chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx && \
        docker buildx version

    USER jenkins
    DOCKERFILE

    cat > /opt/jenkins/docker-compose.yml <<'COMPOSE'
    services:
      jenkins:
        build: .
        container_name: jenkins
        restart: unless-stopped
        user: root
        ports:
          - "8080:8080"
          - "50000:50000"
        environment:
          - DOCKER_HOST=unix:///var/run/docker.sock
          - DOCKER_BUILDKIT=1
        volumes:
          - /var/jenkins_home:/var/jenkins_home
          - /var/run/docker.sock:/var/run/docker.sock
    COMPOSE

    docker compose -f /opt/jenkins/docker-compose.yml up -d --build
  EOF

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.jenkins_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false

    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${var.env}-jenkins-home"
      Role = "cicd"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-jenkins-ec2"
    Role = "cicd"
  })
}

resource "aws_lb_target_group" "jenkins" {
  name        = "${var.project_name}-${var.env}-jenkins-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/login"
    matcher             = "200-499"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, {
    Role = "cicd"
  })
}

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = aws_instance.jenkins.id
  port             = 8080
}

resource "aws_lb_listener_rule" "jenkins_webhook" {
  count        = var.enable_jenkins_webhook_alb_rule ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  condition {
    path_pattern {
      values = ["/github-webhook/*", "/github-webhook/"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}
