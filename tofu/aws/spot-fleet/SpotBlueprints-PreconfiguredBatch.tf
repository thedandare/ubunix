provider "aws" {
  region = "us-east-2"
}

terraform {
  required_version = ">= 0.12"
}

resource "aws_iam_role" "batchdefaultspotBlueprintsBatchServiceRole" {
  name = "batchdefaultspotBlueprintsBatchServiceRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Principal": {
              "Service": [
                  "batch.amazonaws.com"
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

resource "aws_iam_role_policy_attachment" "example-AWSBatchServiceRole" {
  role       = aws_iam_role.batchdefaultspotBlueprintsBatchServiceRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_iam_role" "batchdefaultspotBlueprintsECSInstanceRole" {
  name = "batchdefaultspotBlueprintsECSInstanceRole"

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

resource "aws_iam_role_policy_attachment" "example-AmazonEC2ContainerServiceforEC2Role" {
  role       = aws_iam_role.batchdefaultspotBlueprintsECSInstanceRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "batchdefaultspotBlueprintsECSInstanceProfile" {
  name = "batchdefaultspotBlueprintsECSInstanceProfile"
  role = aws_iam_role.batchdefaultspotBlueprintsECSInstanceRole.name
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_route_table" "batchdefault" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.batchdefault.id
  }

  tags = {
    Name = "batchdefault"
  }
}

resource "aws_route" "default" {
  route_table_id            = aws_route_table.batchdefault.id
  destination_cidr_block    = "0.0.0.0/0"
  depends_on                = [aws_route_table.batchdefault]
  gateway_id                = aws_internet_gateway.batchdefault.id
}

resource "aws_internet_gateway" "batchdefault" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "batchdefault"
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
  route_table_id = aws_route_table.batchdefault.id
}

resource "aws_route_table_association" "association_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.batchdefault.id
}

resource "aws_route_table_association" "association_3" {
  subnet_id      = aws_subnet.subnet_3.id
  route_table_id = aws_route_table.batchdefault.id
}

resource "aws_batch_compute_environment" "batchdefault" {
  compute_environment_name = "batchdefault"

  compute_resources {
    allocation_strategy = "SPOT_CAPACITY_OPTIMIZED"

    instance_role = aws_iam_instance_profile.batchdefaultspotBlueprintsECSInstanceProfile.arn

    max_vcpus = 256
    min_vcpus = 0
    desired_vcpus = 0

    security_group_ids = [aws_security_group.batchdefault.id]

    subnets = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id]

    instance_type = ["c4.large", "c5.large", "c5.xlarge", "c4.xlarge", "c4.2xlarge", "c5.2xlarge", "c4.4xlarge", "c5.4xlarge", "c4.8xlarge", "c5.9xlarge", "c5.12xlarge", "c5.18xlarge", "c5.24xlarge"]

    type = "SPOT"
  }

  service_role = aws_iam_role.batchdefaultspotBlueprintsBatchServiceRole.arn
  type         = "MANAGED"
}

resource "aws_security_group" "batchdefault" {
  name        = "batchdefault"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "batchdefault"
  }
}

resource "aws_batch_job_queue" "batchdefaultspot_batch_job_queue" {
  name     = "batchdefaultspot_batch_job_queue"
  state    = "ENABLED"
  priority = 10
  compute_environments = [
    aws_batch_compute_environment.batchdefault.arn,
  ]
}

resource "aws_batch_job_definition" "batchdefaulthello_world" {
  name = "batchdefaulthello_world"
  type = "container"

  container_properties = <<CONTAINER_PROPERTIES
{
  "Image": "amazonlinux",
  "Vcpus": 1,
  "Memory": 512,
  "Command": [
      "sh",
      "-c",
      "echo \"Hello world from job $AWS_BATCH_JOB_ID . This is run attempt $AWS_BATCH_JOB_ATTEMPT\""
  ]
}
  CONTAINER_PROPERTIES

  retry_strategy {
    attempts = 3
  }

  timeout {
    attempt_duration_seconds = 60
  }
}