provider "aws" {
  region = "us-east-1"
}

provider "kubernetes" {
  host = "https://127.0.0.1:6443" # Kubernetes API server running locally on the EC2 instance
}

provider "helm" {
  kubernetes {
    host = "https://127.0.0.1:6443" # Kubernetes API server for the in-cluster configuration
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Subnets
resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = false
}

# Security Group
resource "aws_security_group" "k8s" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Role for EC2
resource "aws_iam_role" "paperless_role" {
  name = "paperless-secrets-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "ec2.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# Attach IAM Instance Profile
resource "aws_iam_instance_profile" "paperless_instance_profile" {
  name = "paperless-instance-profile"
  role = aws_iam_role.paperless_role.name
}

# EC2 Instance
resource "aws_instance" "k8s" {
  ami                    = "ami-012967cc5a8c9f891"
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.private.id
  security_groups        = [aws_security_group.k8s.name]
  iam_instance_profile   = aws_iam_instance_profile.paperless_instance_profile.name

  user_data = <<-EOF
              #!/bin/bash
              # Install k3s
              curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --tls-san 127.0.0.1" sh -

              # Expose Kubernetes configuration
              mkdir -p /home/ec2-user/.kube
              cp /etc/rancher/k3s/k3s.yaml /home/ec2-user/.kube/config
              chown ec2-user:ec2-user /home/ec2-user/.kube/config

              # Configure Terraform to access the local Kubernetes cluster
              export KUBECONFIG=/home/ec2-user/.kube/config
              EOF

  tags = {
    Name = "k8s-master"
  }
}

# Secrets Manager Data Sources
data "aws_secretsmanager_secret_version" "ssh_key" {
  secret_id = "paperless/ssh-private-key"
}

data "aws_secretsmanager_secret_version" "postgres_credentials" {
  secret_id = "paperless/postgresql"
}

# Parse PostgreSQL Secrets
locals {
  postgres_secret = jsondecode(data.aws_secretsmanager_secret_version.postgres_credentials.secret_string)
}

# PostgreSQL (RDS)
resource "aws_db_instance" "postgresql" {
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "13.7"
  instance_class         = "db.t3.micro"
  username               = local.postgres_secret.username
  password               = local.postgres_secret.password
  publicly_accessible    = false
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.k8s.id]
  db_subnet_group_name   = aws_db_subnet_group.postgres_subnet.name

  tags = {
    Name = "Paperless-PostgreSQL"
  }
}

resource "aws_db_subnet_group" "postgres_subnet" {
  name        = "postgres-subnet-group"
  description = "Subnet group for RDS PostgreSQL"
  subnet_ids  = [aws_subnet.private.id]
}

# Redis (Elasticache)
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "paperless-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis6.x"
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet.name
  security_group_ids   = [aws_security_group.k8s.id]

  tags = {
    Name = "Paperless-Redis"
  }
}

resource "aws_elasticache_subnet_group" "redis_subnet" {
  name        = "redis-subnet-group"
  description = "Subnet group for Elasticache Redis"
  subnet_ids  = [aws_subnet.private.id]
}

# Helm Release for Paperless-ngx
resource "helm_release" "paperless" {
  name       = "paperless"
  namespace  = "default"
  chart      = "./paperless-helm"
  values = [
    file("values.yaml")
  ]

  set {
    name  = "postgresql.postgresUser"
    value = local.postgres_secret.username
  }

  set {
    name  = "postgresql.postgresPassword"
    value = local.postgres_secret.password
  }

  set {
    name  = "postgresql.postgresDatabase"
    value = "paperless"
  }

  set {
    name  = "redis.host"
    value = "${aws_elasticache_cluster.redis.primary_endpoint_address}"
  }

  set {
    name  = "redis.port"
    value = "6379"
  }
}
