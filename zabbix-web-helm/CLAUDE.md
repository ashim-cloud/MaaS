# CLAUDE.md — Zabbix Web Helm Chart Context

> **AI assistant context file.** This document provides a complete overview of the
> `zabbix-web-helm` chart for AI-assisted development, troubleshooting, and code review.

---

## Chart Overview

| Field | Value |
|-------|-------|
| **Chart Name** | `zabbix-web` |
| **Chart Version** | `0.1.0` |
| **App Version** | `7.0.30` |
| **Type** | `application` |
| **Purpose** | Deploy the Zabbix Web Frontend (nginx + pgsql) on AWS EKS |
| **Origin** | Split from monolithic `zabbix-helm` chart |

This chart is **one part** of a multi-chart Zabbix deployment:

| Chart | Component | Status |
|-------|-----------|--------|
| `zabbix-server-helm` | Zabbix Server (HA StatefulSet) | Separate chart |
| **`zabbix-web-helm`** | **Zabbix Web Frontend** | **This chart** |
| `zabbix-aws-monitor-helm` | CloudWatch Metric Fetcher | Separate chart |
| `zabbix-helm` | Original monolithic (all-in-one) | Legacy — do NOT modify |

---

## Directory Structure

```
zabbix-web-helm/
├── Chart.yaml                                    # Helm chart metadata
├── CLAUDE.md                                     # This file — AI context
├── README.md                                     # Human-readable documentation
├── values.yaml                                   # All configurable values
├── docs/
│   └── eks-prerequisites.md                      # AWS EKS setup steps (web-specific)
├── files/
│   └── branding/                                 # Custom Precision branding assets
│       ├── blue-theme.css                        # Custom Zabbix CSS theme (~270KB)
│       ├── precision-compact-logo.svg            # Compact logo
│       ├── precision-favicon.ico                 # Custom favicon (binary)
│       ├── precision-full-logo.svg               # Full logo
│       └── precision-sidebar-logo.svg            # Sidebar logo
└── templates/
    ├── _helpers.tpl                              # Template helper functions
    ├── NOTES.txt                                 # Post-install CLI instructions
    ├── zabbix-web-serviceaccount.yaml            # ServiceAccount
    ├── zabbix-web-deployment.yaml                # Deployment
    ├── zabbix-web-service.yaml                   # ClusterIP Service
    ├── zabbix-web-hpa.yaml                       # HorizontalPodAutoscaler
    ├── zabbix-web-ingress.yaml                   # ALB Ingress
    └── zabbix-web-configmap-branding.yaml        # Branding ConfigMap
```

---

## ALB Architecture — Shared IngressClass

ALB-level configuration is **NOT** in this chart. It is centralized in:

```
aws-loadbalance-controller/alb-defaults.yaml
├── IngressClassParams (maas-public-alb)
│   ├── scheme: internet-facing
│   ├── group.name: maas              ← all Ingresses share ONE ALB
│   ├── subnets: [3 public subnets]
│   ├── certificateArn: [ACM cert]
│   ├── sslPolicy: TLS13
│   └── wafv2AclArn: [WAF ACL]
│
└── IngressClass (alb-public)
    └── references: maas-public-alb
```

This chart's Ingress only sets **per-target-group** annotations:

```yaml
annotations:
  alb.ingress.kubernetes.io/load-balancer-name: k8s-maas    # shared ALB name
  alb.ingress.kubernetes.io/target-type: ip                  # per-target-group
  alb.ingress.kubernetes.io/backend-protocol: HTTP           # per-target-group
  alb.ingress.kubernetes.io/healthcheck-path: /              # per-target-group
  alb.ingress.kubernetes.io/success-codes: "200"             # per-target-group
  alb.ingress.kubernetes.io/listen-ports: '[...]'            # per-rule
  alb.ingress.kubernetes.io/ssl-redirect: "443"              # per-rule
spec:
  ingressClassName: alb-public                               # references shared IngressClassParams
```

Other services sharing the same ALB (same pattern):
- **ArgoCD** — `argocd.hamms.space` (via argocd-values.yaml)
- **Zabbix Web** — `monitoring.prestacknx.co.in` (this chart)

---

## Template Helpers (`_helpers.tpl`)

All helper names are prefixed with `zabbix-web.` to avoid collisions.

| Helper | Output (release=`zabbix-web`) | Used By |
|--------|--------------------------|---------|
| `zabbix-web.name` | `zabbix-web` | Labels |
| `zabbix-web.fullname` | `zabbix-web` (release name) | All name helpers |
| `zabbix-web.labels` | Standard Helm labels | All templates |
| `zabbix-web.deploymentName` | `zabbix-web` (= release name) | Deployment, Service, HPA, Ingress |
| `zabbix-web.serviceAccountName` | `zabbix-web-sa` (hardcoded) | SA, Deployment |
| `zabbix-web.ingressName` | `zabbix-web-ingress` | Ingress, NOTES.txt |
| `zabbix-web.hpaName` | `zabbix-web` (= release name) | HPA |
| `zabbix-web.serverServiceName` | `zabbix-server-active` | Deployment (env var) |
| `zabbix-web.image` | `zabbix/zabbix-web-nginx-pgsql:ubuntu-7.0.30` | Deployment |

