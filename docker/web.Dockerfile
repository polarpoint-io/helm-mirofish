# syntax=docker/dockerfile:1.7
#
# MiroFish-Offline web (Vue 3 / Vite frontend) — production image.
#
# Build context is THIS repo, with the upstream MiroFish-Offline source tree
# vendored at ./upstream (see `make upstream`):
#
#   make upstream
#   docker build -f docker/web.Dockerfile -t mirofish-web .
#
# The frontend is compiled to static assets and served by nginx, which also
# reverse-proxies /api and /health to the API Service. Upstream instead runs
# the Vite dev server with its dev-time proxy.

ARG NODE_VERSION=22
ARG NGINX_VERSION=1.31.4

# --------------------------------------------------------------------------
# Builder
# --------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS builder

WORKDIR /app

COPY upstream/frontend/package.json upstream/frontend/package-lock.json ./
RUN npm ci

COPY upstream/frontend/ ./

# upstream/frontend/src/api/index.js falls back to http://localhost:5001 when
# this is unset. "/" makes axios emit same-origin relative paths (/api/...),
# which nginx proxies on to the API Service.
ARG VITE_API_BASE_URL=/
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}

RUN npm run build

# --------------------------------------------------------------------------
# Runtime — unprivileged nginx, listening on 8080 as a non-root user
# --------------------------------------------------------------------------
FROM nginxinc/nginx-unprivileged:${NGINX_VERSION}-alpine AS runtime

# Where nginx forwards API traffic. The chart overrides this with the
# in-cluster API Service address, so it can change without a rebuild.
ENV API_UPSTREAM=http://mirofish-offline-api:5001 \
    NGINX_LISTEN_PORT=8080 \
    NGINX_ENVSUBST_FILTER="^(API_UPSTREAM|NGINX_LISTEN_PORT)$"

COPY --from=builder /app/dist /usr/share/nginx/html

# Rendered by the base image's envsubst entrypoint at container start.
COPY docker/nginx-default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${NGINX_LISTEN_PORT:-8080}/healthz" || exit 1
