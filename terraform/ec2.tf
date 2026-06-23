# ── Bastion EC2 Jump server --
# Lives in the public subnet. Only entry point to private RDS.
# SSH here first → then psql to RDS private endpoint.
# Traffic flow: Your laptop → Bastion (public subnet) → Private EC2
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  key_name                    = aws_key_pair.deployer.key_name
  associate_public_ip_address = true

  # install postgres clinet  so we can psql from bastion to RDS
  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y postgresql-client
  EOF

  tags = { Name = "${var.environment}-bastion" }
}

# EC2 INSTANCE in private VPC with no intenet access
resource "aws_instance" "backend_app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnets[0] # placed in the provate subnet of the VPC
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    apt-get update -y
    apt-get install -y postgresql-client curl unzip

    # AWS CLI v2 — used by deploy script for ECR login
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip

    apt-get install -y \
      ca-certificates \
      curl \
      gnupg \
      lsb-release

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    mkdir -p /opt/app
  EOF

  depends_on = [aws_db_instance.app_db]

  tags = {
    Name       = "${var.environment}-backend-app"
    RoleAccess = "backend-app"
  }
}