---

## Resource Dependency Graph

```
ServiceAccount (zabbix-web-sa)
      │
      ├──▶ Deployment (zabbix-web)
      │        │
      │        ├── initContainer: ssm-init
      │        │     └── reads SSM → writes /secrets/*
      │        │
      │        ├── container: zabbix-web
      │        │     ├── reads /secrets/* (DB creds)
      │        │     ├── connects to ZBX_SERVER_HOST (zabbix-server-active)
      │        │     └── listens on :8080
      │        │
      │        └── volumes:
      │              ├── secrets-vol (emptyDir: Memory)
      │              └── precision-zabbix-logos (ConfigMap)
      │
      ├──▶ Service (zabbix-web, ClusterIP :80 → :8080)
      │        │
      │        └──▶ Ingress (zabbix-web-ingress)
      │                  ├── ingressClassName: alb-public
      │                  ├── host: monitoring.prestacknx.co.in
      │                  └── routes to Service :80
      │
      └──▶ HPA (zabbix-web)
               └── targets Deployment (CPU/Memory)

ConfigMap (precision-zabbix-logos)
      └── mounted into Deployment containers
```

---

## Values Structure

Key sections in `values.yaml`:

```yaml
zabbix:           # Global — version, baseImage
ingress:          # IngressClass name (alb-public), ALB name (k8s-maas), healthCheck
db:               # SSM path + region for DB credentials
zabbixServer:     # Server service name (connection target)
zabbixWeb:        # Replicas, image, phpTz, SA, ingress host, service, resources, autoscaling
branding:         # Enable/disable custom branding ConfigMap
```

### Critical Values That Must Be Set

| Value | Why |
|-------|-----|
| `ingress.className` | Must match the IngressClass name (`alb-public`) |
| `ingress.loadBalancerName` | Must match the shared ALB name (`k8s-maas`) |
| `db.ssm.path` | Must match SSM parameters created in prerequisites |
| `zabbixServer.serviceName` | Must match the actual Zabbix Server service name in the cluster |
| `zabbixWeb.ingress.zabbixHost` | Domain name for the Zabbix web frontend |

---

## Secrets Architecture

**No Kubernetes Secrets are used.** DB credentials flow:

```
AWS SSM Parameter Store (SecureString)
     │
     ▼
ssm-init (initContainer, AWS CLI)
     │  fetches via: aws ssm get-parameters-by-path
     │  authenticates via: EKS Pod Identity → IAM role
     │
     ▼
/secrets/* (emptyDir: medium: Memory — RAM-backed, never on disk)
     │
     ▼
zabbix-web container
     │  reads via: cat /secrets/host, etc.
     │  exports as: DB_SERVER_HOST, POSTGRES_USER, etc.
     │  then: exec docker-entrypoint.sh
```

Required SSM parameters under `db.ssm.path`:
- `host` — RDS endpoint
- `port` — DB port (default: 5432)
- `dbname` — Database name
- `user` — DB username
- `password` — DB password

---

## Feature Flags

| Flag | Default | Controls |
|------|---------|----------|
| `zabbixWeb.serviceAccount.create` | `true` | ServiceAccount creation |
| `zabbixWeb.service.enabled` | `true` | ClusterIP Service creation |
| `zabbixWeb.ingress.enabled` | `true` | ALB Ingress creation |
| `zabbixWeb.autoscaling.enabled` | `true` | HPA creation (also suppresses `replicas` in Deployment) |
| `branding.enabled` | `true` | Branding ConfigMap + volume mounts |

---

## External Dependencies

| Dependency | Purpose | Managed By |
|------------|---------|------------|
| IngressClass `alb-public` | Shared ALB config (cert, WAF, subnets) | `alb-defaults.yaml` (ArgoCD) |
| IngressClassParams `maas-public-alb` | ALB parameters | `alb-defaults.yaml` (ArgoCD) |
| AWS Load Balancer Controller | Provisions ALB from Ingress | `aws-lb-controller-app.yaml` (ArgoCD) |
| EKS Pod Identity Agent | IAM credentials for SSM access | EKS cluster add-on |
| Zabbix Server (`zabbix-server-active`) | Backend server for web frontend | `zabbix-server-helm` chart |
| RDS PostgreSQL | Zabbix database | External (AWS) |
| Route53 (or DNS) | Domain → ALB hostname mapping | External (manual) |

---

## Common Operations

### Lint & Validate

```bash
helm lint ./zabbix-web-helm --namespace zabbix-dev
helm template zabbix ./zabbix-web-helm --namespace zabbix-dev
helm template zabbix ./zabbix-web-helm --namespace zabbix-dev | kubectl apply --dry-run=client -f -
```

### Install

```bash
helm install zabbix ./zabbix-web-helm --namespace zabbix-dev --create-namespace
```

### Upgrade

```bash
helm upgrade zabbix ./zabbix-web-helm --namespace zabbix-dev
```

### Uninstall

```bash
helm uninstall zabbix --namespace zabbix-dev
```

### Override Values

