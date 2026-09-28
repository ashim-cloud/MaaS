# CLAUDE.md — Grafana Helm Chart Context

> **AI assistant context file.** This document provides a complete overview of the
> `grafana-helm` chart for AI-assisted development, troubleshooting, and code review.

---

## Chart Overview

| Field | Value |
|-------|-------|
| **Chart Name** | `grafana` |
| **Chart Version** | `0.1.0` |
| **App Version** | `13.2.2` |
| **Type** | `application` |
| **Purpose** | Deploy Grafana dashboard on AWS EKS with Zabbix data source plugin |
| **Origin** | Split from monolithic `zabbix-helm` chart |

This chart is **one part** of a multi-chart Zabbix deployment:

| Chart | Component | Status |
|-------|-----------|--------|
| `zabbix-server-helm` | Zabbix Server (HA StatefulSet) | Separate chart |
| `zabbix-web-helm` | Zabbix Web Frontend | Separate chart |
| `zabbix-aws-monitor-helm` | CloudWatch Metric Fetcher | Separate chart |
| **`grafana-helm`** | **Grafana Dashboard** | **This chart** |
| `zabbix-helm` | Original monolithic (all-in-one) | Legacy — do NOT modify |

---

## Directory Structure

```
grafana-helm/
├── Chart.yaml                                    # Helm chart metadata
├── CLAUDE.md                                     # This file — AI context
├── README.md                                     # Human-readable documentation
├── values.yaml                                   # All configurable values
├── docs/
│   └── eks-prerequisites.md                      # AWS EKS setup steps (Grafana-specific)
└── templates/
    ├── _helpers.tpl                              # Template helper functions
    ├── NOTES.txt                                 # Post-install CLI instructions
    ├── grafana-serviceaccount.yaml               # ServiceAccount
    ├── grafana-deployment.yaml                   # Deployment
    ├── grafana-service.yaml                      # ClusterIP Service
    └── grafana-ingress.yaml                      # ALB Ingress
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
  alb.ingress.kubernetes.io/healthcheck-path: /api/health    # per-target-group
  alb.ingress.kubernetes.io/success-codes: "200"             # per-target-group
  alb.ingress.kubernetes.io/listen-ports: '[...]'            # per-rule
  alb.ingress.kubernetes.io/ssl-redirect: "443"              # per-rule
spec:
  ingressClassName: alb-public                               # references shared IngressClassParams
```

Other services sharing the same ALB (same pattern):
- **ArgoCD** — `argocd.hamms.space` (via argocd-values.yaml)
- **Zabbix Web** — `monitoring.prestacknx.co.in` (via zabbix-web-helm)
- **Grafana** — `dashboard.prestacknx.co.in` (this chart)

---

## Template Helpers (`_helpers.tpl`)

All helper names are prefixed with `grafana.` to avoid collisions.

| Helper | Output (release=`grafana`) | Used By |
|--------|---------------------------|---------|
| `grafana.name` | `grafana` | Labels |
| `grafana.fullname` | `grafana` (release name) | All name helpers |
| `grafana.labels` | Standard Helm labels | All templates |
| `grafana.deploymentName` | `grafana` | Deployment, Service, Ingress |
| `grafana.serviceAccountName` | `grafana-sa` | SA, Deployment |
| `grafana.ingressName` | `grafana-ingress` | Ingress, NOTES.txt |
| `grafana.image` | `grafana/grafana:13.2.2` | Deployment |

---

## Resource Dependency Graph

```
ServiceAccount (grafana-sa)
      │
      ├──▶ Deployment (grafana)
      │        │
      │        ├── initContainer: ssm-init
      │        │     └── reads SSM → writes /secrets/*
      │        │
      │        ├── container: grafana
      │        │     ├── reads /secrets/* (DB creds)
      │        │     ├── GF_SERVER_DOMAIN = dashboard.prestacknx.co.in
      │        │     ├── GF_INSTALL_PLUGINS = alexanderzobnin-zabbix-app
      │        │     └── listens on :3000
      │        │
      │        └── volumes:
      │              └── secrets-vol (emptyDir: Memory)
      │
      ├──▶ Service (grafana, ClusterIP :80 → :3000)
      │        │
      │        └──▶ Ingress (grafana-ingress)
      │                  ├── ingressClassName: alb-public
      │                  ├── host: dashboard.prestacknx.co.in
      │                  └── routes to Service :80
```

---

## Values Structure

Key sections in `values.yaml`:

```yaml
ingress:          # IngressClass name (alb-public), ALB name (k8s-maas), host, healthCheck
grafana:          # Replicas, image, plugins, SA, database SSM, rootUrl, service, resources, security
```

### Critical Values That Must Be Set

| Value | Why |
|-------|-----|
| `ingress.className` | Must match the IngressClass name (`alb-public`) |
| `ingress.loadBalancerName` | Must match the shared ALB name (`k8s-maas`) |
| `ingress.grafanaHost` | Domain name for the Grafana dashboard |
| `grafana.database.ssm.path` | Must match SSM parameters created in prerequisites |
| `grafana.image.tag` | Pinned Grafana version — never use `latest` |

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
grafana container
     │  reads via: cat /secrets/type, host, dbname, etc.
     │  exports as: GF_DATABASE_TYPE, GF_DATABASE_HOST, etc.
     │  then: exec grafana server
