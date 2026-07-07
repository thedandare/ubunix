# Plano v3

## Objetivo

Subir NixOS na AWS e usar NixOS como host Incus. O Kubernetes roda dentro de um Ubuntu cloud image no Incus. O storage/MicroCeph fica em stub nesta fase.

## Decisoes

- SSH em `22` e `2409` durante bootstrap.
- Chaves aplicadas em `root` e no usuário `nixos`.
- `configuration.nix` vira wrapper, preservando a configuração base da AMI em `configuration.base.nix`.
- `leonix-host.nix` mantém SSH/firewall/pacotes depois do `switch`.
- `incus.nix` não importa `../secret`.
- Incus usa `incusbr0` NAT, não `br0`.
- Ubuntu usa DHCP, não IP fixo `192.168.0.11`.
- Tailscale recebe credenciais pelo `cloud-init.yaml` compilado.
- MicroCeph fica desativado com stub.

## Fluxo

```text
OpenTofu
  -> EC2 NixOS
  -> amazon-init user-data NixOS
  -> SSH 22/2409
  -> bootstrap-leonix-v3.service
  -> git clone repo
  -> copy leonix/virtualisation/* para /etc/nixos
  -> compile-cloudinit.sh
  -> configuration.nix wrapper
  -> nixos-rebuild switch
  -> incus preseed
  -> leonk8s Ubuntu
  -> Tailscale
  -> MicroK8s
```
