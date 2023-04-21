module "ecs" {
  source = "terraform-aws-modules/ecs/aws"

  cluster_name = "keycloak"

  cluster_configuration = {
    execute_command_configuration = {
      logging = "OVERRIDE"
      log_configuration = {
        cloud_watch_log_group_name = "/aws/ecs/aws-ec2"
      }
    }
  }

  fargate_capacity_providers = {
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
        weight = 50
      }
    }
  }

  tags = {
    Environment = "Development"
    Project     = "KeyCloak"
  }
}

resource "aws_secretsmanager_secret" "keycloak_instance_secrets" {
  name                    = "keycloak_instance_secrets"
  recovery_window_in_days = 0 # for immediate deletion, remove once development is done
}

# set initial keycloak admin password (will have to set up secret rotation)
data "aws_secretsmanager_random_password" "keycloak_admin_initial_pass" {
  password_length     = 50
  exclude_punctuation = true
  include_space       = false
}

# set admin password, note keycloak does not allow changing this through vars passed to container image. See https://stackoverflow.com/questions/69000968/keycloak-lost-admin-password
resource "aws_secretsmanager_secret_version" "keycloak_instance_initial_secrets" {
  secret_id = aws_secretsmanager_secret.keycloak_instance_secrets.id
  secret_string = jsonencode({
    adminPassword = data.aws_secretsmanager_random_password.keycloak_admin_initial_pass.random_password
    adminUsername = "admin"
  })

  # ignore any changes to the secret value
  lifecycle {
    ignore_changes = [
      secret_string
    ]
  }
}

data "aws_iam_policy_document" "keycloak_task_execution_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "ecs.amazonaws.com",
        "ecs-tasks.amazonaws.com"
      ]
    }
    actions = ["sts:AssumeRole"]
  }
}

# Role for task execution for keycloak tasks
resource "aws_iam_role" "keycloak_task_execution_role" {
  name               = "keycloak_task_execution_role"
  assume_role_policy = data.aws_iam_policy_document.keycloak_task_execution_role_policy.json
}

resource "aws_iam_role_policy_attachment" "keycloak_task_execution_role_attachment" {
  role       = aws_iam_role.keycloak_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "allow_access_to_keycloak_ecr_repo_doc" {
  statement {
    sid       = "AllowDescribeRepoImage"
    effect    = "Allow"
    actions   = ["ecr:DescribeImages", "ecr:DescribeRepositories"]
    resources = [module.ecr.repository_arn]
  }
}

# allow task definition to access keycloak ecr repo
resource "aws_iam_policy" "allow_access_to_keycloak_ecr_repo" {
  name        = "allow_access_to_keycloak_ecr_repo"
  path        = "/"
  description = "AWS IAM Policy to attach to ecs task executions that need to access ecr private repo"
  policy      = data.aws_iam_policy_document.allow_access_to_keycloak_ecr_repo_doc.json
}

resource "aws_iam_role_policy_attachment" "keycloak_task_access_secrets" {
  role       = aws_iam_role.keycloak_task_execution_role.name
  policy_arn = aws_iam_policy.allow_access_to_keycloak_ecr_repo.arn
}

data "aws_iam_policy_document" "ecs_cloudwatch_logs_doc" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

# allow autoscaling container instances to use cloudwatch apis
resource "aws_iam_policy" "ecs_cloudwatch_logs" {
  name        = "ecs_cloudwatch_logs"
  path        = "/"
  description = "Allows autoscaling container instances to use cloud watch logs apis"
  policy      = data.aws_iam_policy_document.ecs_cloudwatch_logs_doc.json
}

# also allow task execution to write to cloudwatch
resource "aws_iam_role_policy_attachment" "keycloak_task_cloudwatch" {
  role       = aws_iam_role.keycloak_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_cloudwatch_logs.arn
}

data "aws_iam_policy_document" "allow_access_to_keycloak_secrets_doc" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameters", "secretsmanager:GetSecretValue"]
    resources = ["${aws_secretsmanager_secret.keycloak_db_secrets.arn}", "${aws_secretsmanager_secret.keycloak_instance_secrets.arn}"]
  }
}

# allow task execution to get keycloak secrets
resource "aws_iam_policy" "allow_access_to_keycloak_secrets" {
  name        = "allow_access_to_keycloak_secrets"
  path        = "/"
  description = "AWS IAM Policy to attach to ecs task executions access to keycloak secrets"
  policy      = data.aws_iam_policy_document.allow_access_to_keycloak_secrets_doc.json
}

resource "aws_iam_role_policy_attachment" "keycloak_task_execution_role_secret_attachment" {
  role       = aws_iam_role.keycloak_task_execution_role.name
  policy_arn = aws_iam_policy.allow_access_to_keycloak_secrets.arn
}

resource "aws_s3_bucket" "keycloak_s3_ping" {
  bucket_prefix = "keycloak-s3-ping-"

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}

resource "aws_iam_role" "keycloak_task_role" {
  name               = "keycloak_task_role"
  assume_role_policy = data.aws_iam_policy_document.keycloak_task_execution_role_policy.json
}

data "aws_iam_policy_document" "allow_access_to_keycloak_s3_ping" {
  statement {
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]
    # resources = [aws_s3_bucket.keycloak_s3_ping.arn, "${aws_s3_bucket.keycloak_s3_ping.arn}/*"]
  }
}

resource "aws_iam_policy" "allow_access_to_keycloak_s3_ping" {
  name        = "allow-access-to-keycloak-s3-ping"
  path        = "/"
  description = "AWS IAM Policy to attach to ecs tasks for access to keycloak s3 ping"
  policy      = data.aws_iam_policy_document.allow_access_to_keycloak_s3_ping.json
}

