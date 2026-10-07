{{/*
Chart name, truncated to 63 chars (the Kubernetes name limit).
*/}}
{{- define "sample-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name for all objects. If the release name already contains the chart name, use the
release name alone. With release name "sample-api" every object is named "sample-api".
*/}}
{{- define "sample-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version, used by the helm.sh/chart label.
*/}}
{{- define "sample-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels for every object.
*/}}
{{- define "sample-api.labels" -}}
helm.sh/chart: {{ include "sample-api.chart" . }}
{{ include "sample-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: kubernetes-platform-starter
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels. They are immutable on a Deployment, so keep them minimal.
*/}}
{{- define "sample-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sample-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "sample-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sample-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image reference. An empty tag falls back to the chart appVersion.
*/}}
{{- define "sample-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion | toString) }}
{{- end }}
