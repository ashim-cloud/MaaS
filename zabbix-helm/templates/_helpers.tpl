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

{{/* Web ServiceAccount name: "zabbix-web-sa" — used for EKS Pod Identity */}}
{{- define "zabbix.webSaName" -}}
{{- printf "%s-web-sa" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Web Ingress name: "zabbix-web-ingress" */}}
{{- define "zabbix.webIngressName" -}}
{{- printf "%s-web-ingress" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{/* DB Secret name — references a pre-existing Secret (externally managed).
   The Secret must be created manually before `helm install` is run.
   Configured via db.existingSecret in values.yaml. */}}
{{- define "zabbix.secretName" -}}
{{- .Values.db.existingSecret -}}
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

{{/* -----------------------------------------------------------------------
   kube-state-metrics helpers
   Name and namespace are sourced from values.yaml (kubeStateMetrics.nameOverride
   and kubeStateMetrics.namespace) with defaults matching the prior hardcoded
   values, so existing behaviour is unchanged unless explicitly overridden.
   ----------------------------------------------------------------------- */}}

{{/* kube-state-metrics resource name — defaults to "kube-state-metrics" */}}
{{- define "zabbix.ksmName" -}}
{{- .Values.kubeStateMetrics.nameOverride -}}
{{- end -}}

{{/* kube-state-metrics target namespace — defaults to "kube-system" */}}
{{- define "zabbix.ksmNamespace" -}}
{{- .Values.kubeStateMetrics.namespace -}}
{{- end -}}

{{/* kube-state-metrics container image: repository:tag */}}
{{- define "zabbix.ksmImage" -}}
{{- printf "%s:%s" .Values.kubeStateMetrics.image.repository .Values.kubeStateMetrics.image.tag -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   zabbix-k8s-monitoring helpers
   Names are sourced from values.yaml (zabbixK8sMonitoring.nameOverride and
   zabbixK8sMonitoring.tokenSecretName) with defaults matching the prior
   hardcoded values, so the Zabbix macro endpoint and token extraction
   commands remain stable unless explicitly overridden.
   ----------------------------------------------------------------------- */}}

{{/* zabbix-k8s-monitoring SA / ClusterRole / ClusterRoleBinding name */}}
{{- define "zabbix.k8sMonitoringName" -}}
{{- .Values.zabbixK8sMonitoring.nameOverride -}}
{{- end -}}

{{/* zabbix-k8s-monitoring-token Secret name */}}
{{- define "zabbix.k8sMonitoringTokenName" -}}
{{- .Values.zabbixK8sMonitoring.tokenSecretName -}}
{{- end -}}

{{/* -----------------------------------------------------------------------
   zabbix-aws-monitor helpers
   The Deployment name follows the standard fullname pattern, but the
   ServiceAccount name is configurable because it must exactly match the
   EKS Pod Identity association created out-of-band.
   ----------------------------------------------------------------------- */}}

{{/* aws-monitor Deployment name: "zabbix-aws-monitor" */}}
{{- define "zabbix.awsMonitorName" -}}
{{- printf "%s-aws-monitor" (include "zabbix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* aws-monitor ServiceAccount name — must match Pod Identity association */}}
{{- define "zabbix.awsMonitorSaName" -}}
{{- .Values.awsMonitor.serviceAccountName -}}
{{- end -}}

{{/* aws-monitor container image: repository:tag */}}
{{- define "zabbix.awsMonitorImage" -}}
{{- printf "%s:%s" .Values.awsMonitor.image.repository .Values.awsMonitor.image.tag -}}
{{- end -}}
