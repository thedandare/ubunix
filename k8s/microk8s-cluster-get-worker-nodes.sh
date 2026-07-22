#!/bin/sh

# 1. Salva a saída dos comandos usando $()
message=$(incus exec leonk8s -- microk8s kubectl get nodes -l node.kubernetes.io/microk8s-worker=microk8s-worker)

controlpane=$(incus exec leonk8s -- microk8s kubectl get nodes -l node.kubernetes.io/microk8s-controlplane=microk8s-controlplane)

# 2. Formata o texto com quebra de linha real usando printf
TEXTO_FINAL=$(printf "%s\n\n%s" "$message" "$controlpane")

# 3. Exibe no Whiptail (Atenção: o --title vem ANTES do --msgbox)
whiptail --title "Intro to Whiptail" --msgbox "$TEXTO_FINAL" 20 80



#kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels}{"\n"}{end}'
