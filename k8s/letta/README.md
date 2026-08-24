# Letta App Server

This directory deploys the Letta App Server for clients using the Letta Agent SDK. It runs the local backend, so agent state is persisted in the `letta-state` PVC at `/root/.letta`.

## Build the image

The image is based on Letta's published `letta-code` image and starts:

```text
letta server --backend local --listen ws://0.0.0.0:4500 --ws-auth capability-token
```

Build and publish it to Docker Hub so every MicroK8s node can pull it:

```bash
docker build -t letta-app-server:local .
docker tag letta-app-server:local thedandare/fibo-letta-server:v1.0.0
docker push thedandare/fibo-letta-server:v1.0.0
```

The deployment uses `thedandare/fibo-letta-server:v1.0.0` with `imagePullPolicy: IfNotPresent`. This avoids node-local image availability problems in a multi-node cluster.

## Configure the token

Create the namespace and token Secret. Do not commit the token to this repository:

```bash
microk8s kubectl create namespace letta --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl -n letta create secret generic letta-app-server \
  --from-literal=token='replace-with-a-long-random-token' \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

Set any model provider credentials required by the agents in the same Secret and add them to the Deployment as `secretKeyRef` values. The manifest intentionally does not contain provider keys.

## Deploy to the remote MicroK8s cluster

`deploy.sh` builds and pushes the image to Docker Hub, creates the token Secret if it does not already exist, applies the manifest, and waits for the rollout:

```bash
./deploy.sh
```

Override the defaults when needed:

```bash
IMAGE=thedandare/fibo-letta-server:v1.0.0 \
SSH_HOST=root@35.215.33.107 \
./deploy.sh
```

For a local cluster, the individual Kubernetes commands are:

```bash
microk8s kubectl apply -f deployment.yaml
microk8s kubectl -n letta rollout status deployment/letta-app-server
microk8s kubectl -n letta get pods,svc,pvc
```

Check the remote deployment without changing anything:

```bash
./status.sh
```

The server is available through the MicroK8s node at `http://<node-ip>:32500`; its WebSocket endpoint is `/ws`. Configure the SDK with the service URL (for example, `http://<node-ip>:32500`) and the same token as `authToken`.

## Expose through Traefik

`expose.sh` publishes the App Server, including its WebSocket endpoint, through the existing MicroK8s Traefik ingress:

```bash
./expose.sh
```

The default hostname is `https://letta.35.215.33.107.nip.io`. Change the `Host(...)` value in `expose.yaml` if you use a dedicated DNS name.

The `NodePort` is also retained as a direct access path. Restrict it with firewall rules or replace it with an internal `ClusterIP` if Traefik is the only intended entry point.