```

Required SSM parameters under `grafana.database.ssm.path`:
- `type` — Database type (e.g. `postgres`)
- `host` — RDS endpoint with port (e.g. `mydb.rds.amazonaws.com:5432`)
- `dbname` — Database name
- `user` — DB username
- `password` — DB password
- `sslMode` — SSL mode (e.g. `require`)

---

## Feature Flags

| Flag | Default | Controls |
|------|---------|----------|
| `grafana.serviceAccount.create` | `true` | ServiceAccount creation |
| `grafana.service.enabled` | `true` | ClusterIP Service creation |
| `ingress.enabled` | `true` | ALB Ingress creation |

> **No HPA** — Grafana runs with a static replica count (`grafana.replicaCount: 1`).

---

## External Dependencies

| Dependency | Purpose | Managed By |
|------------|---------|------------|
| IngressClass `alb-public` | Shared ALB config (cert, WAF, subnets) | `alb-defaults.yaml` (ArgoCD) |
| IngressClassParams `maas-public-alb` | ALB parameters | `alb-defaults.yaml` (ArgoCD) |
| AWS Load Balancer Controller | Provisions ALB from Ingress | `aws-lb-controller-app.yaml` (ArgoCD) |
| EKS Pod Identity Agent | IAM credentials for SSM access | EKS cluster add-on |
| RDS PostgreSQL | Grafana database | External (AWS) |
| Route53 (or DNS) | Domain → ALB hostname mapping | External (manual) |

---

## Common Operations

### Lint & Validate

```bash
helm lint ./grafana-helm --namespace zabbix-dev
helm template grafana ./grafana-helm --namespace zabbix-dev
helm template grafana ./grafana-helm --namespace zabbix-dev | kubectl apply --dry-run=client -f -
```

### Install

```bash
helm install grafana ./grafana-helm --namespace zabbix-dev --create-namespace
```

### Upgrade

```bash
helm upgrade grafana ./grafana-helm --namespace zabbix-dev
```

### Uninstall

```bash
helm uninstall grafana --namespace zabbix-dev
```

### Override Values

```bash
# Change Grafana version
helm upgrade grafana ./grafana-helm -n zabbix-dev --set grafana.image.tag=13.3.0

# Change replica count
helm upgrade grafana ./grafana-helm -n zabbix-dev --set grafana.replicaCount=2

# Change domain
helm upgrade grafana ./grafana-helm -n zabbix-dev --set ingress.grafanaHost=grafana.example.com

# Disable ingress
helm upgrade grafana ./grafana-helm -n zabbix-dev --set ingress.enabled=false

# Add more plugins
helm upgrade grafana ./grafana-helm -n zabbix-dev \
  --set 'grafana.plugins=alexanderzobnin-zabbix-app,grafana-clock-panel'
```

---

## Naming Conventions

- **Files**: `grafana-<resource-type>.yaml` (e.g., `grafana-deployment.yaml`)
- **Helper prefix**: `grafana.` (e.g., `grafana.deploymentName`)
- **Labels**: All resources carry `app: grafana` and `app.kubernetes.io/component: grafana`
- **Resource names**: Derived from release name (e.g., release `grafana` → `grafana`, `grafana-sa`)

---

## Known Behaviors & Gotchas

1. **Health check path**: Grafana's root `/` returns HTTP 302 (redirect to `/login`), which ALB treats as unhealthy. The Ingress health check is set to `/api/health` which always returns 200.

2. **WHY separate Ingress from Zabbix Web**: Each Ingress gets its own target group with independent health check configuration. Sharing one Ingress would force the same health check path for both backends.

3. **GF_SERVER_ROOT_URL uses hardcoded https://**: The ALB terminates SSL. Grafana pods only see HTTP internally, so `%(protocol)s` resolves to `http` and breaks login redirects. `https://` must be hardcoded.

4. **GF_SERVER_SERVE_FROM_SUB_PATH is NOT needed**: Grafana serves at the root `/` of its subdomain (`dashboard.prestacknx.co.in/`), not at a sub-path.

5. **ssm-init uses latest tag**: The init container image (`public.ecr.aws/aws-cli/aws-cli:latest`) uses `latest`. This is intentional for always getting the latest AWS CLI.

6. **Container port**: Grafana listens on port **3000** (not 80). The Service maps 80 → 3000.

7. **Iframe embedding**: `GF_SECURITY_ALLOW_EMBEDDING=true` with `cookieSameSite=none` and `cookieSecure=true` is required for embedding Grafana panels in cross-origin iframes.

8. **No HPA**: Unlike zabbix-web-helm, this chart uses a static replica count. The `replicas` field is always present in the Deployment spec.

---

## Related Files in Other Charts

| This Chart File | Equivalent in Monolithic `zabbix-helm` |
|-----------------|---------------------------------------|
| `grafana-serviceaccount.yaml` | `grafana-deployment.yaml` (lines 45-53) |
| `grafana-deployment.yaml` | `grafana-deployment.yaml` (lines 57-183) |
| `grafana-service.yaml` | `grafana-deployment.yaml` (lines 190-206) |
| `grafana-ingress.yaml` | `grafana-ingress.yaml` |

## Related Infrastructure Files

| File | Purpose |
|------|---------|
| `aws-loadbalance-controller/alb-defaults.yaml` | IngressClassParams + IngressClass (ALB config) |
| `aws-loadbalance-controller/aws-lb-controller-app.yaml` | ArgoCD Application for LB Controller |
| `argocd/argocd-values.yaml` | ArgoCD Ingress (shares same ALB) |
| `argocd/maas-project.yaml` | ArgoCD AppProject |
