terraform {
  # Assumes s3 bucket and dynamo DB table already set up
  # See /code/03-basics/aws-backend
  backend "s3" {
    bucket         = "terraformcredentials"
    key            = "03-basics/import-bootstrap/terraform.tfstate"
    region         = "eu-west-3"
    dynamodb_table = "terraform-state-locking"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.63.1" #video, uses version 3 and AWS CLI v1; I suggest upgrading both to ensure credentials works, etc.
    }
  }
}

provider "aws" {
  region = "eu-west-3"
}

resource "aws_instance" "instance_1" {
  ami             = "ami-09d83d8d719da9808" # Ubuntu 20.04 LTS // eu-west-3
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instances.name]
  user_data       = <<-EOF
              #!/bin/bash
              echo "Hello, World 1" > index.html
              python3 -m http.server 8080 &
              EOF
  tags = {
    Name = "Instance1" #I suggest tagging, since it is better to get things more organized / named, despite it is being destroyed
  }
}

resource "aws_instance" "instance_2" {
  ami             = "ami-064508e7b69710843" # Ubuntu 20.04 LTS // eu-west-3
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instances.name]
  user_data       = <<-EOF
              #!/bin/bash
              echo "Hello, World 2" > index.html
              python3 -m http.server 8080 &
              EOF
  tags = {
    Name = "Instance2" #I suggest tagging, since it is better to get things more organized / named, despite it is being destroyed
  }
}

resource "aws_s3_bucket" "bucket" {
  bucket_prefix = "devops-directive-web-app-data"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "bucket_versioning" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_crypto_conf" {
  bucket = aws_s3_bucket.bucket.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_vpc" "default_vpc" {
  default = true
}

data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default_vpc.id]
  }
  filter {
    name   = "availability-zone"
    values = ["eu-west-3a"] # Replace with your desired AZ
  }
}


resource "aws_security_group" "instances" {
  name = "instance-security-group"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instances.id

  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.load_balancer.arn

  port = 80

  protocol = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_target_group" "instances" {
  name     = "example-target-group"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default_vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "instance_1" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_1.id
  port             = 8080
}

resource "aws_lb_target_group_attachment" "instance_2" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_2.id
  port             = 8080
}

resource "aws_lb_listener_rule" "instances" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instances.arn
  }
}


resource "aws_security_group" "alb" {
  name = "alb-security-group"
}

resource "aws_security_group_rule" "allow_alb_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]

}

resource "aws_security_group_rule" "allow_alb_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]

}

resource "aws_lb" "load_balancer" {
  name               = "web-app-lb"
  load_balancer_type = "application"
  subnets            = [data.aws_subnet.default_subnet_1.id, data.aws_subnet.default_subnet_2.id]
  security_groups    = [aws_security_group.alb.id]
}

data "aws_subnet" "default_subnet_1" {
  vpc_id            = data.aws_vpc.default_vpc.id
  availability_zone = "eu-west-3a"
}

data "aws_subnet" "default_subnet_2" {
  vpc_id            = data.aws_vpc.default_vpc.id
  availability_zone = "eu-west-3b"
}



resource "aws_route53_zone" "primary" {
  name = "tick.works"
}

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "tick.works"
  type    = "A"

  alias {
    name                   = aws_lb.load_balancer.dns_name
    zone_id                = aws_lb.load_balancer.zone_id
    evaluate_target_health = true
  }
}


# This allows any minor version within the major engine_version
# defined below, but will also result in allowing AWS to auto
# upgrade the minor version of your DB. This may be too risky
# in a real production environment.
resource "aws_rds_cluster" "aurora_cluster" {
  cluster_identifier      = "aurora-postgres-cluster"
  engine                  = "aurora-postgresql"
  engine_version          = "13.7" # Adjust to the latest version or the version you need
  master_username         = "foo"
  master_password         = "foobarbaz"
  skip_final_snapshot     = true
  db_subnet_group_name    = aws_db_subnet_group.aurora_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.aurora_sg.id]
  storage_encrypted       = false # Set to true if you need encryption in production
  backup_retention_period = 1     # Short retention for development
}

# Aurora Cluster Instance
resource "aws_rds_cluster_instance" "aurora_instance" {
  identifier           = "aurora-postgres-instance-1"
  cluster_identifier   = aws_rds_cluster.aurora_cluster.id
  instance_class       = "db.t3.medium" # Use smaller instances for development
  engine               = "aurora-postgresql"
  engine_version       = aws_rds_cluster.aurora_cluster.engine_version
  publicly_accessible  = true
  db_subnet_group_name = aws_db_subnet_group.aurora_subnet_group.name
}

# Subnet Group for Aurora
resource "aws_db_subnet_group" "aurora_subnet_group" {
  name       = "aurora-subnet-group"
  subnet_ids = [data.aws_subnet.default_subnet_1.id, data.aws_subnet.default_subnet_2.id]

  tags = {
    Name = "aurora-subnet-group"
  }
}

# Security Group for Aurora
resource "aws_security_group" "aurora_sg" {
  name        = "aurora-security-group"
  description = "Allow PostgreSQL access"
  vpc_id      = data.aws_vpc.default_vpc.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Adjust for your security needs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Outputs for ease of use
output "aurora_endpoint" {
  value = aws_rds_cluster.aurora_cluster.endpoint
}

output "aurora_reader_endpoint" {
  value = aws_rds_cluster.aurora_cluster.reader_endpoint
}
