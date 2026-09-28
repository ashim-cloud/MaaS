{{/*
=============================================================================
Zabbix Server Helm Chart — Helper Templates (_helpers.tpl)
=============================================================================
*/}}

{{/*
Chart name, truncated to 63 chars (Kubernetes name limit).
*/}}
{{- define "zabbix-server.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
Uses the release name directly (not release-chart) to keep resource names
short and predictable. If release name = "zabbix", resource names match
the original manually-tested manifests exactly.
Truncated to 63 chars for Kubernetes name compliance.
*/}}
{{- define "zabbix-server.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard Helm metadata labels applied to every resource.
*/}}
{{- define "zabbix-server.labels" -}}
helm.sh/chart: {{ printf "%s-%s" (include "zabbix-server.name" .) .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.zabbix.version | quote }}
app.kubernetes.io/part-of: zabbix
app.kubernetes.io/component: server
{{- end -}}

{{/* -----------------------------------------------------------------------
   Resource Name Helpers
   Each produces a deterministic name from the release name.
   Pod names follow the pattern: <release>-0, <release>-1, etc.
   ----------------------------------------------------------------------- */}}

{{/* StatefulSet + headless Service name — uses the release name directly.
   With release "zabbix-server", pods are: zabbix-server-0, zabbix-server-1 */}}
{{- define "zabbix-server.statefulSetName" -}}
{{- include "zabbix-server.fullname" . -}}
{{- end -}}

{{/* NLB Service name: "<release>-active" */}}
{{- define "zabbix-server.activeServiceName" -}}
{{- printf "%s-active" (include "zabbix-server.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* HA sidecar ServiceAccount name — fixed, not derived from release name. */}}
{{- define "zabbix-server.serviceAccountName" -}}
zabbix-ha-sidecar
{{- end -}}

{{/* HA label patcher Role name: "zabbix-ha-label-patcher" */}}
{{- define "zabbix-server.roleName" -}}
{{- printf "%s-ha-label-patcher" (include "zabbix-server.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* HA label patcher RoleBinding name: "zabbix-ha-label-patcher-binding" */}}
{{- define "zabbix-server.roleBindingName" -}}
{{- printf "%s-ha-label-patcher-binding" (include "zabbix-server.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Image Tag Helper
   Compose image reference from global zabbix.baseImage + zabbix.version.
   Example: zabbix/zabbix-server-pgsql:ubuntu-7.0.30
   ----------------------------------------------------------------------- */}}
{{- define "zabbix-server.image" -}}
{{- printf "%s:%s-%s" .Values.zabbixServer.image.repository .Values.zabbix.baseImage .Values.zabbix.version -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   Subnet list helper — joins the publicSubnetIds list into a
   comma-separated string for AWS NLB annotations.
   ----------------------------------------------------------------------- */}}
{{- define "zabbix-server.subnetList" -}}
{{- if not .Values.vpc.publicSubnetIds -}}
  {{- fail "vpc.publicSubnetIds is required — provide at least 2 public subnet IDs (e.g. --set 'vpc.publicSubnetIds={subnet-aaa,subnet-bbb,subnet-ccc}')" -}}
{{- end -}}
{{- join "," .Values.vpc.publicSubnetIds -}}
{{- end -}}
