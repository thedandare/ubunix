  export POD_NAME=$(microk8s kubectl get pods --namespace kube-system -l "app.kubernetes.io/name=headlamp,app.kubernetes.io/instance=my-headlamp" -o jsonpath="{.items[0].metadata.name}")
  export CONTAINER_PORT=$(microk8s  kubectl get pod --namespace kube-system $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
  echo "Visit http://127.0.0.1:8080 to use your application"
  microk8s  kubectl --namespace kube-system port-forward $POD_NAME 8080:$CONTAINER_PORT