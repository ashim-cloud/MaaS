# Zabbix Web — Helm Chart

Standalone Helm chart for deploying the **Zabbix Web Frontend** (nginx + pgsql) on **AWS EKS**.

> This chart is a split from the monolithic `zabbix-helm` chart.  
> Each Zabbix component (server, web, aws-monitor, etc.) is now its own chart for **easier troubleshooting, independent scaling, and focused upgrades**.

---

## Architecture

```
                     ┌──────────────────────────────────────────┐
                     │           AWS ALB (HTTPS)                │
                     │  *.prestacknx.co.in — ACM wildcard cert  │
                     └──────────────┬───────────────────────────┘
                                    │
                         ┌──────────▼──────────┐
                         │  Kubernetes Ingress  │
                         │  (zabbix-web-ingress)│
                         └──────────┬───────────┘
                                    │
                         ┌──────────▼──────────┐
                         │  ClusterIP Service   │
                         │  (zabbix-web :80)    │
                         └──────────┬───────────┘
                                    │
                     ┌──────────────▼──────────────────┐
                     │  Deployment (zabbix-web)         │
                     │  ┌───────────┐ ┌──────────────┐  │
                     │  │ ssm-init  │→│  zabbix-web  │  │
                     │  │(initCont.)│ │  (nginx+php) │  │
                     │  └───────────┘ └──────────────┘  │
                     │         ↓ /secrets/*             │
                     │   emptyDir (Memory)              │
                     └──────────────────────────────────┘
                                    │
                         ┌──────────▼──────────┐
                         │  Zabbix Server       │
                         │  (zabbix-server-     │
                         │   active, port 10051)│
                         └──────────────────────┘
```

---

## Resources Created

| File | Kubernetes Resource | Description |
|------|-------------------|-------------|
| `zabbix-web-serviceaccount.yaml` | `ServiceAccount` | EKS Pod Identity — assumes IAM role for SSM access |
| `zabbix-web-deployment.yaml` | `Deployment` | Zabbix Web frontend (nginx + pgsql) with SSM init container |
| `zabbix-web-service.yaml` | `Service` (ClusterIP) | Internal service for ALB Ingress routing (port 80 → 8080) |
| `zabbix-web-hpa.yaml` | `HorizontalPodAutoscaler` | Auto-scales based on CPU/memory utilization |
| `zabbix-web-ingress.yaml` | `Ingress` (ALB) | AWS ALB with HTTPS, WAF, HTTP→HTTPS redirect |
| `zabbix-web-configmap-branding.yaml` | `ConfigMap` | Custom Precision branding (CSS, logos, favicon) |

---

## Prerequisites

Before installing this chart, ensure the following:

1. **Namespace** exists:
   ```bash
   kubectl create namespace zabbix-dev
   ```

2. **Zabbix Server** is deployed and accessible at the service name configured in `zabbixServer.serviceName` (default: `zabbix-server-active`).

3. **SSM Parameter Store** — DB credentials stored as SecureString parameters:
   ```
   /zabbix-dev/zabbix-db-secret/host
   /zabbix-dev/zabbix-db-secret/port
   /zabbix-dev/zabbix-db-secret/dbname
   /zabbix-dev/zabbix-db-secret/user
   /zabbix-dev/zabbix-db-secret/password
   ```

4. **IAM Role** with permissions:
   - `ssm:GetParameter*` on the DB credential parameters
   - `kms:Decrypt` on the KMS key used to encrypt those parameters

5. **EKS Pod Identity Association** for the ServiceAccount:
   ```bash
   aws eks create-pod-identity-association \
     --cluster-name <CLUSTER_NAME> \
     --namespace <NAMESPACE> \
     --service-account <RELEASE>-web-sa \
     --role-arn arn:aws:iam::<ACCOUNT>:role/<ROLE_NAME>
   ```

6. **AWS Load Balancer Controller** installed in the cluster.

7. **ACM Certificate** covering the web frontend domain (wildcard or specific).

---

## Installation

### Quick Install

```bash
helm install zabbix ./zabbix-web-helm \
  --namespace zabbix-dev \
  --create-namespace
```

### Install with Custom Values

```bash
helm install zabbix ./zabbix-web-helm \
  --namespace zabbix-dev \
  --create-namespace \
  -f my-values.yaml
```

### Upgrade

```bash
helm upgrade zabbix ./zabbix-web-helm \
  --namespace zabbix-dev
```

