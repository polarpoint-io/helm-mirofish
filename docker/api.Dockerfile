# syntax=docker/dockerfile:1.7
#
# MiroFish-Offline API (Flask backend) — production image.
#
# Build context is THIS repo, with the upstream MiroFish-Offline source tree
# vendored at ./upstream (see `make upstream`, which clones the commit pinned
# in ./UPSTREAM_REF):
#
#   make upstream
#   docker build -f docker/api.Dockerfile -t mirofish-api .
#
# Unlike upstream's single dev-mode image (`npm run dev`, Flask debug server),
# this ships only the backend and serves it through gunicorn.

ARG PYTHON_VERSION=3.11
ARG UV_VERSION=0.9.26

# A variable is only expanded in an image reference on a FROM line, never in
# a `COPY --from=` stage name -- BuildKit resolves those before build args and
# rejects the literal "${UV_VERSION}". Naming the stage here is what makes the
# version a single ARG rather than a hardcoded tag in two places.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# --------------------------------------------------------------------------
# Builder — resolve the locked dependency set into /app/backend/.venv
# --------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS builder

COPY --from=uv /uv /uvx /bin/

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend

# Dependency layer first so source edits do not invalidate the install.
#
# Upstream's own backend/uv.lock is stale: it is the pre-fork lock, still
# naming the project mirofish-backend 0.1.0 and still carrying zep-cloud,
# which this fork removed. `uv sync` against it fails outright with
# "Missing workspace member `mirofish-offline-backend`". So the lock is
# regenerated in this repo (`make relock`) and vendored at
# docker/backend-uv.lock. `--locked` then asserts it still matches the
# upstream pyproject.toml, so repinning UPSTREAM_REF to a commit that
# changed dependencies fails the build loudly instead of silently
# installing the wrong tree.
COPY upstream/backend/pyproject.toml ./pyproject.toml
COPY docker/backend-uv.lock ./uv.lock
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-install-project --no-dev

# The application is imported from the working directory rather than installed
# into the venv (gunicorn puts --chdir on sys.path), so only the sources are
# copied. Upstream's stale lock ships inside backend/; keep ours authoritative.
COPY upstream/backend/ ./
COPY docker/backend-uv.lock ./uv.lock

# gunicorn is a deployment concern, not an upstream dependency, so it is
# pinned here rather than added to the lockfile.
#
# This MUST come after the last `uv sync`. uv sync is exact by default and
# prunes anything absent from the lockfile, so installing gunicorn earlier
# would leave the runtime image without the binary its CMD invokes.
ARG GUNICORN_VERSION=26.1.0
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --python /app/backend/.venv "gunicorn==${GUNICORN_VERSION}"

# Fail the build here rather than in a CrashLooping pod.
RUN /app/backend/.venv/bin/gunicorn --version \
 && /app/backend/.venv/bin/python -c "import flask, neo4j, openai, fitz, oasis, camel; print('imports ok')"

# --------------------------------------------------------------------------
# Runtime
# --------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/backend/.venv/bin:${PATH}" \
    FLASK_DEBUG=false \
    FLASK_HOST=0.0.0.0 \
    FLASK_PORT=5001

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 --shell /usr/sbin/nologin mirofish

WORKDIR /app/backend

COPY --from=builder --chown=10001:10001 /app/backend /app/backend

# Uploaded documents, generated reports and OASIS simulation output all land
# under uploads/. The chart mounts a PersistentVolumeClaim over it.
#
# logs/ must exist and be writable before the first import: upstream's
# app/utils/logger.py runs setup_logger() at module scope and hardcodes
# LOG_DIR to <backend>/logs with no env override, so a missing or unwritable
# directory kills the worker during `app:create_app()` rather than degrading
# to console-only logging.
#
# Creating it here is not enough on its own -- WORKDIR made /app/backend as
# root, and `COPY --chown` only relabels what it copies, not a destination
# directory that already exists. So /app/backend itself stays root-owned and
# uid 10001 cannot mkdir inside it. Both the directory and its parent are
# handed over explicitly.
RUN mkdir -p /app/backend/uploads/projects \
             /app/backend/uploads/reports \
             /app/backend/uploads/simulations \
             /app/backend/logs \
 && chown 10001:10001 /app/backend \
 && chown -R 10001:10001 /app/backend/uploads /app/backend/logs

USER 10001

# Fail the build here rather than in a CrashLooping pod. Both directories are
# written to before the app finishes importing.
RUN test -w /app/backend/logs && test -w /app/backend/uploads

EXPOSE 5001

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${FLASK_PORT:-5001}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

# One worker only: simulation subprocesses and task/progress state are held in
# the serving process, so the API cannot be spread across workers or replicas.
# Concurrency comes from threads. The long timeout accommodates ontology
# generation and report LLM calls, which upstream allows up to 5 minutes.
# Shell form so FLASK_PORT (set by the chart from api.service.port) actually
# reaches the bind address; `exec` keeps gunicorn as PID 1 under tini so it
# still receives SIGTERM. GUNICORN_THREADS and GUNICORN_TIMEOUT are tunable
# through api.extraEnv without overriding the whole command.
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${FLASK_PORT:-5001} --workers 1 --worker-class gthread --threads ${GUNICORN_THREADS:-16} --timeout ${GUNICORN_TIMEOUT:-600} --graceful-timeout 60 --keep-alive 10 --access-logfile - --error-logfile - 'app:create_app()'"]
