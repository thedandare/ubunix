provider "aws" {
  region = "us-east-2"
}

terraform {
  required_version = ">= 0.12"
}

resource "aws_iam_role" "ASGdefaultspotBlueprintsEC2Role" {
  name = "ASGdefaultspotBlueprintsEC2Role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Principal": {
              "Service": [
                  "ec2.amazonaws.com"
              ]
          },
          "Action": [
              "sts:AssumeRole"
          ]
      }
  ]
}
  EOF
}

resource "aws_iam_instance_profile" "ASGdefaultspotBlueprintsEC2Profile" {
  name = "ASGdefaultspotBlueprintsEC2Profile"
  role = aws_iam_role.ASGdefaultspotBlueprintsEC2Role.name
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_route_table" "ASGdefault" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ASGdefault.id
  }

  tags = {
    Name = "ASGdefault"
  }
}

resource "aws_route" "default" {
  route_table_id            = aws_route_table.ASGdefault.id
  destination_cidr_block    = "0.0.0.0/0"
  depends_on                = [aws_route_table.ASGdefault]
  gateway_id                = aws_internet_gateway.ASGdefault.id
}

resource "aws_internet_gateway" "ASGdefault" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "ASGdefault"
  }
}

resource "aws_subnet" "subnet_1" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.0.0/24"
  availability_zone = "us-east-2a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "subnet_2" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-2b"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "subnet_3" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"
  availability_zone = "us-east-2c"
  map_public_ip_on_launch = true
}

resource "aws_route_table_association" "association_1" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.ASGdefault.id
}

resource "aws_route_table_association" "association_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.ASGdefault.id
}

resource "aws_route_table_association" "association_3" {
  subnet_id      = aws_subnet.subnet_3.id
  route_table_id = aws_route_table.ASGdefault.id
}

resource "aws_autoscaling_group" "ASGdefault" {
  desired_capacity   = 1
  max_size           = 1
  min_size           = 1
  capacity_rebalance = true
  health_check_type  = "ELB"
  health_check_grace_period = 300

  vpc_zone_identifier = [ aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id ]

  target_group_arns = [ aws_lb_target_group.ASGdefaulttargetgroup.arn ]

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ASGdefault.id
        version = "$Latest"
      }

       override {
      instance_type     = "c4.large"
    }

       override {
      instance_type     = "t3.medium"
    }

       override {
      instance_type     = "t2.medium"
    }

       override {
      instance_type     = "c5.large"
    }

       override {
      instance_type     = "t2.large"
    }

       override {
      instance_type     = "t3.large"
    }

       override {
      instance_type     = "m4.large"
    }

       override {
      instance_type     = "m5.large"
    }

       override {
      instance_type     = "r3.large"
    }

       override {
      instance_type     = "r5.large"
    }

       override {
      instance_type     = "r4.large"
    }
  }

    instances_distribution {
      on_demand_allocation_strategy = "prioritized"
      on_demand_base_capacity = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy = "capacity-optimized"
    }
  }

  tag {
    key                 = "Name"
    value               = "ASGdefault"
    propagate_at_launch = false
  }
}

resource "aws_launch_template" "ASGdefault" {
  name = "ASGdefault"

  image_id = data.aws_ami.amazon-linux-2.id

  vpc_security_group_ids = [ aws_security_group.ASGdefaultEC2 .id ]

  iam_instance_profile {
    arn = aws_iam_instance_profile.ASGdefaultspotBlueprintsEC2Profile.arn
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "ASGdefault"
      Value = "true"
    }
  }

  user_data = base64encode(data.template_file.file.rendered)
}

resource "aws_security_group" "ASGdefaultELB" {
  name = "ASGdefaultELB"
  description = "Security group for apache instances"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "ASGdefaultEC2" {
  name = "ASGdefaultEC2"
  description = "Security group for apache instances"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [ aws_security_group.ASGdefaultELB.id ]
  }

  vpc_id = aws_vpc.main.id
}

data "template_file" "file" {
  template = <<EOF
  #!/bin/bash
  yum update -y
  amazon-linux-extras install epel -y
  yum -y install httpd jq  
  echo "hello world! 
  My instance-id is $(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  My instance type is $(curl -s http://169.254.169.254/latest/meta-data/instance-type)
  I'm on Availability Zone $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)" > /var/www/html/index.html
  service httpd start
  EOF
}

data "aws_ami" "amazon-linux-2" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"]
  }
}

resource "aws_lb" "ASGdefaultloadbalancer" {
  name               = "ASGdefaultloadbalancer"
  security_groups    = [ aws_security_group.ASGdefaultELB.id ]
  subnets            = [ aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id ]
  internal = false
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "ASGdefaulttargetgroup" {
  name     = "ASGdefaulttargetgroup"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  deregistration_delay = 90
  load_balancing_algorithm_type = "least_outstanding_requests"
}

resource "aws_lb_listener" "ASGdefaultALBListener" {
  load_balancer_arn = aws_lb.ASGdefaultloadbalancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ASGdefaulttargetgroup.arn
  }
}