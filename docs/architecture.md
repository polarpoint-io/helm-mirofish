# Architecture

## What upstream ships, and why this chart differs

Upstream's `Dockerfile` builds one image that runs `npm run dev`: the Vite dev server on 3000 and the Flask debug server on 5001, started together by `concurrently`. That is right for a laptop and wrong for a cluster — the dev server rebuilds on file change, the Flask debug server is single-threaded with the reloader attached, and a single container binding two ports cannot be scaled or probed independently.

This repository builds two images instead:

| | Upstream | Here |
|---|---|---|
| Backend | Flask debug server, `FLASK_DEBUG=True` | gunicorn, `gthread` worker, 600s timeout |
| Frontend | Vite dev server on :3000, dev proxy to :5001 | Static build served by nginx on :8080, nginx proxies `/api` |
| Process model | Both in one container | Two Deployments, probed and scaled separately |
| User | root | uid 10001 (api), uid 101 (web) |

The application code is unmodified. The only build-time change is `VITE_API_BASE_URL=/`, which makes the frontend emit same-origin `/api/...` paths instead of hard-coding `http://localhost:5001`.

## Component map

```
                     ┌────────────────────────────────────────┐
   ingress ─────────▶│ web        nginx :8080                 │
   (optional)        │            /        → SPA (static)     │
                     │            /api/*   → API Service      │
                     │            /healthz → 200 (local)      │
                     └──────────────────┬─────────────────────┘
                                        │ :5001
                     ┌──────────────────▼─────────────────────┐
                     │ api        gunicorn :5001              │
                     │            /api/graph/*                │
                     │            /api/simulation/*           │
                     │            /api/report/*               │
                     │            /health                     │
                     │  volume:   /app/backend/uploads (PVC)  │
                     └───────┬──────────────────────┬─────────┘
                    bolt:7687│                      │http:11434
              ┌──────────────▼──────┐   ┌───────────▼─────────────┐
              │ neo4j               │   │ ollama                  │
              │  entities, relations│   │  chat + embedding models│
              │  agent memory       │   │  optional GPU           │
              │  volume: /data (PVC)│   │  volume: /root/.ollama  │
              └─────────────────────┘   └───────────▲─────────────┘
                                                    │
                                        ┌───────────┴─────────────┐
                                        │ model-pull Job          │
                                        │  POST /api/pull per model│
                                        └─────────────────────────┘
```

## Why nothing except the web tier scales

**The API holds state in the serving process.** `SimulationRunner` forks OASIS simulation workers and tracks them in process memory; `/api/simulation/prepare/status` reads task progress from the same place. A second replica would answer status queries about work it never started. The chart rejects `api.replicaCount > 1` at render time rather than letting that fail confusingly at runtime, and uses a `Recreate` strategy so the old pod releases the `ReadWriteOnce` uploads volume before the new one claims it.

Concurrency within the one pod comes from gunicorn's `gthread` worker with 16 threads, which suits a workload dominated by waiting on LLM calls.

**Neo4j Community Edition does not cluster.** Clustering is an Enterprise feature. The StatefulSet is fixed at one replica.

**Ollama's weights live on a `ReadWriteOnce` volume.** Two replicas would need two copies of a 20GB model and two GPUs, with no shared scheduling between them. Scale by giving the one pod a larger GPU.

**The web tier is stateless**, so it gets replicas, an optional HPA and an optional PodDisruptionBudget.

## Request paths

The SPA always calls same-origin `/api/...`. nginx in the web pod proxies those to the API Service. This holds whether traffic arrives through an Ingress, a LoadBalancer, or `kubectl port-forward`, which means a port-forward is a complete, working deployment rather than a half-broken one.

`ingress.separateApiPath` adds an Ingress rule sending `/api` straight to the API Service, bypassing nginx. It is off by default: it makes the port-forward path behave differently from the ingress path for no gain in a deployment this size.

Two settings matter for long requests. Ontology generation and report agent runs can take minutes; the frontend's axios client allows 300 seconds. nginx is configured with a 600s read timeout and buffering disabled so log-streaming endpoints work. An ingress controller in front will need matching annotations — `ci/ingress-values.yaml` shows them for ingress-nginx.

## Startup ordering

The API's `create_app()` constructs a `Neo4jStorage` singleton at startup, and that constructor is where the graph schema — indexes and constraints — gets created. If Neo4j is unreachable at that moment the failure is not fatal: the connection object is built anyway and the schema queries are logged as warnings and skipped. The pod then serves happily with no indexes, and graph queries degrade later in ways that look like application bugs.

So the API pod runs an init container that blocks on `cypher-shell ... RETURN 1` until Neo4j answers, using the Neo4j image so no extra tooling is needed. If a restart is ever needed after Neo4j comes up late, `kubectl rollout restart` re-runs schema creation.

Ollama is treated differently. It is not required at startup, only when a simulation runs, so the API does not wait for it. The model-pull Job waits for `/api/version` itself.

## The model-pull Job

Models are pulled by a Job that POSTs to Ollama's `/api/pull`, rather than by `helm install --wait` or a Helm hook. A hook would make `helm install` block for however long a 20GB download takes, which breaks CI timeouts and GitOps reconciliation loops.

The Job name carries `.Release.Revision`, so an upgrade creates a new Job rather than failing on a Job's immutable fields; `ttlSecondsAfterFinished` cleans up the old ones. Because `/api/pull` returns 200 with an error embedded in its streamed body, the Job follows each pull with an `/api/show` call and fails if the model is not actually resident.

## Secrets

Two Secrets' worth of material, in one Secret by default:

| Key | Consumed by |
|---|---|
| `neo4j-password` | Neo4j (composed into `NEO4J_AUTH` at container start), API, API init container |
| `llm-api-key` | API, as both `LLM_API_KEY` and `OPENAI_API_KEY` |
| `flask-secret-key` | API, as `SECRET_KEY` |

`NEO4J_AUTH` wants a single `user/password` string, but a user-supplied Secret holds only the password. Rather than templating the password into a manifest, the Neo4j container composes the two at start:

```sh
export NEO4J_AUTH="${DB_USER}/${DB_PASSWORD}"
exec tini -g -- /startup/docker-entrypoint.sh neo4j
```

The Flask `SECRET_KEY` is generated on first install and then read back from the live Secret on every subsequent render, so upgrades do not silently invalidate sessions. Setting `config.secretKey` explicitly overrides both behaviours.

## Data and durability

| Volume | Contents | Recovery if lost |
|---|---|---|
| `api` uploads | Uploaded documents, generated personas, simulation output, reports | None — this is the user's work. PVC is annotated `helm.sh/resource-policy: keep`. |
| `neo4j` data | Entities, relationships, agent memory | Rebuildable by re-running graph build, if the source documents survive. |
| `ollama` models | Model weights | Re-downloadable, slowly. |

Uninstalling the release leaves the uploads PVC behind deliberately. Delete it by hand if you mean it.
