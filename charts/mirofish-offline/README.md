# mirofish-offline

Deploys [MiroFish-Offline](https://github.com/nikmcfly/MiroFish-Offline) together with the Neo4j graph store and Ollama inference server it depends on. All inference is local and no cloud API keys are used.

Two things still reach outside the cluster: Ollama downloads model weights on first start (see `ollama.modelPull`), and upstream's `index.html` loads webfonts from `fonts.googleapis.com`, so the UI falls back to system fonts on an air-gapped network.

## Installing

```bash
helm install mirofish oci://ghcr.io/polarpoint-io/charts/mirofish-offline \
  --namespace mirofish --create-namespace \
  --set neo4j.auth.password='<choose-one>'
```

## Requirements

| | |
|---|---|
| Kubernetes | >= 1.25 |
| Storage | A default StorageClass, or set `global.storageClass`. ~170Gi across three PVCs at default sizes. |
| Image tag | The chart defaults to `appVersion` (`0.2.0`). Publishing that tag requires a `v0.2.0` git tag in this repo — see the repository README. |
| Compute | ~4 CPU / 12Gi requested at defaults, before the GPU. |
| GPU | Strongly recommended. `qwen2.5:32b` on CPU is too slow to be usable for simulations. |
| Egress | Ollama downloads model weights on first start unless you pre-seed the volume. |

## Values

### Top level

| Key | Default | Description |
|---|---|---|
| `nameOverride` | `""` | Override the chart name in resource names. |
| `fullnameOverride` | `""` | Override the full resource name prefix. |
| `commonLabels` | `{}` | Labels added to every object. |
| `commonAnnotations` | `{}` | Annotations added to every object. |
| `global.imageRegistry` | `""` | Registry prefix applied to every image, including Neo4j and Ollama. |
| `global.imagePullSecrets` | `[]` | Pull secrets for every pod. |
| `global.storageClass` | `""` | StorageClass for every PVC. `-` disables dynamic provisioning. |
| `serviceAccount.create` | `true` | Create a ServiceAccount for the release. |
| `serviceAccount.name` | `""` | Name to use; generated when empty. |
| `serviceAccount.annotations` | `{}` | Annotations on the ServiceAccount, e.g. for IRDP/workload identity. |
| `serviceAccount.automountServiceAccountToken` | `false` | No component talks to the Kubernetes API. |

### `api` — Flask backend

| Key | Default | Description |
|---|---|---|
| `api.image.registry` / `.repository` / `.tag` / `.digest` | `ghcr.io` / `polarpoint-io/mirofish-offline-api` / `""` / `""` | Empty tag means the chart's `appVersion`. |
| `api.image.pullPolicy` | `IfNotPresent` | |
| `api.replicaCount` | `1` | **Must be 1.** Any other value fails the render — see [architecture](../../docs/architecture.md). |
| `api.service.type` / `.port` | `ClusterIP` / `5001` | |
| `api.resources` | 500m / 1Gi requested, 4Gi limit | Raise memory for large simulations. |
| `api.persistence.enabled` | `true` | Uploaded documents, personas, simulation output, reports. |
| `api.persistence.size` | `20Gi` | |
| `api.persistence.existingClaim` | `""` | Use a claim you manage instead. |
| `api.persistence.storageClass` / `.accessModes` / `.annotations` | `""` / `[ReadWriteOnce]` / `{}` | The PVC is annotated `helm.sh/resource-policy: keep`. |
| `api.livenessProbe` / `.readinessProbe` / `.startupProbe` | enabled | All hit `/health`. The startup probe allows 10 minutes. |
| `api.podSecurityContext` / `.containerSecurityContext` | non-root, uid 10001, caps dropped | |
| `api.terminationGracePeriodSeconds` | `120` | Time for in-flight simulation subprocesses to stop. |
| `api.extraEnv` / `.extraEnvFrom` / `.extraVolumes` / `.extraVolumeMounts` | `[]` | Escape hatches. |
| `api.command` / `.args` | `[]` | Override the gunicorn invocation. To tune it without replacing it, set `GUNICORN_THREADS` or `GUNICORN_TIMEOUT` through `api.extraEnv`. |
| `api.nodeSelector` / `.tolerations` / `.affinity` / `.topologySpreadConstraints` / `.priorityClassName` / `.podAnnotations` / `.podLabels` | | Standard scheduling controls. |

### `web` — nginx serving the built SPA

| Key | Default | Description |
|---|---|---|
| `web.image.registry` / `.repository` / `.tag` / `.digest` / `.pullPolicy` | `ghcr.io` / `polarpoint-io/mirofish-offline-web` / `""` / `""` / `IfNotPresent` | |
| `web.replicaCount` | `2` | Ignored when autoscaling is on. |
| `web.service.type` / `.port` / `.targetPort` | `ClusterIP` / `80` / `8080` | `targetPort` sets both the Service target and nginx's own listen port. It must be >= 1024 — nginx runs unprivileged — and the chart refuses to render otherwise. |
| `web.resources` | 50m / 64Mi requested, 256Mi limit | |
| `web.autoscaling.enabled` | `false` | HPA on CPU and optionally memory. |
| `web.autoscaling.minReplicas` / `.maxReplicas` / `.targetCPUUtilizationPercentage` / `.targetMemoryUtilizationPercentage` | `2` / `6` / `80` / `""` | |
| `web.podDisruptionBudget.enabled` / `.minAvailable` | `false` / `1` | |
| `web.livenessProbe` / `.readinessProbe` | enabled | Both hit `/healthz`, served by nginx itself. |
| `web.podSecurityContext` / `.containerSecurityContext` | non-root, uid 101 | |
| `web.extraEnv` / `.extraVolumes` / `.extraVolumeMounts` / `.nodeSelector` / `.tolerations` / `.affinity` / `.topologySpreadConstraints` / `.priorityClassName` / `.podAnnotations` / `.podLabels` | | |

### `neo4j` — knowledge graph

| Key | Default | Description |
|---|---|---|
| `neo4j.image.registry` / `.repository` / `.tag` / `.pullPolicy` | `docker.io` / `neo4j` / `5.26.29-community` / `IfNotPresent` | |
| `neo4j.auth.username` | `neo4j` | |
| `neo4j.auth.password` | `mirofish` | **Change this.** Rejected below 8 characters. |
| `neo4j.auth.existingSecret` | `""` | Read the password from a Secret you manage. |
| `neo4j.auth.existingSecretPasswordKey` | `neo4j-password` | Key within that Secret. |
| `neo4j.plugins` | `["apoc"]` | APOC is required by the graph builder. |
| `neo4j.heap.initialSize` / `.maxSize` | `512m` / `2g` | Keep `heap.maxSize` + `pagecache.size` below the memory limit. |
| `neo4j.pagecache.size` | `1g` | |
| `neo4j.service.type` / `.boltPort` / `.httpPort` | `ClusterIP` / `7687` / `7474` | |
| `neo4j.browser.enabled` | `false` | Exposes the Neo4j Browser on the Service. It is an admin console — leave off. |
| `neo4j.resources` | 500m / 2Gi requested, 4Gi limit | |
| `neo4j.persistence.enabled` / `.size` / `.storageClass` / `.accessModes` / `.annotations` | `true` / `50Gi` / `""` / `[ReadWriteOnce]` / `{}` | |
| `neo4j.podSecurityContext` / `.containerSecurityContext` | non-root, uid 7474 | |
| `neo4j.extraEnv` / `.nodeSelector` / `.tolerations` / `.affinity` / `.priorityClassName` / `.podAnnotations` / `.podLabels` | | |

### `ollama` — local inference

| Key | Default | Description |
|---|---|---|
| `ollama.image.registry` / `.repository` / `.tag` / `.pullPolicy` | `docker.io` / `ollama/ollama` / `0.32.15` / `IfNotPresent` | |
| `ollama.gpu.enabled` | `false` | Turn this on for any real workload. |
| `ollama.gpu.resourceName` / `.count` | `nvidia.com/gpu` / `1` | |
| `ollama.gpu.nodeSelector` / `.tolerations` | `{}` / `[]` | Merged with `ollama.nodeSelector` / `.tolerations` when GPU is enabled. |
| `ollama.models.chat` | `qwen2.5:32b` | Must match `config.llmModel`. |
| `ollama.models.embedding` | `nomic-embed-text` | Must match `config.embeddingModel`. |
| `ollama.models.extra` | `[]` | Additional models to pull. |
| `ollama.modelPull.enabled` | `true` | Pulls the models after install/upgrade via a plain Job, so `helm install` does not block on a multi-gigabyte download. |
| `ollama.modelPull.image.*` | `docker.io/curlimages/curl:8.21.0` | |
| `ollama.modelPull.backoffLimit` / `.activeDeadlineSeconds` / `.ttlSecondsAfterFinished` / `.resources` | `3` / `21600` / `3600` / small | |
| `ollama.service.type` / `.port` | `ClusterIP` / `11434` | |
| `ollama.resources` | 2 CPU / 8Gi requested, 32Gi limit | Size for the model you actually run. |
| `ollama.persistence.enabled` / `.size` / `.storageClass` / `.accessModes` / `.annotations` | `true` / `100Gi` / `""` / `[ReadWriteOnce]` / `{}` | `qwen2.5:32b` alone is ~20GB. |
| `ollama.podSecurityContext` / `.containerSecurityContext` | root (the image needs it for GPU device access) | |
| `ollama.extraEnv` / `.nodeSelector` / `.tolerations` / `.affinity` / `.priorityClassName` / `.podAnnotations` / `.podLabels` | | |

### `config` — application settings

Rendered into a ConfigMap and a Secret consumed by the API.

| Key | Default | Description |
|---|---|---|
| `config.llmApiKey` | `ollama` | Required by the OpenAI client; Ollama ignores the value. |
| `config.llmModel` | `qwen2.5:32b` | Must match `ollama.models.chat`. |
| `config.embeddingModel` | `nomic-embed-text` | Must match `ollama.models.embedding`. |
| `config.secretKey` | `""` | Flask `SECRET_KEY`. Generated on first install and preserved across upgrades when left empty — but see the GitOps note below. |
| `config.debug` | `false` | |
| `config.existingSecret` | `""` | Supply `llm-api-key` and `flask-secret-key` yourself. |
| `config.existingSecretLlmApiKeyKey` | `llm-api-key` | |
| `config.existingSecretFlaskSecretKeyKey` | `flask-secret-key` | |

### `ingress`, `networkPolicy`, `tests`

| Key | Default | Description |
|---|---|---|
| `ingress.enabled` | `false` | |
| `ingress.className` / `.annotations` / `.hosts` / `.tls` | | Standard. Set a 50m body-size annotation to match the backend's upload limit. |
| `ingress.separateApiPath` | `false` | Route `/api` straight to the API Service. Off by default because the web container already proxies `/api`, which keeps `kubectl port-forward` working identically. |
| `networkPolicy.enabled` | `false` | Restricts each component to the flows it actually needs. |
| `networkPolicy.ingressControllerSelector` | `{}` | Who may reach the web tier. Empty means any namespace. |
| `networkPolicy.allowOllamaEgress` | `true` | Ollama needs egress to download models unless the volume is pre-seeded. |
| `tests.enabled` | `true` | Render the `helm test` pod. |
| `tests.image.*` | `docker.io/curlimages/curl:8.21.0` | |

## Scenario files

`ci/` holds working values files for the shapes this chart supports; each one is rendered and schema-validated in CI.

| File | Use |
|---|---|
| `default-values.yaml` | Chart defaults. |
| `gpu-values.yaml` | Ollama on a GPU node pool. |
| `small-model-values.yaml` | CPU-only, `qwen2.5:7b`, laptop-scale cluster. |
| `ingress-values.yaml` | Ingress with TLS and a separate `/api` rule. |
| `hardened-values.yaml` | Network policies, autoscaling, external secrets, private registry. |
| `ephemeral-values.yaml` | No persistence, no model pull — smoke tests. |

## Testing an install

```bash
helm test <release> --namespace <ns> --logs
```

Checks the API health endpoint, the web health endpoint, the nginx-to-API proxy path, and that Ollama is answering and reporting its models.

## Deploying through Argo CD or Flux

GitOps tools render with `helm template`, where the chart cannot read the previously stored Flask `SECRET_KEY` back out of the cluster. Left to itself it would mint a new key on every reconcile and invalidate sessions each time. Set one explicitly:

```yaml
config:
  existingSecret: mirofish-app-secrets   # preferred
  # or
  secretKey: "<a long random string>"
```

The same applies to `neo4j.auth.password`, which should come from `neo4j.auth.existingSecret` in any environment you care about.
