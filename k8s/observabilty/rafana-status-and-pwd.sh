#!/bin/sh
#sudo su
CONTEXTPATH="/root/.kube/config"
SERVER="192.168.2.7"
if [[ ! -f "$CONTEXTPATH"  ]]; then  #|| ! -f "$JOIN_SCRIPT_PATH"
    fail "Contexto do Kubectl nao encontrado: $CONTEXTPATH \n\n Copiando de  "
    scp -i /home/leo/.ssh/root_id_ed25519 root@$SERVER:/root/.kube/config /root/.kube/config
    cp /root/.kube/config /home/leo/.kube/config
fi

CHOICE=$(whiptail --title "grafana" --menu "\n\nServidor: $SERVER\n" 15 60 2 \
"1" "Ver Pods" \
"2" "Ver Secret" \
3>&1 1>&2 2>&3)

# Handle the choice or exit if cancelled
if [ $? -ne 0 ]; then
    echo "You cancelled the selection."
else
    case $CHOICE in
        "1")
            echo "You selected Pods."
            kubectl --namespace observability get pods -l "release=kube-prom-stack"

            ;;
        "2")
            echo "You selected Secret."
            kubectl --namespace observability get secrets kube-prom-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
            ;;
    esac
fi

#
