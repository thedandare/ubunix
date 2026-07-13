#!/bin/sh

# Configurações de variáveis
IMAGE_NAME="meu-app"
IMAGE_TAG="local"
TAR_FILE="meu-app.tar"
DEPLOYMENT_FILE="deployment.yaml"

# Cores para organizar a saída do terminal
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

echo -e "${BLUE}[1/5] Gerando imagem no Docker local...${NC}"
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .

echo -e "${BLUE}[2/5] Exportando imagem para arquivo TAR...${NC}"
# Remove o TAR antigo se existir para não dar erro
rm -f ${TAR_FILE}
docker save ${IMAGE_NAME}:${IMAGE_TAG} > ${TAR_FILE}

echo -e "${BLUE}[3/5] Removendo versão antiga do MicroK8s (se houver)...${NC}"
# Remove a imagem antiga do containerd para garantir o update
sudo incus exec leonk8s microk8s ctr image rm docker.io/library/${IMAGE_NAME}:${IMAGE_TAG} 2>/dev/null

echo -e "${BLUE}[4/5] Importando nova imagem para o MicroK8s...${NC}"
sudo incus exec leonk8s microk8s ctr image import ${TAR_FILE}

echo -e "${BLUE}[5/5] Aplicando manifesto no Kubernetes...${NC}"
incus exec leonk8s microk8s kubectl apply -f ${DEPLOYMENT_FILE}

# Força o reinício dos Pods caso a imagem tenha o mesmo nome/tag
echo -e "${BLUE}Forçando atualização dos Pods...${NC}"
incus exec leonk8s microk8s kubectl rollout restart deployment/meu-app-deployment

echo -e "${GREEN}✓ Processo concluído com sucesso!${NC}"
