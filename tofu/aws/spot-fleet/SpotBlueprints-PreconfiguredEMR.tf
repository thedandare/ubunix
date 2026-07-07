provider "aws" {
  region = "us-east-2"
}

terraform {
  required_version = ">= 0.12"
}

resource "aws_iam_role" "emrdefaultspotBlueprintsEmrRole" {
  name = "emrdefaultspotBlueprintsEmrRole"

  assume_role_policy = <<EOF
{
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "elasticmapreduce.amazonaws.com"
      }
    }
  ],
  "Version": "2008-10-17"
}
  EOF
}

resource "aws_iam_role_policy_attachment" "example-AmazonElasticMapReduceRole" {
  role       = aws_iam_role.emrdefaultspotBlueprintsEmrRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceRole"
}


resource "aws_iam_role" "emrdefaultspotBlueprintsEmrEc2Role" {
  name = "emrdefaultspotBlueprintsEmrEc2Role"

  assume_role_policy = <<EOF
{
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      }
    }
  ],
  "Version": "2008-10-17"
}
  EOF
}

resource "aws_iam_role_policy_attachment" "example-AmazonElasticMapReduceforEC2Role" {
  role       = aws_iam_role.emrdefaultspotBlueprintsEmrEc2Role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
}

resource "aws_iam_instance_profile" "emrdefaultspotBlueprintsEmrEc2InstanceProfile" {
  name = "emrdefaultspotBlueprintsEmrEc2InstanceProfile"
  role = aws_iam_role.emrdefaultspotBlueprintsEmrEc2Role.name
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_route_table" "emrdefault" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.emrdefault.id
  }

  tags = {
    Name = "emrdefault"
  }
}

resource "aws_route" "default" {
  route_table_id            = aws_route_table.emrdefault.id
  destination_cidr_block    = "0.0.0.0/0"
  depends_on                = [aws_route_table.emrdefault]
  gateway_id                = aws_internet_gateway.emrdefault.id
}

resource "aws_internet_gateway" "emrdefault" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "emrdefault"
  }
}

resource "aws_subnet" "subnet_1" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.0.0/24"
  availability_zone = "us-east-2a"
}

resource "aws_subnet" "subnet_2" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-2b"
}

resource "aws_subnet" "subnet_3" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"
  availability_zone = "us-east-2c"
}

resource "aws_route_table_association" "association_1" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.emrdefault.id
}

resource "aws_route_table_association" "association_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.emrdefault.id
}

resource "aws_route_table_association" "association_3" {
  subnet_id      = aws_subnet.subnet_3.id
  route_table_id = aws_route_table.emrdefault.id
}

resource "aws_emr_cluster" "emrdefault" {
  name          = "emrdefault"
  applications  = ["Spark", "Hadoop", "Ganglia"]

  core_instance_fleet {
    
    target_on_demand_capacity = 2

    launch_specifications {
      on_demand_specification {
        allocation_strategy      = "lowest-price"
      }
    }
  }

  ec2_attributes {
    subnet_id = aws_subnet.subnet_1.id
    instance_profile = aws_iam_instance_profile.emrdefaultspotBlueprintsEmrEc2InstanceProfile.arn
  }

  master_instance_fleet {
    
    target_on_demand_capacity = 1
  }

  service_role = aws_iam_role.emrdefaultspotBlueprintsEmrRole.arn

  release_label = "emr-5.30.1"

  visible_to_all_users = true
}

resource "aws_emr_instance_fleet" "emrdefault" {
  cluster_id = aws_emr_cluster.emrdefault.id

  

  launch_specifications {
    spot_specification {
      timeout_action           = "TERMINATE_CLUSTER"
      timeout_duration_minutes = 60
      allocation_strategy      = "capacity-optimized"
    }
  }

  target_spot_capacity = 2
}