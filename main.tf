# Chokepoint demo fixture — Terraform for the demo account.
#
# This mirrors chokepoint/demo/inventory.json resource for resource:
# a public EC2 web server whose over-permissioned role (web-role,
# s3:GetObject on *) can read a backups bucket holding the production
# database credentials, an admin-role assumable by web-role, a public
# customer-data bucket, and decoys that must produce no path (a
# private worker, a bastion open only to one office IP, a public but
# empty logs bucket, an orphan role with broad permissions and no way
# in).
#
# The instance/role/bucket/db ids in the companion terraform.tfstate
# are the ones the graph uses (ec2:i-web00001, iam-role:web-role,
# s3:customer-data, rds:prod-db). Nothing here is real: the "db
# credentials" object holds a placeholder string, never a secret.
# Terraform is not required to run Chokepoint — this fixture exists
# so Phase 4 fix templates have real .tf text to edit.

terraform {
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

# --- Network ----------------------------------------------------------

resource "aws_vpc" "demo" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "demo"
  }
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id

  tags = {
    Name = "igw-demo"
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.demo.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "subnet-1"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.demo.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "subnet-2"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block = "10.0.0.0/16"
    gateway_id = "local"
  }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo.id
  }

  tags = {
    Name = "rtb-public"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block = "10.0.0.0/16"
    gateway_id = "local"
  }

  tags = {
    Name = "rtb-private"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- Security groups ---------------------------------------------------

resource "aws_security_group" "web" {
  name   = "sg-web"
  vpc_id = aws_vpc.demo.id

  ingress {
    description = "public HTTPS"
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

resource "aws_security_group" "internal" {
  name   = "sg-internal"
  vpc_id = aws_vpc.demo.id

  ingress {
    description = "VPC internal"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
}

resource "aws_security_group" "office" {
  name   = "sg-office"
  vpc_id = aws_vpc.demo.id

  ingress {
    description = "office SSH only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["203.0.113.0/32"]
  }
}

resource "aws_security_group" "db" {
  name   = "sg-db"
  vpc_id = aws_vpc.demo.id

  ingress {
    description = "Postgres from the VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
}

# --- IAM roles ----------------------------------------------------------

resource "aws_iam_role" "web_role" {
  name = "web-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "web_policy" {
  name = "web-policy"
  role = aws_iam_role.web_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OverBroadRead"
        Action   = "s3:GetObject"
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Sid      = "NarrowWrite"
        Action   = "s3:PutObject"
        Effect   = "Allow"
        Resource = "arn:aws:s3:::assets/*"
      },
    ]
  })
}

resource "aws_iam_role" "admin_role" {
  name = "admin-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::123456789012:role/web-role"
        }
      },
    ]
  })
}

resource "aws_iam_policy" "database_connect" {
  name = "DatabaseConnect"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "rds-db:connect"
        Effect   = "Allow"
        Resource = "arn:aws:rds:us-east-1:123456789012:db:prod-db"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "database_connect" {
  role       = aws_iam_role.admin_role.name
  policy_arn = aws_iam_policy.database_connect.arn
}

resource "aws_iam_role" "worker_role" {
  name = "worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "worker-policy"
  role = aws_iam_role.worker_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "s3:GetObject"
        Effect   = "Allow"
        Resource = "arn:aws:s3:::assets/*"
      },
    ]
  })
}

resource "aws_iam_role" "bastion_role" {
  name = "bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "bastion_policy" {
  name = "bastion-policy"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "s3:GetObject"
        Effect   = "Allow"
        Resource = "arn:aws:s3:::logs/*"
      },
    ]
  })
}

resource "aws_iam_role" "orphan_role" {
  name = "orphan-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "orphan_policy" {
  name = "orphan-policy"
  role = aws_iam_role.orphan_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:*",
          "rds:*",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "web_profile" {
  name = "web-profile"
  role = aws_iam_role.web_role.name
}

resource "aws_iam_instance_profile" "worker_profile" {
  name = "worker-profile"
  role = aws_iam_role.worker_role.name
}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = "bastion-profile"
  role = aws_iam_role.bastion_role.name
}

# --- Compute ------------------------------------------------------------

resource "aws_instance" "web" {
  ami                         = "ami-0c55b159cbfafe1f0"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true

  tags = {
    Name        = "web-1"
    Environment = "production"
  }
}

resource "aws_instance" "worker" {
  ami                    = "ami-0c55b159cbfafe1f0"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.internal.id]
  iam_instance_profile   = aws_iam_instance_profile.worker_profile.name

  tags = {
    Name = "worker-1"
  }
}

resource "aws_instance" "bastion" {
  ami                         = "ami-0c55b159cbfafe1f0"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.office.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion_profile.name
  associate_public_ip_address = true

  tags = {
    Name = "bastion-1"
  }
}

# --- Storage ------------------------------------------------------------

resource "aws_s3_bucket" "backups" {
  bucket = "backups"
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Placeholder object standing in for the stored credential. The content
# is a marker string, never a real credential.
resource "aws_s3_object" "db_creds" {
  bucket  = aws_s3_bucket.backups.id
  key     = "db-creds.json"
  content = "placeholder-credential-not-real"
}

resource "aws_s3_bucket" "assets" {
  bucket = "assets"
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "customer_data" {
  bucket = "customer-data"

  tags = {
    sensitivity = "customer-data"
  }
}

resource "aws_s3_bucket_policy" "customer_data" {
  bucket = aws_s3_bucket.customer_data.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicRead"
        Action    = "s3:GetObject"
        Effect    = "Allow"
        Principal = "*"
        Resource  = "arn:aws:s3:::customer-data/*"
      },
    ]
  })
}

resource "aws_s3_bucket" "logs" {
  bucket = "logs"
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicRead"
        Action    = "s3:GetObject"
        Effect    = "Allow"
        Principal = "*"
        Resource  = "arn:aws:s3:::logs/*"
      },
    ]
  })
}

# --- Database -----------------------------------------------------------

resource "aws_db_instance" "prod_db" {
  identifier             = "prod-db"
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  username               = "postgres"
  password               = "placeholder-password-not-real"
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.db.id]
  skip_final_snapshot    = true

  tags = {
    Environment = "production"
  }
}
