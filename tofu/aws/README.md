# OpenTofu + NixOS + Incus + Ubuntu MicroK8s bootstrap v3

Este pacote sobe uma EC2 com a AMI oficial do NixOS em `sa-east-1`, corrige o bootstrap SSH e prepara o fluxo:

1. OpenTofu cria a instância NixOS.
2. `amazon-init` aplica um `user-data` NixOS mínimo.
3. O NixOS abre SSH nas portas `22` e `2409` para debug.
4. O serviço `bootstrap-leonix-v3` clona `https://github.com/thedandare/nixos`.
5. Copia os arquivos de `leonix/virtualisation/` para `/etc/nixos`.
6. Roda `./compile-cloudinit.sh` para gerar `cloud-init.yaml`.
7. Cria um wrapper de `/etc/nixos/configuration.nix` importando:
   - `configuration.base.nix`
   - `leonix-host.nix`
   - `incus.nix`
8. Executa `nixos-rebuild switch`.
9. Sobe Incus e o container Ubuntu `leonk8s`.
10. Dentro do Ubuntu, cloud-init instala Tailscale e MicroK8s.

## Arquivos importantes

```text
main.tf
variables.tf
outputs.tf
nix/user-data.nix.tftpl
payload/leonix/virtualisation/incus.nix
payload/leonix/virtualisation/cloud-init.template.yaml
payload/leonix/virtualisation/compile-cloudinit.sh
payload/leonix/virtualisation/init_tailscale.sh
payload/leonix/virtualisation/network-config.yaml
payload/leonix/virtualisation/microceph_cluster_join.sh
```

## Antes de aplicar

Copie os arquivos corrigidos de `payload/leonix/virtualisation/` para o seu repo `nixos/leonix/virtualisation/` e faça commit/push.

Atalho:

```bash
./scripts/sync-payload-to-local-repo.sh /caminho/para/nixos
cd /caminho/para/nixos
git diff
git add leonix/virtualisation
git commit -m "bootstrap aws nixos incus v3"
git push
```

O `user-data` da EC2 tem limite pequeno; por isso ele **não embute** todos os anexos. Ele clona o repo e copia de lá.

## Credenciais Tailscale

Para laboratório, você pode passar por variáveis do OpenTofu:

```bash
export TF_VAR_tailscale_client_id='...'
export TF_VAR_tailscale_client_secret='...'
```

Aviso: valores passados via `user_data` podem aparecer no state e no console output. Para produção, trocar por SSM/Secrets Manager/secret externo.

## Executar

```bash
tofu init
tofu fmt
tofu plan
tofu apply
```

Depois:

```bash
tofu output ssh_root_2409
tofu output ssh_nixos_2409
```

## Monitoramento

Via AWS Console Output:

```bash
aws ec2 get-console-output \
  --instance-id ID_DA_INSTANCIA \
  --latest \
  --query Output \
  --output text | less
```

Via SSH no host NixOS:

```bash
journalctl -u amazon-init -f
journalctl -u bootstrap-leonix-v3 -f
tail -f /var/log/bootstrap-leonix-v3.log
```

Status:

```bash
systemctl status bootstrap-leonix-v3 --no-pager
systemctl status incus --no-pager
systemctl status incus-preseed --no-pager
systemctl status init-incus-leonk8s --no-pager
incus list
```

Dentro do Ubuntu:

```bash
incus exec leonk8s -- cloud-init status --long
incus exec leonk8s -- journalctl -u cloud-final --no-pager -n 200
incus exec leonk8s -- systemctl status tailscaled --no-pager
incus exec leonk8s -- microk8s status --wait-ready
incus exec leonk8s -- microk8s kubectl get nodes -o wide
```

## Sobre o SSH

O v3 corrige o problema principal mantendo a configuração de SSH em duas camadas:

- no `user-data.nix.tftpl`, antes do switch pesado;
- em `/etc/nixos/leonix-host.nix`, persistida depois do `nixos-rebuild switch`.

Isso evita perder acesso quando `configuration.nix` é substituído/importado.

Enquanto estiver em bootstrap, deixe `22` e `2409` abertas. Depois que `2409` estiver validada, remova a regra da `22` do Security Group e de `leonix-host.nix`.

## Resumo da sessao de troubleshooting

### Problema: AWS pedia senha apesar de injetar chave SSH

A instancia NixOS foi criada com `user_data` contendo uma configuracao NixOS, mas o `amazon-init` nao estava aplicando esse `user_data` corretamente. Isso causava inconsistencia e o SSH caia em prompt de senha.

### Solucao aplicada

- Removemos o `user_data` do `aws_instance.nixos_x86_64`
- Deixamos apenas o `aws_key_pair` + `key_name` para injetar a chave
- A AWS passou a injetar a chave `leo@ali` (`/home/leo/.ssh/id_ed25519`) no usuario padrao da AMI NixOS: `root`
- Apos `tofu apply`, acesso SSH funcionou:

```bash
ssh -i /home/leo/.ssh/id_ed25519 root@<ip>
```

### Arquivos alterados nesta sessao

- `aws/main.tf` - removido `user_data` e `user_data_replace_on_change`
- `aws/nix/_user-data.nix` - adicionado import de `amazon-image.nix` (nao usado no momento)
- `aws/custom-image-vm/main.tf` - exemplo de AMI customizada
- `aws/container-registry/main.tf` - exemplo de ECR

## Alternativas de imagem/container

- `custom-image-vm/` - cria AMI a partir da instancia atual (`aws_ami_from_instance`) para clonar VMs
- `container-registry/` - cria repositorio privado ECR para imagens de container

### Custom Image

```bash
cd /osnix/ubunix/tofu/aws/custom-image-vm
tofu init
tofu apply
```

A AMI gerada pode ser usada como `ami` em novas instancias.

### Container Registry (ECR)

```bash
cd /osnix/ubunix/tofu/aws/container-registry
tofu init
tofu apply
```

Depois, fazer login e push:

```bash
aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin <account_id>.dkr.ecr.<region>.amazonaws.com

docker tag minha-imagem:latest <account_id>.dkr.ecr.<region>.amazonaws.com/nixos:minha-imagem
docker push <account_id>.dkr.ecr.<region>.amazonaws.com/nixos:minha-imagem
```
