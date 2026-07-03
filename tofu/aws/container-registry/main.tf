# Exemplo: criar um Container Registry privado na AWS (ECR) para fazer push/pull
# de imagens Docker e depois rodar containers via Incus, LXD ou Docker na VM.

resource "aws_ecr_repository" "nixos_repo" {
  name                 = "nixos"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Name = "nixos"
  }
}

# Permissao para push/pull (sensivel - ajuste conforme necessario)
resource "aws_ecr_repository_policy" "nixos_repo_policy" {
  repository = aws_ecr_repository.nixos_repo.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPushPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
      }
    ]
  })
}

# Data source para obter o account_id
# Se ainda nao existir, adicione em main.tf:
# data "aws_caller_identity" "current" {}

# Exemplo de comandos para usar o registry:
# 1. Login:
#    aws ecr get-login-password --region <region> | \
#      docker login --username AWS --password-stdin <account_id>.dkr.ecr.<region>.amazonaws.com
#
# 2. Tag:
#    docker tag minha-imagem:latest \
#      <account_id>.dkr.ecr.<region>.amazonaws.com/nixos:minha-imagem
#
# 3. Push:
#    docker push <account_id>.dkr.ecr.<region>.amazonaws.com/nixos:minha-imagem
#
# 4. Pull/Incus:
#    incus image copy images:ubuntu/24.04 local: --alias ubuntu-24.04
#    ou, se for imagem OCI, use o Incus com remote do registry.
