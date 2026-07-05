#!/usr/bin/env bash
# Cria uma nova workspace do OpenTofu para a regiao us-east-2, sem alterar a
# infra atual (workspace "default", regiao sa-east-1, state ja aplicado).
#
# O que este script faz:
#   1. Cria (se nao existir) e faz checkout de uma branch git dedicada.
#   2. Cria/seleciona uma workspace do tofu chamada "us-east-2".
#   3. Gera um arquivo terraform.us-east-2.tfvars com aws_region = "us-east-2".
#
# Uso:
#   ./scripts/new-workspace-us-east-2.sh
#
# Depois de rodar, para planejar/aplicar na nova regiao:
#   cd tofu/aws
#   tofu workspace select us-east-2
#   tofu plan  -var-file=terraform.us-east-2.tfvars
#   tofu apply -var-file=terraform.us-east-2.tfvars
#
# Para voltar a infra atual (default/sa-east-1):
#   tofu workspace select default


BRANCH_NAME="${1:-aws-us-east-2}"
WORKSPACE_NAME="us-east-2"
NEW_REGION="us-east-2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GIT_ROOT="$(git -C "${AWS_DIR}" rev-parse --show-toplevel)"

echo "==> Repositorio git: ${GIT_ROOT}"
echo "==> Diretorio tofu/aws: ${AWS_DIR}"

# 1. Branch git dedicada para a nova workspace.
if git -C "${GIT_ROOT}" show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
  echo "==> Branch '${BRANCH_NAME}' ja existe. Fazendo checkout..."
  git -C "${GIT_ROOT}" checkout "${BRANCH_NAME}"
else
  echo "==> Criando e mudando para a branch '${BRANCH_NAME}'..."
  git -C "${GIT_ROOT}" checkout -b "${BRANCH_NAME}"
fi

# 2. Workspace do tofu (isolada da 'default', sem mexer no state atual).
cd "${AWS_DIR}"

if [ ! -d ".terraform" ]; then
  echo "==> Rodando 'tofu init' (necessario antes de criar workspaces)..."
  tofu init
fi

if tofu workspace list | grep -qE "(^|\s)${WORKSPACE_NAME}\$"; then
  echo "==> Workspace '${WORKSPACE_NAME}' ja existe. Selecionando..."
  tofu workspace select "${WORKSPACE_NAME}"
else
  echo "==> Criando workspace '${WORKSPACE_NAME}'..."
  tofu workspace new "${WORKSPACE_NAME}"
fi

# 3. tfvars especifico da nova regiao (nao mexe no terraform.tfvars atual).
TFVARS_FILE="${AWS_DIR}/terraform.${WORKSPACE_NAME}.tfvars"

if [ -f "${TFVARS_FILE}" ]; then
  echo "==> ${TFVARS_FILE} ja existe. Ajustando aws_region..."
  if grep -q '^aws_region' "${TFVARS_FILE}"; then
    sed -i "s/^aws_region.*/aws_region = \"${NEW_REGION}\"/" "${TFVARS_FILE}"
  else
    echo "aws_region = \"${NEW_REGION}\"" >> "${TFVARS_FILE}"
  fi
else
  echo "==> Criando ${TFVARS_FILE}..."
  if [ -f "${AWS_DIR}/terraform.tfvars.example" ]; then
    cp "${AWS_DIR}/terraform.tfvars.example" "${TFVARS_FILE}"
    sed -i "s/^aws_region.*/aws_region = \"${NEW_REGION}\"/" "${TFVARS_FILE}"
  else
    echo "aws_region = \"${NEW_REGION}\"" > "${TFVARS_FILE}"
  fi
fi

echo
echo "==> Pronto."
echo "    Branch git ativa : $(git -C "${GIT_ROOT}" branch --show-current)"
echo "    Workspace tofu   : $(tofu workspace show)"
echo "    Var file         : ${TFVARS_FILE} (aws_region = ${NEW_REGION})"
echo
echo "    A workspace 'default' (infra atual, sa-east-1) permanece intocada."
echo "    Para planejar/aplicar a nova infra:"
echo "      cd ${AWS_DIR}"
echo "      tofu plan  -var-file=terraform.${WORKSPACE_NAME}.tfvars"
echo "      tofu apply -var-file=terraform.${WORKSPACE_NAME}.tfvars"
