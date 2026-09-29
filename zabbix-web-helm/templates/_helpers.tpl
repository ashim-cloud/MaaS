{{/*
=============================================================================
Zabbix Web Helm Chart — Helper Templates (_helpers.tpl)
=============================================================================
*/}}

{{/*
Chart name, truncated to 63 chars (Kubernetes name limit).
*/}}
{{- define "zabbix-web.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
Uses the release name directly (not release-chart) to keep resource names
short and predictable. If release name = "zabbix", resource names match
the original manually-tested manifests exactly.
Truncated to 63 chars for Kubernetes name compliance.
*/}}
{{- define "zabbix-web.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard Helm metadata labels applied to every resource.
*/}}
{{- define "zabbix-web.labels" -}}
helm.sh/chart: {{ printf "%s-%s" (include "zabbix-web.name" .) .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.zabbix.version | quote }}
app.kubernetes.io/part-of: zabbix
app.kubernetes.io/component: web
{{- end -}}

{{/* -----------------------------------------------------------------------
   Resource Name Helpers
   Each produces a deterministic name from the release name.
   With release name "zabbix", these match the original manifest names.
   ----------------------------------------------------------------------- */}}

{{/* Web Deployment + ClusterIP Service name: "zabbix-web" */}}
{{- define "zabbix-web.deploymentName" -}}
{{- printf "%s-web" (include "zabbix-web.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Web ServiceAccount name: "zabbix-web-sa" — used for EKS Pod Identity */}}
{{- define "zabbix-web.serviceAccountName" -}}
{{- printf "%s-web-sa" (include "zabbix-web.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Web Ingress name: "zabbix-web-ingress" */}}
{{- define "zabbix-web.ingressName" -}}
{{- printf "%s-web-ingress" (include "zabbix-web.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Web HPA name: same as deployment name for clarity */}}
{{- define "zabbix-web.hpaName" -}}
{{- printf "%s-web" (include "zabbix-web.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Zabbix Server Service Name
   The web frontend connects to the Zabbix Server via this service name.
   Defaults to zabbixServer.serviceName in values.yaml.
   ----------------------------------------------------------------------- */}}
{{- define "zabbix-web.serverServiceName" -}}
{{- .Values.zabbixServer.serviceName -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Image Tag Helper
   Compose image reference from global zabbix.baseImage + zabbix.version.
   Example: zabbix/zabbix-web-nginx-pgsql:ubuntu-7.0.30
   ----------------------------------------------------------------------- */}}
{{- define "zabbix-web.image" -}}
{{- printf "%s:%s-%s" .Values.zabbixWeb.image.repository .Values.zabbix.baseImage .Values.zabbix.version -}}
{{- end -}}


