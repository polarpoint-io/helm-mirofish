# Installation

## Before you start

| | |
|---|---|
| Kubernetes | 1.25 or newer |
| Helm | 3.8 or newer (OCI registry support) |
| StorageClass | A default one, or set `global.storageClass` |
| GPU | Optional but strongly recommended — see [sizing](#sizing) |

The chart pulls three third-party images (`neo4j`, `ollama/ollama`, `curlimages/curl`) and two of its own from GHCR. Behind a private registry, set `global.imageRegistry` and `global.imagePullSecrets`.

## Sizing

At default values the chart requests roughly 4 CPU and 12Gi of memory, and claims about 170Gi across three volumes.

| Component | CPU req | Mem req | Mem limit | Volume |
|---|---|---|---|---|
| api | 500m | 1Gi | 4Gi | 20Gi |
| web (x2) | 50m each | 64Mi each | 256Mi each | — |
| neo4j | 500m | 2Gi | 4Gi | 50Gi |
| ollama | 2 | 8Gi | 32Gi | 100Gi |

The Ollama figures assume a GPU is doing the work. On CPU, memory needs to cover the whole model.

Rough model sizing:

| Model | Disk | GPU VRAM | Practical on CPU? |
|---|---|---|---|
| `qwen2.5:32b` | ~20GB | 24GB+ | No |
| `qwen2.5:14b` | ~9GB | 16GB | Barely |
| `qwen2.5:7b` | ~4.7GB | 8GB | Slow but workable |
| `qwen2.5:1.5b` | ~1GB | 4GB | Yes, for smoke tests only |
| `nomic-embed-text` | ~280MB | minimal | Yes |

A simulation makes one LLM call per agent per round. At the default 10 rounds with a few hundred agents, that is thousands of calls — which is why CPU inference on a 32B model is not viable.

## Install

### With a GPU

```bash
helm install mirofish oci://ghcr.io/polarpoint-io/charts/mirofish-offline \
  --namespace mirofish --create-namespace \
  --set neo4j.auth.password='<choose-one>' \
  --set ollama.gpu.enabled=true \
  --set ollama.gpu.nodeSelector."cloud\.google\.com/gke-accelerator"=nvidia-l4
```

`ci/gpu-values.yaml` in the chart is the same thing as a values file, which is easier to read.

The cluster needs a device plugin already installed (NVIDIA GPU Operator or equivalent) so that `nvidia.com/gpu` is a schedulable resource.

### Without a GPU

Use a small model. The chart will warn you at install time if you leave `qwen2.5:32b` on CPU.

```bash
helm install mirofish oci://ghcr.io/polarpoint-io/charts/mirofish-offline \
  --namespace mirofish --create-namespace \
  --set neo4j.auth.password='<choose-one>' \
  --set ollama.models.chat=qwen2.5:7b \
  --set config.llmModel=qwen2.5:7b
```

`ollama.models.chat` and `config.llmModel` must agree — one controls what gets downloaded, the other what the app asks for. The chart warns on a mismatch rather than failing, since you may be pointing at a pre-seeded volume.

### From a local checkout

```bash
git clone https://github.com/polarpoint-io/helm-mirofish
cd helm-mirofish
make install NAMESPACE=mirofish VALUES=charts/mirofish-offline/ci/small-model-values.yaml
```

## Wait for the models

`helm install` returns before the models are downloaded — deliberately, since a cold `qwen2.5:32b` pull can take a long time. Until it finishes, graph building and simulation fail with model-not-found errors.

```bash
kubectl get jobs -n mirofish
kubectl logs -n mirofish -f job/mirofish-mirofish-offline-ollama-model-pull-1
```

## Verify

```bash
helm test mirofish --namespace mirofish --logs
```

This checks the API health endpoint, the web health endpoint, the nginx-to-API proxy path, and that Ollama is answering and listing its models.

## Reach the UI

Port-forward, which is a fully working deployment because nginx proxies `/api` itself:

```bash
kubectl port-forward -n mirofish svc/mirofish-mirofish-offline-web 8080:80
```

Or enable an Ingress:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    # Match the backend's 50MB upload limit and long-running requests.
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
  hosts:
    - host: mirofish.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: mirofish-tls
      hosts:
        - mirofish.example.com
```

Both annotations matter. Without the body-size annotation, document uploads fail at the ingress controller before reaching the app; without the read timeout, ontology generation appears to hang and then 504s.

## Managing secrets yourself

Create the Secrets first:

```bash
kubectl create secret generic mirofish-neo4j \
  -n mirofish --from-literal=password='<neo4j-password>'

kubectl create secret generic mirofish-app-secrets \
  -n mirofish \
  --from-literal=llm-api-key=ollama \
  --from-literal=flask-secret-key="$(openssl rand -hex 32)"
```

Then point the chart at them:

```yaml
neo4j:
  auth:
    existingSecret: mirofish-neo4j
    existingSecretPasswordKey: password
config:
  existingSecret: mirofish-app-secrets
```

The chart stops rendering a Secret of its own once both are set.

## Uninstalling

```bash
helm uninstall mirofish -n mirofish
```

Volumes are **not** removed. The `api` uploads PVC carries `helm.sh/resource-policy: keep`, and StatefulSet volume claim templates are never garbage-collected by Kubernetes. To reclaim the storage:

```bash
kubectl delete pvc -n mirofish -l app.kubernetes.io/instance=mirofish
```
