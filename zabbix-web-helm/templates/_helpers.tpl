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
   Pod names follow the pattern: <release>-<hash> (Deployment).
   ----------------------------------------------------------------------- */}}

{{/* Web Deployment + ClusterIP Service + HPA name — uses the release name directly.
   With release "zabbix-web", Deployment is "zabbix-web", pods are "zabbix-web-<hash>". */}}
{{- define "zabbix-web.deploymentName" -}}
{{- include "zabbix-web.fullname" . -}}
{{- end -}}

{{/* Web ServiceAccount name — fixed, not derived from release name. */}}
{{- define "zabbix-web.serviceAccountName" -}}
zabbix-web-sa
{{- end -}}

{{/* Web Ingress name: "<release>-ingress" */}}
{{- define "zabbix-web.ingressName" -}}
{{- printf "%s-ingress" (include "zabbix-web.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Web HPA name: same as deployment name for clarity */}}
{{- define "zabbix-web.hpaName" -}}
{{- include "zabbix-web.fullname" . -}}
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


