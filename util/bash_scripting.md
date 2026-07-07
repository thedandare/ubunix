# Runbook: Automatizando CLI com Menus Interativos (Whiptail & Tmux)

## 1. Contexto e Objetivo
Este documento detalha o procedimento operacional padrão para construir menus dinâmicos de terminal integrados com o ecossistema Git, eliminando o preenchimento de tela cheia do `whiptail` tradicional através do isolamento de escopo via `tmux`.

---

## 2. Configurações Prévias

### Paleta de Cores Otimizada
Insira essas variáveis de ambiente no topo do seu script utilitário para renderizar as fontes de forma limpa.

```bash
# Configurações de Escape ANSI corrigidas
export Fg="\033[0;"
export Fb="\033[1;"
export R="31m"
export G="32m"
export B="34m"
export RESET="\033[0m"
```

### Validação do Primeiro Parâmetro
O script valida se o argumento essencial foi repassado via terminal pelo operador.

```bash
# Valida se o parâmetro essencial está nulo
if [ -z "\$1" ]; then
    echo -e "\${Fg}{R}Erro: O parâmetro 1 (arquivo) está nulo!{RESET}"
    exit 1
fi
```

---

## 3. Procedimento Operacional: TUI com Whiptail e Tmux

Selecione um dos métodos abaixo dependendo do comportamento desejado para a interface de controle do usuário.

### Método A: Pop-up Flutuante Integrado (Recomendado)
Abre uma janela suspensa centralizada no monitor, preservando o histórico e os logs do painel ativo atrás dela.

```bash
# Executa a TUI sem limpar o console principal do operador
tmux display-popup -E -w 60 -h 15 \
"whiptail --menu 'Ações Git:' 12 50 3 \
'1' 'Git Add (Adicionar Alterações)' \
'2' 'Git Status (Verificar Modificados)' \
'3' 'Sair' 3>&1 1>&2 2>&3"
```

### Método B: Janela Dividida Dinamicamente (Split Pane)
Reduz o consumo de espaço criando um mini-terminal temporário na margem inferior para rodar o assistente.

```bash
# Executa um split inferior cobrindo apenas 35% do espaço ativo
tmux split-window -v -p 35 \
"whiptail --menu 'Menu Rápido:' 10 45 2 \
'1' 'Git Add -A' \
'2' 'Sair' 3>&1 1>&2 2>&3 > /tmp/git_opcao.txt"
```

---

## 4. Tratamento do Fluxo e Execução Final

Abaixo está o tratamento condicional baseado no retorno de saída do componente visual (`whiptail`).

```bash
# Captura a resposta da interface gráfica
status_saida=\$?

if [ \$status_saida -ne 0 ]; then
    echo -e "{Fg}{R}Operação cancelada pelo usuário.\${RESET}"
    exit 1
else
    # Executa a ação do Git baseada no parâmetro validado anteriormente
    echo -e "{Fg}{G}Executando inclusão no repositório...\${RESET}"
    git add "\$1" -A
fi
```



# Runbook Completo: Integração Profissional Whiptail + Tmux

## 1. Contexto Teórico e Arquitetura
Por padrão, o `whiptail` limpa toda a tela do terminal e desenha um fundo cinza/azul que esconde o histórico de comandos do operador. Integrá-lo ao `tmux` resolve este problema: o menu é isolado em subjanelas (Pop-ups ou Split Panes), mantendo os logs anteriores visíveis no painel principal.

---

## 2. Recurso 1: Janelas Pop-up Flutuantes (Tmux >= 3.2)
Este método abre um box suspenso no centro da tela. É a interface mais limpa disponível porque não altera o layout dos seus painéis atuais.

### Sintaxe Básica do Pop-up
```bash
tmux display-popup -E -w 65 -h 15 "whiptail --menu 'Menu Git' 12 55 3 '1' 'Opção A' '2' 'Opção B' 3>&1 1>&2 2>&3"
```

### Como Capturar o Resultado do Menu de Dentro do Pop-up
Como o pop-up roda em uma subssessão isolada, a forma mais confiável de ler o dado escolhido e trazê-lo de volta para o seu script principal é usando um arquivo temporário em `/tmp/`.

