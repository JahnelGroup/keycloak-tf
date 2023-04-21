resource "aws_security_group" "keycloak_alb" {
  name        = "keycloak_alb"
  description = "Security group for keycloak load balancer"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "allow_https_keycloak_load_balancer" {
  from_port         = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.keycloak_alb.id
  to_port           = 443
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow https into instance"
}

resource "aws_security_group_rule" "allow_all_outbound_keycloak_load_balancer" {
  from_port         = 0
  protocol          = "-1"
  security_group_id = aws_security_group.keycloak_alb.id
  to_port           = 0
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound internet traffic"
}

resource "aws_lb" "keycloak_load_balancer" {
  name               = "keycloak-load-balancer"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.keycloak_alb.id]
  subnets            = module.vpc.public_subnets
  ip_address_type    = "ipv4"
}

resource "aws_lb_target_group" "keycloak_target_group_http" {
  health_check {
    enabled             = true
    healthy_threshold   = 5
    matcher             = "200"
    path                = "/health/ready"
    protocol            = "HTTP"
    unhealthy_threshold = 2
  }
  name        = "keycloak-target-group-http"
  port        = "8080"
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "keycloak_load_balancer_listen_https" {
  load_balancer_arn = aws_lb.keycloak_load_balancer.arn
  certificate_arn   = aws_acm_certificate_validation.auth_cert_validation.certificate_arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak_target_group_http.arn

    forward {
      target_group {
        arn    = aws_lb_target_group.keycloak_target_group_http.arn
        weight = 100
      }

      stickiness {
        enabled  = true
        duration = 86400
      }
    }
  }
}

