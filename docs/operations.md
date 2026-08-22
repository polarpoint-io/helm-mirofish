# Operations

## Upgrading the chart

```bash
helm upgrade mirofish oci://ghcr.io/polarpoint-io/charts/mirofish-offline \
  --namespace mirofish --reuse-values --version <new-version>
```

What happens:

- The API uses a `Recreate` strategy, so it goes down while the new pod starts — its volume is `ReadWriteOnce` and cannot be held by two pods. Expect a gap of a minute or two.
- The web tier rolls normally.
- Neo4j and Ollama restart in place, keeping their volumes.
- A new model-pull Job is created, named for the new revision. If the models are already on the volume it finishes in seconds.

Run an in-flight simulation to completion before upgrading; restarting the API kills its simulation subprocesses.

## Upgrading the application

Application versions are pinned by `UPSTREAM_REF` in this repo, not by the chart:

```bash
make upstream-latest       # repin to upstream HEAD
make relock                # regenerate docker/backend-uv.lock for that ref
make check-lock            # sanity check
git commit -am "build: repin upstream to $(cat UPSTREAM_REF)"
git push
```

The relock step is not optional. Upstream's own `backend/uv.lock` is stale and cannot be installed from; this repo vendors a regenerated one, and the image build asserts it still matches upstream's `pyproject.toml`.

Pushing to `main` builds and publishes new images. Then bump `appVersion` in `Chart.yaml`, tag `chart-v<version>`, and the release workflow publishes the chart.

## Backup

The uploads volume is the only irreplaceable data — it holds uploaded documents, generated personas, simulation output and reports.

```bash
kubectl exec -n mirofish deploy/mirofish-mirofish-offline-api -- \
  tar czf - -C /app/backend uploads > mirofish-uploads-$(date +%F).tar.gz
```

Neo4j, using its own dump tool while the database is stopped:

```bash
kubectl scale -n mirofish statefulset/mirofish-mirofish-offline-neo4j --replicas=0
# attach a job to the data PVC and run: neo4j-admin database dump neo4j --to-path=/backup
kubectl scale -n mirofish statefulset/mirofish-mirofish-offline-neo4j --replicas=1
```

A live `cp` of `/data` while Neo4j is running produces an inconsistent copy. Do not rely on volume snapshots taken mid-write either, unless your CSI driver quiesces the filesystem.

The Ollama volume needs no backup — it is a cache of re-downloadable weights.

## Troubleshooting

### API pod stuck in Init

The init container is waiting on Neo4j.

```bash
kubectl logs -n mirofish deploy/mirofish-mirofish-offline-api -c wait-for-neo4j
kubectl logs -n mirofish sts/mirofish-mirofish-offline-neo4j
```

Common cause: wrong password. Neo4j ignores `NEO4J_AUTH` once its volume is initialised, so the Secret must match what the database was *first* created with. APOC is bundled in the image and copied into place by the entrypoint, so it is not a source of startup delay; a slow first boot is store initialisation or recovery.

If the password was changed after first install, either reset it inside Neo4j or delete the data PVC and start clean.

### Graph queries behave oddly, or "Schema query warning" in the API logs

`create_app()` creates the Neo4j indexes and constraints at startup. If Neo4j was unreachable then, those queries are logged as warnings and skipped — the API still starts, but the graph has no schema. Restart it once Neo4j is healthy:

```bash
kubectl logs -n mirofish deploy/mirofish-mirofish-offline-api | grep -i "schema query warning"
kubectl rollout restart -n mirofish deploy/mirofish-mirofish-offline-api
```

The init container normally prevents this; it only shows up if Neo4j was restarted or repaired underneath a running API pod.

### "model not found"

The pull Job has not finished, or the model names disagree.

```bash
kubectl logs -n mirofish -l app.kubernetes.io/component=ollama-model-pull --tail=50
kubectl exec -n mirofish sts/mirofish-mirofish-offline-ollama -- ollama list
```

Confirm `config.llmModel` matches `ollama.models.chat` exactly, tag included.

### Simulations are extremely slow

Check whether the GPU is actually in use:

```bash
kubectl exec -n mirofish sts/mirofish-mirofish-offline-ollama -- nvidia-smi
kubectl describe pod -n mirofish -l app.kubernetes.io/component=ollama | grep -A3 Limits
```

No `nvidia.com/gpu` in the limits means it is on CPU. Check that the device plugin is installed and that the pod's nodeSelector and tolerations match your GPU node pool.

### Uploads fail at around 10MB

The ingress controller's body-size limit, not the app's — the backend allows 50MB.

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
```

### Ontology generation times out

Long LLM calls hitting an intermediate timeout. The chart already sets gunicorn to 600s and nginx to 600s; the ingress controller needs telling too:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
```

### API pod OOMKilled

Simulations with many agents hold a lot in memory.

```yaml
api:
  resources:
    limits:
      memory: 8Gi
```

Reducing the agent count and round count when starting a simulation also helps; both are chosen in the UI, not in the chart.

## Useful commands

```bash
# What is running
kubectl get all -n mirofish

# API logs
kubectl logs -n mirofish -l app.kubernetes.io/component=api -f --tail=200

# Neo4j shell
kubectl exec -it -n mirofish sts/mirofish-mirofish-offline-neo4j -- \
  cypher-shell -u neo4j -p "$(kubectl get secret -n mirofish mirofish-mirofish-offline-secrets -o jsonpath='{.data.neo4j-password}' | base64 -d)"

# What Ollama has loaded
kubectl exec -n mirofish sts/mirofish-mirofish-offline-ollama -- ollama ps

# Re-run the health checks
helm test mirofish -n mirofish --logs
```
