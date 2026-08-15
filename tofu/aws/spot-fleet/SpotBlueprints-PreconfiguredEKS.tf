provider "aws" {
  region = "us-east-2"
}

terraform {
  required_version = ">= 0.12"
}

resource "aws_iam_role" "eksdefaultspotBlueprintsEksClusterRole" {
  name = "eksdefaultspotBlueprintsEksClusterRole"

  assume_role_policy = <<EOF
{
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
            "eks.amazonaws.com"
        ]
      },
      "Action": [
        "sts:AssumeRole"
      ]
    }
  ],
  "Version": "2008-10-17"
}
  EOF
}

resource "aws_iam_role_policy_attachment" "example-AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eksdefaultspotBlueprintsEksClusterRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "example-AmazonEKSServicePolicy" {
  role       = aws_iam_role.eksdefaultspotBlueprintsEksClusterRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}

resource "aws_iam_role" "eksdefaultspotBlueprintsNodeInstanceRole" {
  name = "eksdefaultspotBlueprintsNodeInstanceRole"

  assume_role_policy = <<EOF
{
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
  ],
  "Version": "2008-10-17"
}
  EOF

}

resource "aws_iam_role_policy_attachment" "example-AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.eksdefaultspotBlueprintsNodeInstanceRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "example-AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.eksdefaultspotBlueprintsNodeInstanceRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "example-AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.eksdefaultspotBlueprintsNodeInstanceRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

resource "aws_route_table" "eksdefault" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eksdefault.id
  }

  tags = {
    Name = "eksdefault"
  }
}

resource "aws_route" "default" {
  route_table_id            = aws_route_table.eksdefault.id
  destination_cidr_block    = "0.0.0.0/0"
  depends_on                = [aws_route_table.eksdefault]
  gateway_id                = aws_internet_gateway.eksdefault.id
}

resource "aws_internet_gateway" "eksdefault" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "eksdefault"
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
  route_table_id = aws_route_table.eksdefault.id
}

resource "aws_route_table_association" "association_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.eksdefault.id
}

resource "aws_route_table_association" "association_3" {
  subnet_id      = aws_subnet.subnet_3.id
  route_table_id = aws_route_table.eksdefault.id
}

resource "aws_security_group" "eksdefaultControlPlane" {
  name        = "eksdefaultControlPlane"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
  }
}

resource "aws_eks_cluster" "spotblueprintscluster" {
  name     = "spotblueprintscluster"
  role_arn = aws_iam_role.eksdefaultspotBlueprintsEksClusterRole.arn

  vpc_config {
    subnet_ids = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id]
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.example-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.example-AmazonEKSServicePolicy,
    aws_iam_role_policy_attachment.example-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.example-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.example-AmazonEC2ContainerRegistryReadOnly
  ]
}

output "endpoint" {
  value = aws_eks_cluster.spotblueprintscluster.endpoint
}

output "kubeconfig-certificate-authority-data" {
  value = aws_eks_cluster.spotblueprintscluster.certificate_authority[0].data
}

resource "aws_eks_node_group" "node_group_1" {
  cluster_name    = aws_eks_cluster.spotblueprintscluster.name
  node_group_name = "eksdefaultNodeGroup1"
  node_role_arn   = aws_iam_role.eksdefaultspotBlueprintsNodeInstanceRole.arn
  subnet_ids      = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id]
  capacity_type   = "SPOT"
  instance_types  = ["c4.large", "c5.large"]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.example-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.example-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.example-AmazonEC2ContainerRegistryReadOnly,
  ]
}

resource "aws_eks_node_group" "node_group_2" {
  cluster_name    = aws_eks_cluster.spotblueprintscluster.name
  node_group_name = "eksdefaultNodeGroup2"
  node_role_arn   = aws_iam_role.eksdefaultspotBlueprintsNodeInstanceRole.arn
  subnet_ids      = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id]
  capacity_type   = "SPOT"
  instance_types  = ["m4.large", "m5.large"]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.example-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.example-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.example-AmazonEC2ContainerRegistryReadOnly,
  ]
}

resource "aws_eks_node_group" "node_group_3" {
  cluster_name    = aws_eks_cluster.spotblueprintscluster.name
  node_group_name = "eksdefaultNodeGroup3"
  node_role_arn   = aws_iam_role.eksdefaultspotBlueprintsNodeInstanceRole.arn
  subnet_ids      = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id, aws_subnet.subnet_3.id]
  capacity_type   = "SPOT"
  instance_types  = ["r3.large", "r5.large", "r4.large"]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.example-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.example-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.example-AmazonEC2ContainerRegistryReadOnly,
  ]
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