**Código para o Script:**
```bash
# 1. Define um arquivo temporário exclusivo
ARQUIVO_TEMP=\$(mktemp)

# 2. Abre o pop-up e redireciona a saída do whiptail para o arquivo temporário
tmux display-popup -E -w 65 -h 15 "whiptail --menu 'Gerenciador Repositório' 12 55 3 \
'1' 'Executar git add' \
'2' 'Verificar git status' \
'3' 'Sair' 3>&1 1>&2 2>&3 > \$ARQUIVO_TEMP"

# 3. Lê o resultado salvo no arquivo e o remove em seguida
ESCOLHA=(catARQUIVO_TEMP)
rm -f \$ARQUIVO_TEMP

# 4. Trata a resposta recebida
case "\$ESCOLHA" in
    1) git add . -A ;;
    2) git status ;;
    *) echo "Operação cancelada ou encerrada." ;;
esac
```

---

## 3. Recurso 2: Divisão de Tela Dinâmica (Split Pane)
Se o seu terminal ou servidor antigo não suportar pop-ups, a alternativa é dividir a tela atual (Split), injetar o menu na parte inferior usando apenas uma porcentagem do monitor, e fechar o painel automaticamente após o Enter.

**Código para o Script:**
```bash
ARQUIVO_TEMP=\$(mktemp)

# -v (divisão vertical/inferior), -p 30 (ocupa apenas 30% da altura da tela)
tmux split-window -v -p 30 "whiptail --menu 'Ações Rápidas:' 10 45 2 \
'1' 'Commit Rápido' \
'2' 'Cancelar' 3>&1 1>&2 2>&3 > \$ARQUIVO_TEMP"

# Espera o painel do tmux fechar antes de ler o resultado no script principal
sleep 0.2 

ESCOLHA=(catARQUIVO_TEMP)
rm -f \$ARQUIVO_TEMP
```

---

## 4. Recurso 3: Avançado - Formulários e Checkboxes dentro do Tmux

O `whiptail` disponibiliza outros componentes interativos além de menus de texto simples. Abaixo estão os formatos adaptados para rodar de dentro do ecossistema `tmux`.

### Entrada de Texto (Inputbox) para Mensagem de Commit
```bash
ARQUIVO_TEMP=\$(mktemp)

tmux display-popup -E -w 65 -h 12 "whiptail --inputbox 'Digite a mensagem do Commit:' 10 55 '' 3>&1 1>&2 2>&3 > \$ARQUIVO_TEMP"

MSG_COMMIT=(catARQUIVO_TEMP)
rm -f \$ARQUIVO_TEMP

if [ -n "\$MSG_COMMIT" ]; then
    git commit -m "\$MSG_COMMIT"
fi
```

### Checkbox de Múltipla Escolha (Checklist) para Rodar Tarefas em Lote
Ideal para permitir que o operador use a **Barra de Espaço** para marcar múltiplas ações simultâneas antes de confirmar com o **Enter**.

```bash
ARQUIVO_TEMP=\$(mktemp)

tmux display-popup -E -w 70 -h 16 "whiptail --checklist 'Selecione as etapas de deploy:' 14 62 4 \
'1' 'Rodar Testes Unitários' ON \
'2' 'Gerar Build de Produção' OFF \
'3' 'Enviar tags ao Git' OFF \
'4' 'Limpar arquivos temporários' ON 3>&1 1>&2 2>&3 > \$ARQUIVO_TEMP"

SELECOES=(catARQUIVO_TEMP)
rm -f \$ARQUIVO_TEMP

# O retorno será uma string contendo as opções marcadas, ex: "1" "4"
echo "Ações agendadas: \$SELECOES"
```

---

## 5. Recurso 4: Customização Visual Hacker (Temas no Tmux)
Para evitar que o fundo do pop-up adote o azul corporativo padrão do `whiptail`, defina a variável `NEWT_COLORS_FILE` em linha de comando junto ao `tmux` para renderizar uma paleta customizada (ex: bordas vermelhas e fundo preto).

```bash
# Cria o arquivo de configuração visual em memória
echo "rootscreen black,black" > /tmp/tema_escuro.newt
echo "window red,black" >> /tmp/tema_escuro.newt
echo "border black,red" >> /tmp/tema_escuro.newt

# Executa o pop-up injetando o novo arquivo de propriedades visuais do motor Newt
tmux display-popup -E -w 60 -h 15 "export NEWT_COLORS_FILE=/tmp/tema_escuro.newt; whiptail --title 'ALERTA CRÍTICO' --msgbox 'Falha ao sincronizar branches!' 10 50"
```