resource "aws_iam_role_policy_attachment" "keycloak_task_role_s3_attachment" {
  role       = aws_iam_role.keycloak_task_role.name
  policy_arn = aws_iam_policy.allow_access_to_keycloak_s3_ping.arn
}

resource "aws_ecs_task_definition" "keycloak" {
  execution_role_arn       = aws_iam_role.keycloak_task_execution_role.arn
  task_role_arn            = aws_iam_role.keycloak_task_role.arn
  family                   = "keycloak"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024

  container_definitions = jsonencode([
    {
      name   = "keycloak"
      cpu    = 512
      memory = 1024
      environment = [
        {
          name  = "KC_DB"
          value = "postgres"
        },
        {
          name  = "KC_HOSTNAME"
          value = aws_route53_record.auth_alias.name
        },
        {
          name  = "KC_HEALTH_ENABLED"
          value = "true"
        },
        {
          name  = "KC_HOSTNAME_STRICT_BACKCHANNEL"
          value = "true"
        },
        {
          name  = "JAVA_OPTS_APPEND"
          value = "-Djgroups.s3.region_name=${var.aws_region} -Djgroups.s3.bucket_name=${aws_s3_bucket.keycloak_s3_ping.id} -Dquarkus.transaction-manager.enable-recovery=true"
        },
        {
          name  = "KC_CACHE_STACK"
          value = "ec2"
        },
        {
          name  = "KC_PROXY"
          value = "edge"
        },
      ]
      command   = ["start", "--optimized"]
      essential = true
      image     = "${module.ecr.repository_url}:${var.keycloak_image_tag}"
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-create-group"  = "true"
          "awslogs-group"         = "awslogs-keycloak"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "keycloak"
        }
      }
      portMappings = [
        {
          containerPort = 8080 //  web port
        },
        { containerPort : 7800 },  // jgroups-s3
        { containerPort : 57800 }, // jgroups-s3-fd
      ]
      secrets = [
        {
          name      = "KC_DB_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.keycloak_db_secrets.arn}:password::"
        },
        {
          name      = "KC_DB_URL_HOST"
          valueFrom = "${aws_secretsmanager_secret.keycloak_db_secrets.arn}:host::"
        },
        {
          name      = "KC_DB_USERNAME"
          valueFrom = "${aws_secretsmanager_secret.keycloak_db_secrets.arn}:username::"
        },
        {
          name      = "KEYCLOAK_ADMIN"
          valueFrom = "${aws_secretsmanager_secret.keycloak_instance_secrets.arn}:adminUsername::"
        },
        {
          name      = "KEYCLOAK_ADMIN_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.keycloak_instance_secrets.arn}:adminPassword::"
        },
        {
          name      = "KC_DB_URL_PORT"
          valueFrom = "${aws_secretsmanager_secret.keycloak_db_secrets.arn}:port::"
        },
        {
          name      = "KC_DB_URL_DATABASE"
          valueFrom = "${aws_secretsmanager_secret.keycloak_db_secrets.arn}:dbName::"
        }
      ]
    }
  ])
}

resource "aws_security_group" "keycloak" {
  name        = "keycloak"
  description = "Security group for keycloak instances"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "allow_https_keycloak" {
  from_port                = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.keycloak.id
  to_port                  = 8080
  type                     = "ingress"
  source_security_group_id = aws_security_group.keycloak_alb.id
  description              = "Allow http into instance"
}

resource "aws_security_group_rule" "allow_jgroups_tcp_keycloak" {
  from_port                = 7800
  protocol                 = "tcp"
  security_group_id        = aws_security_group.keycloak.id
  to_port                  = 7800
  type                     = "ingress"
  source_security_group_id = aws_security_group.keycloak.id # all ecs tasks need to be able to communicate with each other on this port for clustering
  description              = "Allow keycloak jgroups-tcp"
}

resource "aws_security_group_rule" "allow_jgroups_tcp_fd_keycloak" {
  from_port                = 57800
  protocol                 = "tcp"
  security_group_id        = aws_security_group.keycloak.id
  to_port                  = 57800
  type                     = "ingress"
  source_security_group_id = aws_security_group.keycloak.id # all ecs tasks need to be able to communicate with each other on this port for clustering
  description              = "Allow keycloak jgroups-tcp-fd"
}

resource "aws_security_group_rule" "allow_all_outbound_keycloak" {
  from_port         = 0
  protocol          = "-1"
  security_group_id = aws_security_group.keycloak.id
  to_port           = 0
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound internet traffic"
}

resource "aws_ecs_service" "keycloak" {
  name                              = "keycloak"
  cluster                           = module.ecs.cluster_id
  desired_count                     = 2
  force_new_deployment              = true
  task_definition                   = aws_ecs_task_definition.keycloak.arn
  scheduling_strategy               = "REPLICA"
  health_check_grace_period_seconds = 120

  load_balancer {
    target_group_arn = aws_lb_target_group.keycloak_target_group_http.arn
    container_name   = "keycloak"
    container_port   = "8080"
  }

  network_configuration {
    subnets          = module.vpc.public_subnets
    security_groups  = [aws_security_group.keycloak.id]
    assign_public_ip = true
  }

  lifecycle {
    ignore_changes = [
      desired_count,
      # This one is kinda a bug https://github.com/hashicorp/terraform-provider-aws/issues/22823
      capacity_provider_strategy
    ]
  }
}

