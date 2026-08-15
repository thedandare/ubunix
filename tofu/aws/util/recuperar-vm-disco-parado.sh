#!/bin/bash

set -euo pipefail

# Script para recuperar uma VM que foi parada por preempção de spot instance
# Reutiliza o disco EBS existente e cria uma nova instância
# Uso: ./recuperar-vm-disco-parado.sh <instance-id-parada> [instance-type] [region]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funções auxiliares
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Validar argumentos
if [ $# -lt 1 ]; then
    log_error "Uso: $0 <instance-id-parada> [instance-type] [region]"
    echo ""
    echo "Exemplos:"
    echo "  $0 i-0c5aee3d686a2fb6d"
    echo "  $0 i-0c5aee3d686a2fb6d t3.small us-east-2"
    exit 1
fi

STOPPED_INSTANCE_ID="$1"
INSTANCE_TYPE="${2:-t3.small}"
AWS_REGION="${3:-us-east-2}"

log_info "Recuperando VM parada: $STOPPED_INSTANCE_ID"
log_info "Tipo de instância: $INSTANCE_TYPE"
log_info "Região: $AWS_REGION"
echo ""

# Verificar se a instância existe e está parada
log_info "Verificando status da instância..."
INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$STOPPED_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "not-found")

if [ "$INSTANCE_STATE" = "not-found" ]; then
    log_error "Instância $STOPPED_INSTANCE_ID não encontrada na região $AWS_REGION"
    exit 1
fi

if [ "$INSTANCE_STATE" != "stopped" ]; then
    log_warn "Instância está em estado: $INSTANCE_STATE (esperado: stopped)"
    read -p "Deseja continuar? (s/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        log_error "Operação cancelada"
        exit 1
    fi
fi

log_success "Instância está parada"
echo ""

# Obter informações da instância parada
log_info "Coletando informações da instância..."
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$STOPPED_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0]' \
    --output json)

SUBNET_ID=$(echo "$INSTANCE_INFO" | jq -r '.SubnetId')
SECURITY_GROUP_IDS=$(echo "$INSTANCE_INFO" | jq -r '.SecurityGroups[].GroupId' | tr '\n' ',')
SECURITY_GROUP_IDS="${SECURITY_GROUP_IDS%,}"
KEY_NAME=$(echo "$INSTANCE_INFO" | jq -r '.KeyName')
AMI_ID=$(echo "$INSTANCE_INFO" | jq -r '.ImageId')
AVAILABILITY_ZONE=$(echo "$INSTANCE_INFO" | jq -r '.Placement.AvailabilityZone')

# Obter volumes EBS
log_info "Coletando volumes EBS..."
VOLUMES=$(echo "$INSTANCE_INFO" | jq -r '.BlockDeviceMappings[].Ebs.VolumeId')

if [ -z "$VOLUMES" ]; then
    log_error "Nenhum volume EBS encontrado"
    exit 1
fi

log_success "Volumes encontrados:"
echo "$VOLUMES" | while read -r vol; do
    VOL_SIZE=$(aws ec2 describe-volumes \
        --volume-ids "$vol" \
        --region "$AWS_REGION" \
        --query 'Volumes[0].Size' \
        --output text)
    echo "  - $vol (${VOL_SIZE}GB)"
done
echo ""

# Desanexar volumes da instância parada
log_info "Desanexando volumes da instância parada..."
for VOLUME_ID in $VOLUMES; do
    DEVICE=$(echo "$INSTANCE_INFO" | jq -r ".BlockDeviceMappings[] | select(.Ebs.VolumeId==\"$VOLUME_ID\") | .DeviceName")
    
    log_info "Desanexando $VOLUME_ID de $DEVICE..."
    aws ec2 detach-volume \
        --volume-id "$VOLUME_ID" \
        --instance-id "$STOPPED_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --output text > /dev/null
    
    # Aguardar desanexamento
    log_info "Aguardando desanexamento..."
    aws ec2 wait volume-available \
        --volume-ids "$VOLUME_ID" \
        --region "$AWS_REGION"
    
    log_success "Volume $VOLUME_ID desanexado"
