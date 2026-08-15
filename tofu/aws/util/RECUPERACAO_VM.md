# Recuperação de VM com Disco Parado

Quando uma spot instance é preemptada com `interruption_behavior = "stop"`, a VM é parada mas o disco EBS é preservado. Este script permite criar uma nova VM reutilizando o disco existente.

## Cenário

1. **Antes**: VM `amnix0s` (i-0c5aee3d686a2fb6d) está rodando com dados importantes
2. **Evento**: AWS preempta a spot instance → VM para, disco preservado
3. **Depois**: Você quer criar uma nova VM com o mesmo disco para recuperar os dados

## Uso Rápido

```bash
# Forma mais simples (usa defaults)
./recuperar-vm-disco-parado.sh i-0c5aee3d686a2fb6d

# Com tipo de instância customizado
./recuperar-vm-disco-parado.sh i-0c5aee3d686a2fb6d t3.medium

# Com região customizada
./recuperar-vm-disco-parado.sh i-0c5aee3d686a2fb6d t3.small us-west-2
```

## O que o Script Faz

1. **Valida** a instância parada existe e está no estado correto
2. **Coleta informações** da instância parada:
   - Subnet ID
   - Security Groups
   - Key Pair
   - AMI ID
   - Availability Zone
   - Volumes EBS
3. **Desanexa** todos os volumes EBS da instância parada
4. **Cria** uma nova instância com a mesma configuração
5. **Anexa** os volumes EBS à nova instância
6. **Retorna** informações de conexão

## Pré-requisitos

- AWS CLI configurado com credenciais válidas
- `jq` instalado para parsing JSON
- Permissões IAM para:
  - `ec2:DescribeInstances`
  - `ec2:DescribeVolumes`
  - `ec2:DetachVolume`
  - `ec2:AttachVolume`
  - `ec2:RunInstances`

## Exemplo Completo

```bash
$ ./recuperar-vm-disco-parado.sh i-0c5aee3d686a2fb6d

[INFO] Recuperando VM parada: i-0c5aee3d686a2fb6d
[INFO] Tipo de instância: t3.small
[INFO] Região: us-east-2

[INFO] Verificando status da instância...
[SUCCESS] Instância está parada

[INFO] Coletando informações da instância...
[INFO] Coletando volumes EBS...
[SUCCESS] Volumes encontrados:
  - vol-0123456789abcdef0 (40GB)

[INFO] Desanexando volumes da instância parada...
[INFO] Desanexando vol-0123456789abcdef0 de /dev/sda1...
[INFO] Aguardando desanexamento...
[SUCCESS] Volume vol-0123456789abcdef0 desanexado

[INFO] Criando nova instância...
[SUCCESS] Nova instância criada: i-1a2b3c4d5e6f7g8h9

[INFO] Aguardando nova instância ficar pronta...
[SUCCESS] Nova instância está rodando

[INFO] Anexando volumes à nova instância...
[INFO] Anexando vol-0123456789abcdef0 como /dev/sda1...
[SUCCESS] Volume vol-0123456789abcdef0 anexado

[SUCCESS] VM recuperada com sucesso!

Informações da nova instância:
  ID: i-1a2b3c4d5e6f7g8h9
  IP Privado: 10.0.1.42
  IP Público: 3.144.144.45
  Tipo: t3.small
  Região: us-east-2

Próximos passos:
  1. Aguarde alguns minutos para o sistema operacional inicializar
  2. Conecte via SSH:
     ssh -p 2409 root@3.144.144.45
  3. Verifique se os discos foram montados corretamente:
     lsblk
     mount | grep /dev

Instância parada original: i-0c5aee3d686a2fb6d
Você pode deletá-la depois se não precisar mais:
  aws ec2 terminate-instances --instance-ids i-0c5aee3d686a2fb6d --region us-east-2
```

## Fluxo de Recuperação Detalhado

### 1. Instância Parada por Preempção

```
┌─────────────────────────────────────┐
│ Spot Instance (parada)              │
│ ID: i-0c5aee3d686a2fb6d             │
│ State: stopped                      │
│ Volumes: vol-0123456789abcdef0      │
└─────────────────────────────────────┘
```

### 2. Desanexar Volumes

```
┌─────────────────────────────────────┐
│ Spot Instance (parada)              │
│ ID: i-0c5aee3d686a2fb6d             │
│ State: stopped                      │
│ Volumes: (nenhum)                   │
└─────────────────────────────────────┘
                    ↓
        ┌───────────────────────┐
        │ Volume EBS            │
        │ vol-0123456789abcdef0 │
        │ State: available      │
        └───────────────────────┘
```

### 3. Criar Nova Instância

```
┌─────────────────────────────────────┐
│ Nova Spot Instance                  │
│ ID: i-1a2b3c4d5e6f7g8h9             │
│ State: running                      │
│ Volumes: (nenhum ainda)             │
└─────────────────────────────────────┘
```

### 4. Anexar Volumes

```
┌─────────────────────────────────────┐
│ Nova Spot Instance                  │
│ ID: i-1a2b3c4d5e6f7g8h9             │
│ State: running                      │
│ Volumes: vol-0123456789abcdef0      │
└─────────────────────────────────────┘
         ↑
    ┌────────────────────────┐
    │ Volume EBS             │
    │ vol-0123456789abcdef0  │
    │ State: in-use          │
    └────────────────────────┘
```

## Verificação Pós-Recuperação

Após conectar na nova instância:

```bash
# Verificar discos
lsblk

# Verificar montagens
mount | grep /dev

# Verificar dados (exemplo)
ls -la /mnt/efs/
df -h

# Verificar containers Incus
incus list

# Verificar MicroK8s
microk8s status
```

## Troubleshooting

### Erro: "Instância não encontrada"

```bash
# Verificar ID da instância
aws ec2 describe-instances --region us-east-2 --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table
```

### Erro: "Volume ainda em uso"

Aguarde alguns segundos e tente novamente. O desanexamento pode levar tempo.

### Erro: "Permissão negada"

Verifique suas credenciais AWS:

```bash
aws sts get-caller-identity
```

### Volumes não aparecem na nova instância

Pode levar alguns minutos para o kernel reconhecer os novos discos. Tente:

```bash
# Rescan SCSI devices
echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan

# Ou reinicie a instância
sudo reboot
```

## Limpeza

Após confirmar que os dados foram recuperados com sucesso:

```bash
# Deletar instância parada (e seus volumes se não estiverem anexados)
aws ec2 terminate-instances \
    --instance-ids i-0c5aee3d686a2fb6d \
    --region us-east-2

# Verificar volumes órfãos
aws ec2 describe-volumes \
    --filters "Name=status,Values=available" \
    --region us-east-2
```

## Notas Importantes

1. **Custos**: Você continua pagando pelo armazenamento EBS enquanto o volume está desanexado
2. **Dados**: Os dados no disco são preservados, mas o sistema de arquivos pode precisar de verificação (`fsck`)
3. **Configuração de Rede**: A nova instância terá um novo IP privado/público
4. **Segurança**: Certifique-se de atualizar qualquer configuração que dependa do IP antigo

## Alternativa: Usar Terraform

Se preferir usar Terraform para criar a nova instância:

```hcl
resource "aws_instance" "recuperada" {
  ami           = data.aws_ami.nixos_x86_64.id
  instance_type = "t3.small"
  
  root_block_device {
    volume_id = "vol-0123456789abcdef0"  # Volume desanexado
  }
  
  tags = {
    Name = "amnix0s-recuperada"
  }
}
```

Depois execute:

```bash
tofu apply
```
