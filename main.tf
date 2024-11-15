provider "aws" {
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = aws_instance.k8s.public_dns
  client_certificate     = file("./k3s_client.crt")
  client_key             = file("./k3s_client.key")
  cluster_ca_certificate = file("./k3s_ca.crt")
}

provider "helm" {
  kubernetes {
    host                   = aws_instance.k8s.public_dns
    client_certificate     = file("./k3s_client.crt")
    client_key             = file("./k3s_client.key")
    cluster_ca_certificate = file("./k3s_ca.crt")
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

resource "aws_iam_policy" "ssm_secrets_policy" {
  name        = "ssm-secrets-access-policy"
  description = "Allow EC2 to use SSM and access Secrets Manager"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "secretsmanager:GetSecretValue",
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_ssm_secrets_policy" {
  role       = aws_iam_role.paperless_role.name
  policy_arn = aws_iam_policy.ssm_secrets_policy.arn
}

# Attach IAM Role to EC2
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
              yum install -y amazon-ssm-agent
              systemctl enable amazon-ssm-agent
              systemctl start amazon-ssm-agent

              curl -sfL https://get.k3s.io | sh -
              mkdir -p /home/ec2-user/.kube
              cp /etc/rancher/k3s/k3s.yaml /home/ec2-user/.kube/config
              chown ec2-user:ec2-user /home/ec2-user/.kube/config

              aws secretsmanager get-secret-value --secret-id paperless/ssh-private-key --query SecretString --output text > /tmp/id_rsa
              chmod 600 /tmp/id_rsa
              EOF

  tags = {
    Name = "k8s-master"
  }
}

# PostgreSQL (RDS)
resource "aws_db_instance" "postgresql" {
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "13.7"
  instance_class         = "db.t3.micro"
  username               = "paperless"
  password               = "paperlesspassword"
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

# Route 53 Hosted Zone
data "aws_route53_zone" "mlkr_link" {
  name         = "mlkr.link."
  private_zone = false
}

# Route 53 Record
resource "aws_route53_record" "docs_mlkr" {
  zone_id = data.aws_route53_zone.mlkr_link.zone_id
  name    = "docs.mlkr.link"
  type    = "A"
  alias {
    name                   = aws_instance.k8s.public_dns
    zone_id                = aws_instance.k8s.hosted_zone_id
    evaluate_target_health = false
  }
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
    name  = "postgresql.host"
    value = "${aws_db_instance.postgresql.address}"
  }

  set {
    name  = "postgresql.postgresUser"
    value = "paperless"
  }

  set {
    name  = "postgresql.postgresPassword"
    value = "paperlesspassword"
  }

  set {
    name  = "postgresql.postgresDatabase"
    value = "paperless"
  }

  set {
    name  = "redis.host"
    value = "${aws_elasticache_cluster.redis.configuration_endpoint_address}"
  }

  set {
    name  = "redis.port"
    value = "6379"
  }
}