# Flux CD GitOps — EFS Driver + OpenObserve

## Estrutura de Pastas

```
flux-gitops/
├── clusters/
│   └── meu-cluster/
│       ├── infrastructure.yaml   # Kustomization: sobe EFS driver + StorageClass
│       └── apps.yaml             # Kustomization: sobe OpenObserve (dependsOn: cluster-infra)
├── infrastructure/
│   ├── aws-efs-driver.yaml       # HelmRepository + HelmRelease do EFS CSI Driver
│   └── efs-storageclass.yaml     # StorageClass apontando para o EFS fs-04ef6e005c89a49e4
└── apps/
    └── openobserve.yaml          # HelmRepository + HelmRelease do OpenObserve
```

## Correções aplicadas vs. o rascunho original

| Campo | Valor original (corrompido) | Valor corrigido |
|---|---|---|
| Helm repo EFS | `https://github.io` | `https://kubernetes-sigs.github.io/aws-efs-csi-driver/` |
| provisioner | `://aws.com` | `efs.csi.aws.com` |
| Helm repo OpenObserve | `https://openobserve.ai` | `https://charts.openobserve.ai` |
| `apps.yaml` path | `./infrastructure` (duplicado) | `./apps` (separado) |

A separação `./infrastructure` vs `./apps` é importante: se ambos os Kustomizations apontassem para o mesmo path, o Flux aplicaria tudo duas vezes. Com paths separados, o `cluster-infra` aplica apenas o driver + StorageClass, e o `cluster-apps` aplica apenas o OpenObserve — respeitando a dependência.

---

## Passo a Passo

### Pré-requisitos

- Flux CD já instalado no cluster MicroK8s
- Repositório Git configurado como source do Flux (`flux-system` GitRepository)
- EFS `fs-04ef6e005c89a49e4` ativo com mount targets nas subnets do cluster

### Passo 1 — Copiar os arquivos para o repositório Git

Copie a pasta `flux-gitops/` para a raiz do seu repositório Git que o Flux já monitora.

Se o seu repositório Flux ainda não existe, crie:

```bash
# No cluster MicroK8s, bootstrap do Flux apontando para seu repo
flux bootstrap git \
  --url=ssh://git@github.com/seu-usuario/seu-repo.git \
  --branch=main \
  --path=clusters/meu-cluster
```

### Passo 2 — Commit e Push

```bash
cd seu-repositorio
git add .
git commit -m "feat: add EFS CSI driver + StorageClass + OpenObserve via Flux GitOps"
git push origin main
```

### Passo 3 — Forçar a reconciliação imediata

Não espere os 10 minutos do intervalo. Force o Flux a ler agora:

```bash
flux reconcile kustomization flux-system --with-source
```

### Passo 4 — Acompanhar a ordem de inicialização

```bash
flux get kustomizations --watch
```

Você deve ver:

1. `cluster-infra` → Ready (EFS driver + StorageClass aplicados)
2. `cluster-apps` → Ready (OpenObserve instalado após infra saudável)

### Passo 5 — Validar os recursos no cluster

```bash
# Verificar Helm releases
helm list -n kube-system    # aws-efs-csi-driver
helm list -n monitoring     # openobserve

# Verificar StorageClass
kubectl get sc efs-sc

# Verificar pods do EFS driver
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver

# Verificar pods do OpenObserve
kubectl get pods -n monitoring

# Verificar PVC do OpenObserve (deve estar Bound usando EFS)
kubectl get pvc -n monitoring
```

### Passo 6 — Troubleshooting

Se algo der errado:

```bash
# Logs do Flux para ver o que aconteceu
flux logs --follow

# Status detalhado de um Kustomization específico
flux describe kustomization cluster-infra
flux describe kustomization cluster-apps

# Se o OpenObserve não subir, verificar eventos
kubectl get events -n monitoring --sort-by='.lastTimestamp'

# Se o PVC ficar Pending, verificar eventos do PVC
kubectl describe pvc -n monitoring
```

---

## Fluxo GitOps

```
git push
  └─→ Flux detecta mudança
       └─→ cluster-infra (Kustomization)
            ├─→ HelmRepository: aws-efs-csi-driver
            ├─→ HelmRelease: aws-efs-csi-driver (instala o driver)
            └─→ StorageClass: efs-sc (cria o SC apontando para o EFS)
                 └─→ cluster-infra fica Ready ✓
                      └─→ cluster-apps (Kustomization, dependsOn: cluster-infra)
                           ├─→ HelmRepository: openobserve
                           └─→ HelmRelease: openobserve (instala com PVC no efs-sc)
                                └─→ cluster-apps fica Ready ✓
```
