provider "aws" {
  region = "us-east-2"
}

terraform {
  required_version = ">= 0.12"
}

resource "aws_iam_role" "defaultECSExecutionRole" {
        name = "defaultECSExecutionRole"
      
        assume_role_policy = <<EOF
{
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ecs-tasks.amazonaws.com"
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

resource "aws_iam_role_policy_attachment" "defaultECSExecutionRolePolicy" {
  role       = aws_iam_role.defaultECSExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}



resource "aws_iam_role" "defaultECSTaskRole" {
  name = "defaultECSTaskRole"

  assume_role_policy = <<EOF
{
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ecs-tasks.amazonaws.com"
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

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_route_table" "defaultECS" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.defaultECS.id
  }

  tags = {
    Name = "defaultECS"
  }
}

resource "aws_route" "default" {
  route_table_id            = aws_route_table.defaultECS.id
  destination_cidr_block    = "0.0.0.0/0"
  depends_on                = [aws_route_table.defaultECS]
  gateway_id                = aws_internet_gateway.defaultECS.id
}

resource "aws_internet_gateway" "defaultECS" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "defaultECS"
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
  route_table_id = aws_route_table.defaultECS.id
}
      

resource "aws_route_table_association" "association_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.defaultECS.id
}
      

resource "aws_route_table_association" "association_3" {
  subnet_id      = aws_subnet.subnet_3.id
  route_table_id = aws_route_table.defaultECS.id
}

resource "aws_security_group" "defaultECSContainer" {
  name = "defaultECSContainer"
  description = "Security group for the container"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [ aws_security_group.defaultECSELB.id ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "defaultECSELB" {
  name = "defaultECSELB"
  description = "Security group for the load balancer"

  ingress {
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
  vpc_id = aws_vpc.main.id
}

resource "aws_ecs_cluster" "ecsfargateclusterdefault" {
  name = "ecsfargateclusterdefault"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}


resource "aws_ecs_cluster_capacity_providers" "defaultECSClusterProvider" {
  cluster_name = aws_ecs_cluster.ecsfargateclusterdefault.name
  capacity_providers = ["FARGATE_SPOT"]
  default_capacity_provider_strategy {
    weight            = "1"
    capacity_provider = "FARGATE_SPOT"
  }
}

resource "aws_ecs_service" "defaultECSService" {
  name            = "defaultECSService"
  cluster         = aws_ecs_cluster.ecsfargateclusterdefault.id
  task_definition = aws_ecs_task_definition.defaultECSTaskDefinition.arn
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent = 200
  health_check_grace_period_seconds = 30
  launch_type = "FARGATE"
  desired_count   = 2
  depends_on      = [aws_lb_target_group.defaultECSTargetGroup, aws_lb.defaultECSLoadBalancer, aws_lb_listener.defaultECSALBListener]

  network_configuration {
    assign_public_ip   = true
    security_groups = [aws_security_group.defaultECSContainer.id]
    subnets            = [ aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id ]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.defaultECSTargetGroup.arn
    container_name   = "first"
    container_port   = 80
  }

}

resource "aws_lb_target_group" "defaultECSTargetGroup" {
  name     = "defaultECSTargetGroup"

  health_check {
    interval            = 10
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  port     = 80
  protocol = "HTTP"
  deregistration_delay = 60
  target_type = "ip"
  vpc_id = aws_vpc.main.id
}

resource "aws_lb" "defaultECSLoadBalancer" {
  name               = "defaultECSLoadBalancer"
  idle_timeout = 60
  security_groups    = [ aws_security_group.defaultECSELB.id ]
  subnets            = [ aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id ]
  internal = false
}

resource "aws_lb_listener" "defaultECSALBListener" {
  load_balancer_arn = aws_lb.defaultECSLoadBalancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.defaultECSTargetGroup.arn
  }
}

resource "aws_ecs_task_definition" "defaultECSTaskDefinition" {
  family = "defaultECSTaskDefinition"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = 256
  memory = 512
  execution_role_arn = aws_iam_role.defaultECSExecutionRole.arn
  task_role_arn = aws_iam_role.defaultECSTaskRole.arn
  container_definitions = jsonencode([
    {
      name      = "first"
      image     = "public.ecr.aws/ecs-sample-image/amazon-ecs-sample"
      portMappings = [
        {
          containerPort = 80
        }
      ]
    }
  ])
}