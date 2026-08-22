# Configuration

The full values reference lives in the [chart README](../charts/mirofish-offline/README.md). This page covers the changes people actually make.

## Changing the model

Two values must move together — one decides what Ollama downloads, the other what the application requests:

```yaml
ollama:
  models:
    chat: qwen2.5:14b
config:
  llmModel: qwen2.5:14b
```

The same pairing applies to embeddings (`ollama.models.embedding` / `config.embeddingModel`). Changing the embedding model after a graph has been built invalidates the stored vectors — rebuild the graph rather than expecting search to keep working.

To run several models and switch between them, list the extras:

```yaml
ollama:
  models:
    chat: qwen2.5:14b
    extra: ["llama3.1:8b", "mistral:7b"]
```

## Pre-seeding models instead of downloading them

If cluster egress is restricted, point the Ollama volume at a pre-populated PVC and disable the pull Job:

```yaml
ollama:
  modelPull:
    enabled: false
  persistence:
    storageClass: my-preseeded-class
networkPolicy:
  allowOllamaEgress: false
```

Or load them by hand after install:

```bash
kubectl exec -n mirofish sts/mirofish-mirofish-offline-ollama -- ollama pull qwen2.5:7b
```

## Making simulations shorter

Not a chart setting. Rounds dominate runtime — each round is one LLM call per agent — and both round count and agent count are chosen per simulation in the UI.

Upstream's `Config` class does read `OASIS_DEFAULT_MAX_ROUNDS` and the `REPORT_AGENT_*` variables, but nothing consumes them: rounds come from the request, and `report_agent.py` uses hardcoded class constants. The chart deliberately does not expose them as values rather than offer settings that quietly do nothing. If a future upstream version starts honouring them, set them through `api.extraEnv`:

```yaml
api:
  extraEnv:
    - name: OASIS_DEFAULT_MAX_ROUNDS
      value: "3"
```

The one lever that does work today is the model — a smaller model finishes each call faster.

## Inference throughput

Ollama's concurrency is set in the StatefulSet: `OLLAMA_NUM_PARALLEL=4`, `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KEEP_ALIVE=30m`. Raise parallelism only if VRAM allows — each concurrent request needs its own KV cache.

```yaml
ollama:
  extraEnv:
    - name: OLLAMA_NUM_PARALLEL
      value: "8"
```

`OLLAMA_KEEP_ALIVE` keeps the chat model resident between rounds. Lowering it frees VRAM at the cost of reloading the model constantly, which is almost always the wrong trade during a simulation.

## Storage

```yaml
api:
  persistence:
    size: 50Gi          # documents, personas, simulation output, reports
neo4j:
  persistence:
    size: 100Gi
ollama:
  persistence:
    size: 200Gi         # sized for the models you pull
global:
  storageClass: fast-ssd
```

Neo4j and Ollama volumes come from StatefulSet claim templates, which Kubernetes will not resize in place. Growing them means either a StorageClass with `allowVolumeExpansion` and editing the PVCs directly, or recreating the StatefulSet with `--cascade=orphan`.

## Neo4j memory

Keep heap plus page cache below the container memory limit, with headroom for the JVM itself:

```yaml
neo4j:
  heap:
    initialSize: 2g
    maxSize: 4g
  pagecache:
    size: 4g
  resources:
    limits:
      memory: 12Gi
```

Page cache is what makes graph traversal fast; give it whatever is left after heap.

## Network policies

`networkPolicy.enabled: true` restricts each component to the flows it needs: the web tier accepts traffic from your ingress controller and talks only to the API; the API talks only to Neo4j and Ollama; Neo4j and Ollama accept traffic only from within the release.

```yaml
networkPolicy:
  enabled: true
  ingressControllerSelector:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: ingress-nginx
  allowOllamaEgress: true   # false only if models are pre-seeded
```

Leaving `ingressControllerSelector` empty accepts web traffic from any namespace, which is permissive — set it.

## Flask secret key

Left empty, `config.secretKey` is generated on first install and read back from the live Secret on subsequent `helm upgrade` runs. That read uses Helm's `lookup`, which returns nothing under `helm template` — the mode Argo CD and Flux use — so under GitOps a new key would be minted on every reconcile. Set `config.existingSecret` (or `config.secretKey`) in those environments.

## Private registries

```yaml
global:
  imageRegistry: registry.internal.example.com
  imagePullSecrets:
    - internal-registry
```

`global.imageRegistry` overrides the registry on *every* image, including `neo4j` and `ollama/ollama`, so mirror all of them.

## Pinning by digest

For reproducible deploys:

```yaml
api:
  image:
    digest: sha256:...
web:
  image:
    digest: sha256:...
```

A digest takes precedence over `tag`. The image build workflow prints both to its job summary.
