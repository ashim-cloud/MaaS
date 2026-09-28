{{/*
=============================================================================
Grafana Helm Chart — Helper Templates (_helpers.tpl)
=============================================================================
*/}}

{{/*
Chart name, truncated to 63 chars (Kubernetes name limit).
*/}}
{{- define "grafana.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
Uses the release name directly (not release-chart) to keep resource names
short and predictable.
Truncated to 63 chars for Kubernetes name compliance.
*/}}
{{- define "grafana.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard Helm metadata labels applied to every resource.
*/}}
{{- define "grafana.labels" -}}
helm.sh/chart: {{ printf "%s-%s" (include "grafana.name" .) .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.grafana.image.tag | quote }}
app.kubernetes.io/part-of: zabbix
app.kubernetes.io/component: grafana
{{- end -}}

{{/* -----------------------------------------------------------------------
   Resource Name Helpers
   ----------------------------------------------------------------------- */}}

{{/* Grafana Deployment + Service name: "grafana" */}}
{{- define "grafana.deploymentName" -}}
{{- printf "%s" (include "grafana.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Grafana ServiceAccount name: "grafana-sa" */}}
{{- define "grafana.serviceAccountName" -}}
{{- printf "%s-sa" (include "grafana.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Grafana Ingress name: "grafana-ingress" */}}
{{- define "grafana.ingressName" -}}
{{- printf "%s-ingress" (include "grafana.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Image Tag Helper
   ----------------------------------------------------------------------- */}}
{{- define "grafana.image" -}}
{{- printf "%s:%s" .Values.grafana.image.repository .Values.grafana.image.tag -}}
{{- end -}}
