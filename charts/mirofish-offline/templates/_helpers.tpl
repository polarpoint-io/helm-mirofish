{{/* vim: set filetype=mustache: */}}

{{- define "mirofish.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mirofish.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mirofish.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels applied to every object. */}}
{{- define "mirofish.labels" -}}
helm.sh/chart: {{ include "mirofish.chart" . }}
{{ include "mirofish.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mirofish-offline
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "mirofish.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mirofish.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Per-component labels. Usage: include "mirofish.componentLabels" (dict "ctx" $ "component" "api") */}}
{{- define "mirofish.componentLabels" -}}
{{ include "mirofish.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "mirofish.componentSelectorLabels" -}}
{{ include "mirofish.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "mirofish.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "mirofish.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Resolve an image reference.
Usage: include "mirofish.image" (dict "ctx" $ "image" .Values.api.image "defaultTag" .Chart.AppVersion)
*/}}
{{- define "mirofish.image" -}}
{{- $img := .image -}}
{{- $registry := default $img.registry .ctx.Values.global.imageRegistry -}}
{{- if .ctx.Values.global.imageRegistry -}}
{{- $registry = .ctx.Values.global.imageRegistry -}}
{{- end -}}
{{- $repo := $img.repository -}}
{{- if and (hasKey $img "digest") $img.digest -}}
{{- if $registry -}}{{ printf "%s/%s@%s" $registry $repo $img.digest }}{{- else -}}{{ printf "%s@%s" $repo $img.digest }}{{- end -}}
{{- else -}}
{{- $tag := default (default "latest" .defaultTag) $img.tag -}}
{{- if $registry -}}{{ printf "%s/%s:%s" $registry $repo $tag }}{{- else -}}{{ printf "%s:%s" $repo $tag }}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mirofish.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ if kindIs "string" . }}{{ . }}{{ else }}{{ .name }}{{ end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Append a suffix to a name, keeping the result inside the 63-character DNS
label limit. Truncating the whole thing afterwards would eat the suffix --
which is what makes the name unique -- so the base is shortened instead.
Usage: include "mirofish.suffixed" (dict "base" $someName "suffix" "headless")
*/}}
{{- define "mirofish.suffixed" -}}
{{- $suffix := .suffix -}}
{{- $room := int (sub 62 (len $suffix)) -}}
{{- printf "%s-%s" (trunc $room .base | trimSuffix "-") $suffix -}}
{{- end -}}

{{/* Component object names */}}
{{- define "mirofish.api.fullname"    -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" "api")    }}{{- end -}}
{{- define "mirofish.web.fullname"    -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" "web")    }}{{- end -}}
{{- define "mirofish.neo4j.fullname"  -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" "neo4j")  }}{{- end -}}
{{- define "mirofish.ollama.fullname" -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" "ollama") }}{{- end -}}

{{/*
Two-part suffixes are built against the release fullname, never by nesting one
suffixed name inside another. Nesting truncates the base twice, and the second
pass can shave off the component word that made the names differ -- e.g.
"...-neo4j" and "...-ollama" both collapsing to the same "...-headless".
*/}}
{{- define "mirofish.neo4j.headlessName"  -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" "neo4j-headless")  }}{{- end -}}
{{- define "mirofish.ollama.headlessName" -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" "ollama-headless") }}{{- end -}}
{{- define "mirofish.api.pvcName"         -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" "api-uploads")     }}{{- end -}}
{{- define "mirofish.configMapName"       -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .)        "suffix" "config")   }}{{- end -}}
{{- define "mirofish.ownSecretName"       -}}{{ include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .)        "suffix" "secrets")  }}{{- end -}}

{{/* The revision suffix is what keeps each upgrade's Job distinct, so it must survive truncation. */}}
{{- define "mirofish.modelPullJobName" -}}
{{- include "mirofish.suffixed" (dict "base" (include "mirofish.fullname" .) "suffix" (printf "ollama-model-pull-%d" (int .Release.Revision))) -}}
{{- end -}}

{{/* In-cluster endpoints */}}
{{- define "mirofish.neo4j.uri" -}}
{{- printf "bolt://%s:%v" (include "mirofish.neo4j.fullname" .) .Values.neo4j.service.boltPort -}}
{{- end -}}

{{- define "mirofish.ollama.url" -}}
{{- printf "http://%s:%v" (include "mirofish.ollama.fullname" .) .Values.ollama.service.port -}}
{{- end -}}

{{- define "mirofish.api.url" -}}
{{- printf "http://%s:%v" (include "mirofish.api.fullname" .) .Values.api.service.port -}}
{{- end -}}

{{- define "mirofish.secretName" -}}
{{- default (include "mirofish.ownSecretName" .) .Values.config.existingSecret -}}
{{- end -}}

{{- define "mirofish.neo4j.secretName" -}}
{{- default (include "mirofish.ownSecretName" .) .Values.neo4j.auth.existingSecret -}}
{{- end -}}

{{- define "mirofish.neo4j.secretPasswordKey" -}}
{{- if .Values.neo4j.auth.existingSecret -}}
{{- .Values.neo4j.auth.existingSecretPasswordKey -}}
{{- else -}}
neo4j-password
{{- end -}}
{{- end -}}

{{- define "mirofish.secretLlmApiKeyKey" -}}
{{- if .Values.config.existingSecret -}}
{{- .Values.config.existingSecretLlmApiKeyKey -}}
{{- else -}}
llm-api-key
{{- end -}}
{{- end -}}

{{- define "mirofish.secretFlaskKeyKey" -}}
{{- if .Values.config.existingSecret -}}
{{- .Values.config.existingSecretFlaskSecretKeyKey -}}
{{- else -}}
flask-secret-key
{{- end -}}
{{- end -}}

{{/*
Flask SECRET_KEY. An explicit config.secretKey wins; otherwise reuse the value
already stored in the Secret so upgrades do not invalidate sessions, and only
generate a fresh one on first install.

`lookup` returns nothing under `helm template`, which is how Argo CD and Flux
render. Under those tools this generates a new key on every reconcile, so set
config.secretKey or config.existingSecret when deploying via GitOps.
*/}}
{{- define "mirofish.flaskSecretKey" -}}
{{- if .Values.config.secretKey -}}
{{- .Values.config.secretKey -}}
{{- else -}}
{{- $name := include "mirofish.ownSecretName" . -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- if and $existing $existing.data (index $existing.data "flask-secret-key") -}}
{{- index $existing.data "flask-secret-key" | b64dec -}}
{{- else -}}
{{- randAlphaNum 48 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Common pod-level image pull secret + service account block */}}
{{- define "mirofish.podCommon" -}}
{{- include "mirofish.imagePullSecrets" .ctx }}
serviceAccountName: {{ include "mirofish.serviceAccountName" .ctx }}
automountServiceAccountToken: {{ .ctx.Values.serviceAccount.automountServiceAccountToken }}
{{- end -}}

{{/* Fail fast on values combinations that cannot work. */}}
{{- define "mirofish.validateValues" -}}
{{- if gt (int .Values.api.replicaCount) 1 -}}
{{- fail "api.replicaCount must be 1: simulation subprocesses and task progress live in the serving process, and uploads/ is a ReadWriteOnce volume." -}}
{{- end -}}
{{- if and (not .Values.neo4j.auth.existingSecret) (lt (len .Values.neo4j.auth.password) 8) -}}
{{- fail "neo4j.auth.password must be at least 8 characters, or set neo4j.auth.existingSecret." -}}
{{- end -}}
{{- if and .Values.ollama.gpu.enabled (lt (int .Values.ollama.gpu.count) 1) -}}
{{- fail "ollama.gpu.count must be >= 1 when ollama.gpu.enabled is true." -}}
{{- end -}}
{{- if lt (int .Values.web.service.targetPort) 1024 -}}
{{- fail "web.service.targetPort must be >= 1024: the web image runs nginx as an unprivileged user, which cannot bind a privileged port." -}}
{{- end -}}
{{- end -}}