---

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `zabbix.version` | Zabbix version (image tag) | `7.0.30` |
| `zabbix.baseImage` | Base image variant | `ubuntu` |
| `zabbixWeb.replicaCount` | Static replicas (when HPA disabled) | `2` |
| `zabbixWeb.image.repository` | Web image repository | `zabbix/zabbix-web-nginx-pgsql` |
| `zabbixWeb.phpTz` | PHP timezone | `Asia/Kolkata` |
| `zabbixWeb.resources.requests.cpu` | CPU request | `200m` |
| `zabbixWeb.resources.requests.memory` | Memory request | `300Mi` |
| `zabbixWeb.resources.limits.cpu` | CPU limit | `1` |
| `zabbixWeb.resources.limits.memory` | Memory limit | `1Gi` |
| `zabbixWeb.autoscaling.enabled` | Enable HPA | `true` |
| `zabbixWeb.autoscaling.minReplicas` | HPA min replicas | `2` |
| `zabbixWeb.autoscaling.maxReplicas` | HPA max replicas | `5` |
| `zabbixWeb.ingress.enabled` | Enable ALB Ingress | `true` |
| `zabbixWeb.ingress.scheme` | ALB scheme | `internet-facing` |
| `zabbixWeb.ingress.zabbixHost` | Zabbix hostname | `monitoring.prestacknx.co.in` |
| `zabbixServer.serviceName` | Zabbix Server service to connect to | `zabbix-server-active` |
| `db.ssm.path` | SSM parameter path for DB credentials | `/zabbix-dev/zabbix-db-secret` |
| `db.ssm.region` | AWS region for SSM | `ap-south-1` |
| `alb.acmCertificateArn` | ACM certificate ARN (REQUIRED) | *(set in values)* |
| `alb.groupName` | ALB Ingress Group | `zabbix-shared` |
| `alb.wafAclArn` | WAFv2 Web ACL ARN (optional) | *(set in values)* |
| `branding.enabled` | Deploy custom branding ConfigMap | `true` |

---

## Chart Structure

```
zabbix-web-helm/
├── Chart.yaml                                   # Chart metadata (v0.1.0)
├── values.yaml                                  # Default configuration
├── README.md                                    # This file
├── files/
│   └── branding/                                # Custom branding assets
│       ├── blue-theme.css
│       ├── dark-theme.css
│       ├── hc-light.css
│       ├── hc-dark.css
│       ├── precision-compact-logo.svg
│       ├── precision-favicon.ico
│       ├── precision-full-logo.svg
│       └── precision-sidebar-logo.svg
└── templates/
    ├── _helpers.tpl                             # Template helper functions
    ├── NOTES.txt                                # Post-install instructions
    ├── zabbix-web-serviceaccount.yaml           # ServiceAccount (Pod Identity)
    ├── zabbix-web-deployment.yaml               # Deployment (web frontend)
    ├── zabbix-web-service.yaml                  # ClusterIP Service
    ├── zabbix-web-hpa.yaml                      # HorizontalPodAutoscaler
    ├── zabbix-web-ingress.yaml                  # ALB Ingress
    └── zabbix-web-configmap-branding.yaml       # Branding ConfigMap
```

---

## Custom Branding / Theming

To modify or add new Zabbix themes (like `blue-theme.css`, `dark-theme.css`, etc.) to use custom logos:
1. Download the original CSS theme file from the Zabbix source repository (matching version `7.0.x`).
2. Open the downloaded CSS file and locate `div.zabbix-logo`, `div.zabbix-logo-sidebar`, and `div.zabbix-logo-sidebar-compact`.
3. Replace their `background: url("data:image...")` references with paths to the custom SVG logos (e.g., `background: url("/assets/precision-full-logo.svg") no-repeat;`).
4. Save the modified CSS file to the `files/branding/` directory.
5. Update `templates/zabbix-web-configmap-branding.yaml` to include the new file in a new `ConfigMap` block (to avoid Kubernetes' 1MB size limit per ConfigMap).
6. Update `templates/zabbix-web-deployment.yaml` to add a new `volume` for the new ConfigMap, and a new `volumeMount` for the file under `/usr/share/zabbix/assets/styles/<theme-name>.css`.

---

## Troubleshooting

### Pods stuck in Init

The `ssm-init` container needs IAM permissions. Check:
```bash
# Check init container logs
kubectl logs -n zabbix-dev <pod-name> -c ssm-init

# Verify Pod Identity association
aws eks list-pod-identity-associations \
  --cluster-name <CLUSTER_NAME> \
  --namespace zabbix-dev
```

### ALB not provisioning

```bash
# Check Ingress status
kubectl describe ingress -n zabbix-dev

# Check AWS LB Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### Web UI shows "Connection refused"

The Zabbix Server must be reachable at the configured `zabbixServer.serviceName`:
```bash
# Verify server service exists
kubectl get svc zabbix-server-active -n zabbix-dev

# Test connectivity from a web pod
kubectl exec -n zabbix-dev <web-pod> -- \
  wget -qO- --timeout=5 http://zabbix-server-active:10051 || echo "Connection test done"
```

### Database connection errors

```bash
# Verify SSM parameters exist
aws ssm get-parameters-by-path \
  --path "/zabbix-dev/zabbix-db-secret" \
  --with-decryption \
  --query "Parameters[*].Name"

# Check if secrets were written
kubectl exec -n zabbix-dev <web-pod> -c zabbix-web -- ls -la /secrets/
```

---

## Migrating from Monolithic Chart

If you're migrating from the monolithic `zabbix-helm` chart:

1. The resource names remain identical when using the same release name (e.g., `zabbix`).
2. Values structure is slightly flattened — copy relevant sections from the monolithic `values.yaml`.
3. The `files/branding/` directory must be present in this chart's root (copy from monolithic chart).
4. Install this chart **before** removing the web resources from the monolithic chart to avoid downtime.

---

## License

Internal — Platform Team
