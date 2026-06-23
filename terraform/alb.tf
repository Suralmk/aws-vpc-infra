# -- ALB - sits in public subnet and forwards traffic to EC2
resource "aws_lb" "app_alb" {
  name               = "${var.environment}-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets

  tags = { Name = "${var.environment}-alb" }
}

# TARGET GROUP WHERE ALB SENDS TRAFFIC
# helath check hits /health
resource "aws_lb_target_group" "app_tg" {
  name     = "${var.environment}-app-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "${var.environment}-tg" }
}

# --- ALB Listener ---
# Listens on port 80, forwards to the target group.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# ATTACH EC2 TO THE TARGET GROUP
resource "aws_lb_target_group_attachment" "app_attach" {
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.backend_app.id
  port             = 8000
}
