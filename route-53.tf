resource "aws_route53_zone" "keycloak_zone" {
  name = "keycloak.brennonloveless.com"
}

resource "aws_acm_certificate" "auth_cert" {
  domain_name       = aws_route53_record.auth_alias.fqdn
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "auth_cert_validation" {
  certificate_arn         = aws_acm_certificate.auth_cert.arn
  validation_record_fqdns = [aws_route53_record.auth_subdomain_record.fqdn]
}

resource "aws_route53_record" "auth_subdomain_record" {
  allow_overwrite = true
  name            = tolist(aws_acm_certificate.auth_cert.domain_validation_options)[0].resource_record_name
  records         = [tolist(aws_acm_certificate.auth_cert.domain_validation_options)[0].resource_record_value]
  type            = tolist(aws_acm_certificate.auth_cert.domain_validation_options)[0].resource_record_type
  zone_id         = aws_route53_zone.keycloak_zone.id
  ttl             = 60
}

resource "aws_route53_record" "auth_alias" {
  zone_id = aws_route53_zone.keycloak_zone.zone_id
  name    = "keycloak.brennonloveless.com"
  type    = "A"
  alias {
    name                   = aws_lb.keycloak_load_balancer.dns_name
    zone_id                = aws_lb.keycloak_load_balancer.zone_id
    evaluate_target_health = false
  }
}