done
echo ""

# Criar nova instância
log_info "Criando nova instância..."
log_info "  - AMI: $AMI_ID"
log_info "  - Tipo: $INSTANCE_TYPE"
log_info "  - Subnet: $SUBNET_ID"
log_info "  - Security Groups: $SECURITY_GROUP_IDS"
log_info "  - Key: $KEY_NAME"
log_info "  - AZ: $AVAILABILITY_ZONE"
echo ""

NEW_INSTANCE=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids $SECURITY_GROUP_IDS \
    --subnet-id "$SUBNET_ID" \
    --placement "AvailabilityZone=$AVAILABILITY_ZONE" \
    --no-associate-public-ip-address \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

log_success "Nova instância criada: $NEW_INSTANCE"
echo ""

# Aguardar que a nova instância esteja pronta para receber volumes
log_info "Aguardando nova instância ficar pronta..."
aws ec2 wait instance-running \
    --instance-ids "$NEW_INSTANCE" \
    --region "$AWS_REGION"

log_success "Nova instância está rodando"
echo ""

# Anexar volumes à nova instância
log_info "Anexando volumes à nova instância..."
DEVICE_INDEX=0
for VOLUME_ID in $VOLUMES; do
    # Determinar device name baseado no índice
    if [ $DEVICE_INDEX -eq 0 ]; then
        DEVICE="/dev/sda1"  # Root device
    else
        DEVICE="/dev/sdf"   # Dados adicionais
    fi
    
    log_info "Anexando $VOLUME_ID como $DEVICE..."
    aws ec2 attach-volume \
        --volume-id "$VOLUME_ID" \
        --instance-id "$NEW_INSTANCE" \
        --device "$DEVICE" \
        --region "$AWS_REGION" \
        --output text > /dev/null
    
    # Aguardar anexamento
    log_info "Aguardando anexamento..."
    aws ec2 wait volume-in-use \
        --volume-ids "$VOLUME_ID" \
        --region "$AWS_REGION"
    
    log_success "Volume $VOLUME_ID anexado"
    DEVICE_INDEX=$((DEVICE_INDEX + 1))
done
echo ""

# Obter IP público
log_info "Obtendo informações da nova instância..."
NEW_INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$NEW_INSTANCE" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0]' \
    --output json)

PUBLIC_IP=$(echo "$NEW_INSTANCE_INFO" | jq -r '.PublicIpAddress // "N/A"')
PRIVATE_IP=$(echo "$NEW_INSTANCE_INFO" | jq -r '.PrivateIpAddress')

echo ""
log_success "VM recuperada com sucesso!"
echo ""
echo "Informações da nova instância:"
echo "  ID: $NEW_INSTANCE"
echo "  IP Privado: $PRIVATE_IP"
echo "  IP Público: $PUBLIC_IP"
echo "  Tipo: $INSTANCE_TYPE"
echo "  Região: $AWS_REGION"
echo ""

# Sugestões
echo "Próximos passos:"
echo "  1. Aguarde alguns minutos para o sistema operacional inicializar"
echo "  2. Conecte via SSH:"
if [ "$PUBLIC_IP" != "N/A" ]; then
    echo "     ssh -p 2409 root@$PUBLIC_IP"
else
    echo "     ssh -p 2409 root@$PRIVATE_IP"
fi
echo "  3. Verifique se os discos foram montados corretamente:"
echo "     lsblk"
echo "     mount | grep /dev"
echo ""

# Opcional: Marcar instância parada para exclusão
echo "Instância parada original: $STOPPED_INSTANCE_ID"
echo "Você pode deletá-la depois se não precisar mais:"
echo "  aws ec2 terminate-instances --instance-ids $STOPPED_INSTANCE_ID --region $AWS_REGION"
echo ""

log_success "Script finalizado!"
