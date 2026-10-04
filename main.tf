terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "db_password" {
  type      = string
  sensitive = true
}

resource "aws_vpc" "main" {
  cidr_block = "10.40.0.0/16"

  tags = {
    Name        = "client-management"
    Application = "client-management"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = ["us-east-1a", "us-east-1b"][count.index]
  map_public_ip_on_launch = true
}

resource "aws_ecs_cluster" "main" {
  name = "client-management"
}

resource "aws_security_group" "alb" {
  name        = "client-management-alb"
  description = "Internet-facing entry"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from the internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "alb" {
  name               = "client-management-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "alb"
  }
}

resource "aws_lb_target_group" "client_api" {
  name        = "client-management-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
}

resource "aws_lb_target_group" "billing_api" {
  name        = "billing-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.client_api.arn
  }
}

module "client_api" {
  source = "./modules/ecs-service"

  name               = "client-management-api"
  cluster_id         = aws_ecs_cluster.main.id
  subnet_ids         = aws_subnet.public[*].id
  security_group_ids = [aws_security_group.alb.id]
  target_group_arn   = aws_lb_target_group.client_api.arn
}

module "billing_api" {
  source = "./modules/ecs-service"

  name               = "billing-api"
  cluster_id         = aws_ecs_cluster.main.id
  subnet_ids         = aws_subnet.public[*].id
  security_group_ids = [aws_security_group.alb.id]
  target_group_arn   = aws_lb_target_group.billing_api.arn
}

resource "aws_db_instance" "client_db" {
  identifier          = "client-db"
  engine              = "postgres"
  engine_version      = "16"
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  db_name             = "clientdb"
  username            = "clientadmin"
  password            = var.db_password
  storage_encrypted   = true
  skip_final_snapshot = true

  tags = {
    Name = "client-db"
  }
}

resource "aws_wafv2_web_acl" "alb" {
  name  = "client-management-alb"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = "client-management-alb"
    sampled_requests_enabled   = false
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}