```bash
# Change Zabbix version
helm upgrade zabbix ./zabbix-web-helm -n zabbix-dev --set zabbix.version=7.0.31

# Change replica count (when HPA disabled)
helm upgrade zabbix ./zabbix-web-helm -n zabbix-dev \
  --set zabbixWeb.autoscaling.enabled=false \
  --set zabbixWeb.replicaCount=3

# Disable branding
helm upgrade zabbix ./zabbix-web-helm -n zabbix-dev --set branding.enabled=false

# Change domain
helm upgrade zabbix ./zabbix-web-helm -n zabbix-dev --set zabbixWeb.ingress.zabbixHost=zabbix.example.com
```

---

## Custom Branding / Theming

If you want to modify or add new Zabbix themes (like `blue-theme.css`, `dark-theme.css`, `hc-light.css`, or `hc-dark.css`) to use the custom Precision logos, follow these steps:

1. **Obtain the Original CSS File**: Download the original CSS theme file from the Zabbix source repository for the matching version (e.g., `https://raw.githubusercontent.com/zabbix/zabbix/release/7.0/ui/assets/styles/dark-theme.css`).
2. **Modify Logo References**: Open the downloaded CSS file and locate the classes `div.zabbix-logo`, `div.zabbix-logo-sidebar`, and `div.zabbix-logo-sidebar-compact`. Replace the `background: url("data:image...")` definitions with paths to the custom SVG logos:
   - Full logo: `background: url("/assets/precision-full-logo.svg") no-repeat;`
   - Sidebar logo: `background: url("/assets/precision-sidebar-logo.svg") no-repeat;`
   - Compact logo: `background: url("/assets/precision-compact-logo.svg") no-repeat;`
3. **Save to Chart**: Save the modified CSS file to `c:\Users\PIT1216\Desktop\Zabbix-Helm\zabbix-web-helm\files\branding\`.
4. **Update ConfigMap**: Add the file reference into `templates/zabbix-web-configmap-branding.yaml` under the file list comment and under the `data:` section so it's loaded as part of the ConfigMap.
5. **Update Deployment**: Edit `templates/zabbix-web-deployment.yaml` and add a new `volumeMount` for the file under the `zabbix-web` container mounting to `/usr/share/zabbix/assets/styles/<theme-name>.css`.
6. **Apply Changes**: Run `helm upgrade` or apply the manifests to update the deployment.

---

## Naming Conventions

- **Files**: `zabbix-web-<resource-type>.yaml` (e.g., `zabbix-web-deployment.yaml`)
- **Helper prefix**: `zabbix-web.` (e.g., `zabbix-web.deploymentName`)
- **Labels**: All resources carry `app: zabbix-web` and `app.kubernetes.io/component: web`
- **Resource names**: Deployment/Service/HPA use release name directly (e.g., release `zabbix-web` → `zabbix-web`)
- **ServiceAccount**: Always `zabbix-web-sa` (hardcoded, not derived from release name)

---

## Known Behaviors & Gotchas

1. **HPA vs replicas**: When `autoscaling.enabled=true`, the Deployment template **omits** the `replicas` field entirely. This prevents `helm upgrade` from resetting the HPA-managed count.

2. **ALB is shared**: This Ingress joins the `maas` ALB group via `ingressClassName: alb-public`. All ALB-level config (cert, WAF, scheme, subnets) comes from `IngressClassParams`. Do NOT add ALB-level annotations to this Ingress.

3. **Branding files size**: `blue-theme.css` is ~270KB. The ConfigMap will be large. This is expected.

4. **ssm-init uses latest tag**: The init container image (`public.ecr.aws/aws-cli/aws-cli:latest`) uses `latest`. This is intentional for always getting the latest AWS CLI, but can be pinned in values if needed.

5. **ZBX_SERVER_NAME**: Hardcoded to `"Prestack Monitoring"` in the Deployment template. To make this configurable, it would need a new values field.

6. **Container port**: The zabbix-web-nginx-pgsql image listens on port **8080** (not 80). The Service maps 80 → 8080.

---

## Related Files in Other Charts

| This Chart File | Equivalent in Monolithic `zabbix-helm` |
|-----------------|---------------------------------------|
| `zabbix-web-serviceaccount.yaml` | `web-deployment.yaml` (lines 26-33) |
| `zabbix-web-deployment.yaml` | `web-deployment.yaml` (lines 38-160) |
| `zabbix-web-service.yaml` | `web-service.yaml` |
| `zabbix-web-hpa.yaml` | `web-hpa.yaml` |
| `zabbix-web-ingress.yaml` | `web-ingress.yaml` |
| `zabbix-web-configmap-branding.yaml` | `precision-zabbix-logos-configmap.yaml` |

## Related Infrastructure Files

| File | Purpose |
|------|---------|
| `aws-loadbalance-controller/alb-defaults.yaml` | IngressClassParams + IngressClass (ALB config) |
| `aws-loadbalance-controller/aws-lb-controller-app.yaml` | ArgoCD Application for LB Controller |
| `argocd/argocd-values.yaml` | ArgoCD Ingress (shares same ALB) |
| `argocd/maas-project.yaml` | ArgoCD AppProject |
