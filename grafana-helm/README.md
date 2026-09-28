# Grafana — Helm Chart

Standalone Helm chart for deploying **Grafana** on **AWS EKS** with external RDS PostgreSQL and Zabbix data source integration.

> This chart is a split from the monolithic `zabbix-helm` chart.
> Each component (server, web, grafana, aws-monitor) is now its own chart
> for **easier troubleshooting, independent upgrades, and focused ownership**.

---

## Resources Created

| File | Kubernetes Resource | Description |
|------|-------------------|-------------|
| `grafana-serviceaccount.yaml` | `ServiceAccount` | Pod Identity for SSM/IAM access |
| `grafana-deployment.yaml` | `Deployment` | Grafana with SSM init + Zabbix plugin |
| `grafana-service.yaml` | `Service` (ClusterIP) | Port 80 → container 3000 |
| `grafana-ingress.yaml` | `Ingress` | ALB host routing via alb-public IngressClass |

---

## Prerequisites

1. **Namespace** exists:
   ```bash
   kubectl create namespace zabbix-dev
   ```

2. **RDS PostgreSQL** — Grafana database created with user/permissions.

3. **SSM Parameter Store** — DB credentials stored as SecureString:
   ```
   /zabbix-dev/grafana-secret/type      (e.g. "postgres")
   /zabbix-dev/grafana-secret/host      (e.g. "mydb.rds.amazonaws.com:5432")
   /zabbix-dev/grafana-secret/dbname    (e.g. "grafana")
   /zabbix-dev/grafana-secret/user
   /zabbix-dev/grafana-secret/password
   /zabbix-dev/grafana-secret/sslMode   (e.g. "require")
   ```

4. **EKS Pod Identity** association for the ServiceAccount.

5. **IngressClass `alb-public`** with `IngressClassParams` configured.

---

## Installation

```bash
helm install grafana ./grafana-helm --namespace zabbix-dev --create-namespace
```

---

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `grafana.replicaCount` | Number of replicas | `1` |
| `grafana.image.repository` | Image repository | `grafana/grafana` |
| `grafana.image.tag` | Image tag | `13.2.2` |
| `grafana.plugins` | Plugins to install | `alexanderzobnin-zabbix-app` |
| `grafana.serviceAccount.create` | Create ServiceAccount | `true` |
| `grafana.database.ssm.path` | SSM path for DB creds | `/zabbix-dev/grafana-secret` |
| `grafana.database.ssm.region` | AWS region | `ap-south-1` |
| `grafana.rootUrl` | GF_SERVER_ROOT_URL | `https://%(domain)s/` |
| `grafana.service.enabled` | Create Service | `true` |
| `grafana.service.port` | Service port | `80` |
| `grafana.service.targetPort` | Container port | `3000` |
| `grafana.resources.requests.cpu` | CPU request | `300m` |
| `grafana.resources.requests.memory` | Memory request | `512Mi` |
| `grafana.security.allowEmbedding` | Allow iframe embedding | `true` |
| `grafana.security.cookieSecure` | HTTPS-only cookies | `true` |
| `grafana.security.cookieSameSite` | SameSite attribute | `none` |
| `ingress.enabled` | Create Ingress | `true` |
| `ingress.className` | IngressClass | `alb-public` |
| `ingress.loadBalancerName` | Shared ALB name | `k8s-maas` |
| `ingress.grafanaHost` | Domain name | `dashboard.prestacknx.co.in` |
| `ingress.healthCheck.path` | Health check path | `/api/health` |
| `ingress.healthCheck.successCodes` | Success codes | `200` |

---

## Chart Structure

```
grafana-helm/
├── Chart.yaml                                    # Chart metadata (v0.1.0)
├── README.md                                     # This file
├── values.yaml                                   # Default configuration
├── docs/
│   └── eks-prerequisites.md                      # AWS EKS setup steps
└── templates/
    ├── _helpers.tpl                              # Template helper functions
    ├── NOTES.txt                                 # Post-install instructions
    ├── grafana-serviceaccount.yaml                # ServiceAccount (split out)
    ├── grafana-deployment.yaml                    # Deployment (split out)
    ├── grafana-service.yaml                       # Service (split out)
    └── grafana-ingress.yaml                       # Ingress (simplified)
```

---

## Troubleshooting

### Pods stuck in Init (ssm-init)
```bash
kubectl logs -n zabbix-dev -l app=grafana -c ssm-init
```

### Grafana CrashLoopBackOff
```bash
kubectl logs -n zabbix-dev -l app=grafana -c grafana --tail=50
# Common: wrong DB credentials, DB not reachable, missing SSM params
```

### Health check failing (ALB shows unhealthy targets)
```bash
# Verify /api/health returns 200
kubectl exec -n zabbix-dev deploy/grafana -- curl -s http://localhost:3000/api/health
```

---

## License

Internal — Platform Team
