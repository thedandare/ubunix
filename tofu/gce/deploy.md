# Deploy GCE NixOS - Valores necessários e como obter

## Variáveis obrigatórias (sem default)

### 1. project_id
**Descrição:** ID do projeto GCP onde a VM e a rede serão criadas.

**Como obter:**
```bash
# Listar todos os projetos
gcloud projects list

# Definir projeto padrão
gcloud config set project PROJECT_ID

# Ver projeto atual
gcloud config get-value project
```

**Exemplo:** `meu-projeto-12345`

---

## Variáveis com default (podem precisar de alteração)

### 2. region
**Descrição:** Região GCP. Default: `us-east5` (São Paulo).

**Como obter:**
```bash
# Listar regiões disponíveis
gcloud compute regions list

# Ver detalhes de uma região específica
gcloud compute regions describe us-east5
```

**Exemplo:** `us-east5`, `us-central1`, `europe-west1`

---

### 3. zone
**Descrição:** Zona GCP. Default: `us-east5-a`. Confirme capacidade Spot para o machine_type escolhido.

**Como obter:**
```bash
# Listar zonas disponíveis em uma região
gcloud compute zones list --filter="region:us-east5"

# Ver zonas com capacidade para Spot
gcloud compute zones list --filter="region:us-east5" --format="table(name,status)"
```

**Exemplo:** `us-east5-a`, `us-east5-b`

---

### 4. machine_type
**Descrição:** Tipo da instância. Default: `e2-standard-2`. Para Incus/MicroK8s, comece com pelo menos e2-standard-2 ou maior.

**Como obter:**
```bash
# Listar tipos de máquina disponíveis em uma zona
gcloud compute machine-types list --zones=us-east5-a

# Filtrar por tipos específicos (ex: E2)
gcloud compute machine-types list --zones=us-east5-a --filter="name:e2-*"

# Ver detalhes de um tipo específico
gcloud compute machine-types describe e2-standard-2 --zone=us-east5-a
```

**Exemplos:** `e2-standard-2`, `e2-standard-4`, `e2-highmem-2`, `n2-standard-2`

---

### 5. nixos_image_project
**Descrição:** Projeto que contém a imagem custom do NixOS. Vazio usa `project_id`.

**Como obter:**
```bash
# Se usar imagem pública do NixOS, pode deixar vazio ou usar:
# "nixos-cloud" (imagens oficiais do NixOS no GCP)

# Se usar imagem custom no seu projeto, use o mesmo project_id
```

**Exemplo:** `""` (usa project_id), `"nixos-cloud"`, `"meu-projeto-12345"`

---

### 6. nixos_image_family
**Descrição:** Família da imagem custom NixOS criada no GCE. Default: `nixos-26-05-k7`. Ignorado se `nixos_image_self_link` for informado.

**Como obter:**
```bash
# Listar imagens disponíveis em um projeto
gcloud compute images list --project=nixos-cloud

# Listar apenas famílias de imagens
gcloud compute images list --project=nixos-cloud --no-standard-images

# Listar imagens do seu projeto
gcloud compute images list --project=PROJECT_ID
```

**Exemplo:** `nixos-26-05-k7`, `nixos-unstable`, `nixos-24-11`

---

### 7. nixos_image_self_link
**Descrição:** Self link de uma imagem GCE específica. Use para pin exato/reproduzível. Se vazio, usa `image_family`.

**Como obter:**
```bash
# Listar imagens com self links
gcloud compute images list --project=nixos-cloud --format="table(name,family,selfLink)"

# Obter self link de uma imagem específica
gcloud compute images describe nixos-26-05-k7 --project=nixos-cloud --format="value(selfLink)"
```

**Exemplo:** `projects/nixos-cloud/global/images/nixos-26-05-k7`

---

## Variáveis opcionais

### 8. service_account_email
**Descrição:** Service Account da VM. Vazio não declara bloco service_account.

**Como obter:**
```bash
# Listar service accounts no projeto
gcloud iam service-accounts list --project=PROJECT_ID

# Criar nova service account
gcloud iam service-accounts create SA_NAME --display-name="Display Name" --project=PROJECT_ID
```

**Exemplo:** `""` (sem service account), `sa-name@PROJECT_ID.iam.gserviceaccount.com`

---

## Configuração inicial do gcloud

Se ainda não configurou o gcloud CLI:

```bash
# Autenticar
gcloud auth login

# Configurar projeto padrão
gcloud config set project PROJECT_ID

# Configurar região padrão
gcloud config set compute/region us-east5

# Configurar zona padrão
gcloud config set compute/zone us-east5-a

# Ver configuração atual
gcloud config list
```

---

## Exemplo de arquivo terraform.tfvars

```hcl
project_id = "meu-projeto-12345"
region     = "us-east5"
zone       = "us-east5-a"
name       = "gcenix-spot"
machine_type = "e2-standard-2"

# Imagem NixOS (escolha uma das opções)
nixos_image_project = "nixos-cloud"  # ou "" para usar project_id
nixos_image_family  = "nixos-26-05-k7"
# nixos_image_self_link = "projects/nixos-cloud/global/images/nixos-26-05-k7"

# Rede
subnet_cidr = "10.42.0.0/24"

# SSH
ssh_source_ranges = ["SEU.IP.AQUI/32"]  # Substituir pelo seu IP
ssh_user = "leo"
ssh_port = 2409

# OS Login (recomendado para NixOS GCE recente)
enable_oslogin = true
manage_oslogin_keys = true

# IP público
assign_public_ip = true
reserve_static_ip = true
network_tier = "PREMIUM"

# Spot
spot_termination_action = "STOP"  # ou "DELETE"
boot_disk_auto_delete = false  # Preserva disco ao destruir VM

# Service Account (opcional)
# service_account_email = "sa-name@PROJECT_ID.iam.gserviceaccount.com"
```

---

## Comandos úteis para verificação

```bash
# Verificar cotas de Spot na região
gcloud compute regions describe us-east5 --format="value(quotas)"

# Verificar capacidade de Spot para um tipo de máquina
gcloud compute machine-types list --zones=us-east5-a --filter="name:e2-standard-2"

# Verificar imagens NixOS disponíveis
gcloud compute images list --project=nixos-cloud --filter="name:nixos*"
```
