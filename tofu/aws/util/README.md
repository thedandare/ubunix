# Multi SSH CLI

Script bash para conexão multi-SSH em VMs AWS via tmux, usando `dialog` para seleção interativa.

## Uso

```bash
cd /osnix/ubunix/tofu/aws/util
./multi_ssh_cli.sh
```

## Funcionalidades

- Seleção de VMs por região (seleciona todas as VMs da região)
- Seleção individual de VMs
- Multi-shell SSH via tmux (panes horizontais)
- Interface `dialog` (ncurses)

## Dependências

- `dialog` - Interface ncurses
- `tmux` - Multi-shell
- `ssh` - Conexão remota
- AWS CLI configurado (para `describe-ips.sh`)

## Configuração

Edit as constantes no topo do script:

```bash
SESSION="amnix"           # Nome da sessão tmux
SSH_PORT=2409             # Porta SSH
SSH_KEY=/root/.ssh/root_id_ed25519  # Chave SSH
```

## Fluxo

1. Script coleta VMs via `describe-ips.sh`
2. Mostra checklist `dialog` com regiões e VMs
3. Selecionar uma região marca todas as VMs daquela região
4. Selecionar VMs individuais marca apenas as selecionadas
5. Confirmação e lançamento do tmux

## Comandos úteis

```bash
# Ver VMs disponíveis
./describe-ips.sh

# Matar sessão tmux manualmente
tmux kill-session -t amnix

# Listar sessões tmux
tmux list-sessions
```
