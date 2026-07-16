{{/*
=============================================================================
Zabbix Helm Chart — Helper Templates (_helpers.tpl)
=============================================================================
*/}}

{{/*
Chart name, truncated to 63 chars (Kubernetes name limit).
*/}}
{{- define "zabbix.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
Uses the release name directly (not release-chart) to keep resource names
short and predictable. If release name = "zabbix", resource names match
the original manually-tested manifests exactly.
Truncated to 63 chars for Kubernetes name compliance.
*/}}
{{- define "zabbix.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Target namespace — all resources use this.
*/}}
{{- define "zabbix.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}

{{/*
Standard Helm metadata labels applied to every resource.
These are additive — component-specific labels (app: zabbix-server, etc.)
are applied separately in each template to match the original manifests.
*/}}
{{- define "zabbix.labels" -}}
helm.sh/chart: {{ printf "%s-%s" (include "zabbix.name" .) .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.zabbix.version | quote }}
app.kubernetes.io/part-of: zabbix
{{- end -}}

{{/* -----------------------------------------------------------------------
   Resource Name Helpers
   Each produces a deterministic name from the release name.
   With release name "zabbix", these match the original manifest names.
   ----------------------------------------------------------------------- */}}

{{/* StatefulSet + headless Service name: "zabbix-server" */}}
{{- define "zabbix.serverName" -}}
{{- printf "%s-server" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* NLB Service name: "zabbix-server-active" */}}
{{- define "zabbix.serverActiveServiceName" -}}
{{- printf "%s-server-active" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Web Deployment + ClusterIP Service name: "zabbix-web" */}}
{{- define "zabbix.webName" -}}
{{- printf "%s-web" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Web Ingress name: "zabbix-web-ingress" */}}
{{- define "zabbix.webIngressName" -}}
{{- printf "%s-web-ingress" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Agent2 DaemonSet name: "zabbix-agent2" */}}
{{- define "zabbix.agent2Name" -}}
{{- printf "%s-agent2" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* DB Secret name: "zabbix-db-secret" */}}
{{- define "zabbix.secretName" -}}
{{- printf "%s-db-secret" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* HA sidecar ServiceAccount name: "zabbix-ha-sidecar" */}}
{{- define "zabbix.saName" -}}
{{- printf "%s-ha-sidecar" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* HA label patcher Role name: "zabbix-ha-label-patcher" */}}
{{- define "zabbix.roleName" -}}
{{- printf "%s-ha-label-patcher" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* HA label patcher RoleBinding name: "zabbix-ha-label-patcher-binding" */}}
{{- define "zabbix.roleBindingName" -}}
{{- printf "%s-ha-label-patcher-binding" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Image Tag Helpers
   Compose image references from global zabbix.baseImage + zabbix.version.
   Example: zabbix/zabbix-server-pgsql:ubuntu-7.0.27
   ----------------------------------------------------------------------- */}}

{{- define "zabbix.serverImage" -}}
{{- printf "%s:%s-%s" .Values.zabbixServer.image.repository .Values.zabbix.baseImage .Values.zabbix.version -}}
{{- end -}}

{{- define "zabbix.webImage" -}}
{{- printf "%s:%s-%s" .Values.zabbixWeb.image.repository .Values.zabbix.baseImage .Values.zabbix.version -}}
{{- end -}}

{{- define "zabbix.agent2Image" -}}
{{- printf "%s:%s-%s" .Values.zabbixAgent2.image.repository .Values.zabbix.baseImage .Values.zabbix.version -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Resolved server service name for agent2 and web to connect to.
   Uses the user-supplied override if set, otherwise the chart's own
   NLB service name.
   ----------------------------------------------------------------------- */}}
{{- define "zabbix.resolvedServerServiceName" -}}
{{- if .Values.zabbixAgent2.serverActiveServiceName -}}
  {{- .Values.zabbixAgent2.serverActiveServiceName -}}
{{- else -}}
  {{- include "zabbix.serverActiveServiceName" . -}}
{{- end -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Subnet list helper — joins the publicSubnetIds list into a
   comma-separated string for AWS annotations.
   Validates that the list is non-empty (required() alone only checks nil,
   not empty lists).
   ----------------------------------------------------------------------- */}}
{{- define "zabbix.subnetList" -}}
{{- if not .Values.vpc.publicSubnetIds -}}
  {{- fail "vpc.publicSubnetIds is required — provide at least 2 public subnet IDs (e.g. --set 'vpc.publicSubnetIds={subnet-aaa,subnet-bbb,subnet-ccc}')" -}}
{{- end -}}
{{- join "," .Values.vpc.publicSubnetIds -}}
{{- end -}}
