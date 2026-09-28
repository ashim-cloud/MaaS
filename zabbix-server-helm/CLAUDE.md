# CLAUDE.md — Zabbix Server Helm Chart Context

> **AI assistant context file.** This document provides a complete overview of the
> `zabbix-server-helm` chart for AI-assisted development, troubleshooting, and code review.

---

## Chart Overview

| Field | Value |
|-------|-------|
| **Chart Name** | `zabbix-server` |
| **Chart Version** | `0.1.0` |
| **App Version** | `7.0.30` |
| **Type** | `application` |
| **Purpose** | Deploy Zabbix Server (Native HA) on AWS EKS with external RDS PostgreSQL |
| **Origin** | Split from monolithic `zabbix-helm` chart |

This chart is **one part** of a multi-chart Zabbix deployment:

| Chart | Component | Status |
|-------|-----------|--------|
| **`zabbix-server-helm`** | **Zabbix Server (HA StatefulSet)** | **This chart** |
| `zabbix-web-helm` | Zabbix Web Frontend | Separate chart |
| `zabbix-aws-monitor-helm` | CloudWatch Metric Fetcher | Separate chart |
| `zabbix-helm` | Original monolithic (all-in-one) | Legacy — do NOT modify |

---

## Directory Structure

```
zabbix-server-helm/
├── Chart.yaml                                    # Helm chart metadata
├── CLAUDE.md                                     # This file — AI context
├── README.md                                     # Human-readable documentation
├── values.yaml                                   # All configurable values
├── docs/
│   └── eks-prerequisites.md                      # AWS EKS setup steps (server-specific)
└── templates/
    ├── _helpers.tpl                              # Template helper functions
    ├── NOTES.txt                                 # Post-install CLI instructions
    ├── zabbix-server-serviceaccount.yaml         # ServiceAccount (HA sidecar + Pod Identity)
    ├── zabbix-server-role.yaml                   # Role (pod get/list/patch)
    ├── zabbix-server-rolebinding.yaml            # RoleBinding
    ├── zabbix-server-statefulset.yaml            # StatefulSet (server + ha-label-sidecar)
    ├── zabbix-server-service-headless.yaml       # Headless Service (pod DNS)
    └── zabbix-server-service-nlb.yaml            # NLB Service (external agents → active pod)
```

---

## NLB Architecture — Network Load Balancer

The NLB is provisioned by the **AWS Load Balancer Controller** via a Kubernetes Service
of `type: LoadBalancer` with AWS-specific annotations.

Key annotations on the NLB Service:

```yaml
annotations:
  service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
  service.beta.kubernetes.io/aws-load-balancer-name: "maas"              # custom NLB name
  service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing" # or "internal"
  service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: "preserve_client_ip.enabled=true"
  service.beta.kubernetes.io/aws-load-balancer-subnets: "subnet-xxx,subnet-yyy,subnet-zzz"
spec:
  type: LoadBalancer
  selector:
    app: zabbix-server
    role: active          # ← only the active HA node receives traffic
  ports:
    - port: 10051
      targetPort: 10051
```

The NLB name (`maas`) is configurable via `zabbixServer.nlbService.loadBalancerName`.
When set, it adds the `aws-load-balancer-name` annotation so the NLB is created with a
predictable, human-readable name in the AWS console instead of an auto-generated hash.

---

## Template Helpers (`_helpers.tpl`)

All helper names are prefixed with `zabbix-server.` to avoid collisions.

| Helper | Output (release=`zabbix-server`) | Used By |
|--------|----------------------------------|---------  |
| `zabbix-server.name` | `zabbix-server` | Labels |
| `zabbix-server.fullname` | `zabbix-server` (release name) | All name helpers |
| `zabbix-server.labels` | Standard Helm labels | All templates |
| `zabbix-server.statefulSetName` | `zabbix-server` (= release name) | StatefulSet, Headless Service |
| `zabbix-server.activeServiceName` | `zabbix-server-active` | NLB Service, NOTES.txt |
| `zabbix-server.serviceAccountName` | `zabbix-ha-sidecar` (hardcoded) | SA, StatefulSet, NOTES.txt |
| `zabbix-server.roleName` | `zabbix-server-ha-label-patcher` | Role |
| `zabbix-server.roleBindingName` | `zabbix-server-ha-label-patcher-binding` | RoleBinding |
| `zabbix-server.image` | `zabbix/zabbix-server-pgsql:ubuntu-7.0.30` | StatefulSet |
| `zabbix-server.subnetList` | `subnet-aaa,subnet-bbb,subnet-ccc` | NLB Service annotation |

---

## Resource Dependency Graph

```
ServiceAccount (zabbix-ha-sidecar)
      │
      ├──▶ Role (zabbix-ha-label-patcher)
      │        └── get, list, patch pods (namespace-scoped)
      │
      ├──▶ RoleBinding (zabbix-ha-label-patcher-binding)
      │        └── binds Role → ServiceAccount
      │
      └──▶ StatefulSet (zabbix-server)
               │
               ├── initContainer: ssm-init
               │     └── fetches SSM → writes /secrets/*
               │
               ├── container: zabbix-server
               │     ├── reads /secrets/* (DB creds)
               │     ├── ZBX_HANODENAME = pod hostname
               │     └── listens on :10051
               │
               ├── container: ha-label-sidecar
               │     ├── reads /secrets/* (DB creds)
               │     ├── installs postgresql-client
               │     ├── polls ha_node table every 60s
               │     └── patches pod label: role=active|standby
               │
               └── volumes:
                     └── secrets-vol (emptyDir: Memory)

Headless Service (<release>, clusterIP: None)
      └── pod DNS: <release>-0.<release>.<ns>.svc.cluster.local

NLB Service (<release>-active)
      ├── type: LoadBalancer
      ├── selector: app=zabbix-server, role=active
      ├── NLB name: "maas" (configurable)
      └── port: 10051 → 10051
```

---

## Values Structure

Key sections in `values.yaml`:

```yaml
zabbix:           # Global — version, baseImage
vpc:              # VPC ID, publicSubnetIds (for NLB subnet placement)
zabbixServer:     # Replicas, image, affinity, SA, RBAC, haSidecar, ssmInit, services
  ssmInit:        # SSM image, region, parameterPath (single source of truth for DB creds)
  nlbService:     # NLB enabled, loadBalancerName ("maas"), scheme, preserveClientIp
  headlessService: # Headless Service enabled
```

### Critical Values That Must Be Set

| Value | Why |
|-------|-----|
| `vpc.id` | VPC where the EKS cluster runs |
| `vpc.publicSubnetIds` | Subnets for NLB placement (minimum 2 AZs required by AWS) |
| `zabbixServer.ssmInit.parameterPath` | SSM path prefix for DB credentials |
| `zabbixServer.ssmInit.region` | AWS region where SSM parameters live |
| `zabbixServer.nlbService.loadBalancerName` | Custom NLB name (default: `maas`) |

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
     │  validates: all 5 keys exist and are non-empty
     │
     ▼
/secrets/* (emptyDir: medium: Memory — RAM-backed, never on disk)
     │
     ├──▶ zabbix-server container
     │      reads via: cat /secrets/host, etc.
     │      exports as: DB_SERVER_HOST, POSTGRES_USER, etc.
     │      then: exec docker-entrypoint.sh -f
     │
     └──▶ ha-label-sidecar container
            reads via: cat /secrets/host, etc.
            uses for: PGPASSWORD psql connections to ha_node table
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
| `zabbixServer.serviceAccount.create` | `true` | ServiceAccount creation |
| `zabbixServer.rbac.create` | `true` | Role + RoleBinding creation |
| `zabbixServer.headlessService.enabled` | `true` | Headless Service creation |
| `zabbixServer.nlbService.enabled` | `true` | NLB Service creation |

---

## HA Architecture

### How Native HA Works

1. **StatefulSet** deploys N replicas (default: 2) — each runs `zabbix-server` with `ZBX_HANODENAME` set to the pod name (hostname).
2. Zabbix Server uses PostgreSQL's `ha_node` table for leader election — one pod becomes **active** (status=3), the rest are **standby**.
3. The **ha-label-sidecar** in each pod:
   - Installs `postgresql-client` at startup (via `apk add`)
   - Verifies Kubernetes RBAC permissions (get/patch pods)
   - Tests PostgreSQL connectivity
   - Polls `ha_node` table every 60 seconds
   - Patches the pod's `role` label only when it changes (reduces API server load)
4. The **NLB Service** selects only `role=active` pods → external agents always connect to the active node.
5. On failover, Zabbix HA promotes a standby. The sidecar detects and updates labels within ~60 seconds.

### Failover Timeline

```
T+0s    Active pod fails
T+~30s  Zabbix HA detects failure, promotes standby in ha_node table
T+~60s  Sidecar on new active pod detects role change, patches label
T+~60s  NLB routes traffic to the new active pod
```

---

## External Dependencies

| Dependency | Purpose | Managed By |
|------------|---------|------------|
| AWS Load Balancer Controller | Provisions NLB from Service annotations | `aws-lb-controller-app.yaml` (ArgoCD) |
| EKS Pod Identity Agent | IAM credentials for SSM access | EKS cluster add-on |
| RDS PostgreSQL | Zabbix database + ha_node table | External (AWS) |
| SSM Parameter Store | DB credential storage | External (AWS) |
| KMS Key | Encrypts SSM SecureString parameters | External (AWS) |
| Zabbix Web (`zabbix-web-helm`) | Web frontend (connects to this server) | Separate chart |

---

## Common Operations

### Lint & Validate

```bash
helm lint ./zabbix-server-helm --namespace zabbix-dev
helm template zabbix ./zabbix-server-helm --namespace zabbix-dev
helm template zabbix ./zabbix-server-helm --namespace zabbix-dev | kubectl apply --dry-run=client -f -
```

### Install

```bash
helm install zabbix ./zabbix-server-helm --namespace zabbix-dev --create-namespace
```

### Upgrade

```bash
helm upgrade zabbix ./zabbix-server-helm --namespace zabbix-dev
```

### Uninstall

```bash
helm uninstall zabbix --namespace zabbix-dev
```

### Override Values

```bash
# Change Zabbix version
helm upgrade zabbix ./zabbix-server-helm -n zabbix-dev --set zabbix.version=7.0.31

# Change NLB name
helm upgrade zabbix ./zabbix-server-helm -n zabbix-dev --set zabbixServer.nlbService.loadBalancerName=my-nlb

# Remove custom NLB name (let AWS auto-generate)
helm upgrade zabbix ./zabbix-server-helm -n zabbix-dev --set zabbixServer.nlbService.loadBalancerName=""

# Change replica count
helm upgrade zabbix ./zabbix-server-helm -n zabbix-dev --set zabbixServer.replicaCount=3

# Switch to internal NLB
helm upgrade zabbix ./zabbix-server-helm -n zabbix-dev --set zabbixServer.nlbService.scheme=internal
```

---

## Naming Conventions

- **Files**: `zabbix-server-<resource-type>.yaml` (e.g., `zabbix-server-statefulset.yaml`)
- **Helper prefix**: `zabbix-server.` (e.g., `zabbix-server.statefulSetName`)
- **Labels**: All resources carry `app: zabbix-server` and `app.kubernetes.io/component: server`
- **Resource names**: StatefulSet + headless Service = release name directly (e.g., release `zabbix-server` → StatefulSet `zabbix-server`, pods `zabbix-server-0`)
- **ServiceAccount**: Always `zabbix-ha-sidecar` (hardcoded, not derived from release name)

---

## Known Behaviors & Gotchas

1. **NLB has no targets initially**: Until the ha-label-sidecar sets the `role=active` label on a pod, NO pods match the NLB selector. This is intentional — no traffic until HA election completes.

2. **Sidecar installs postgresql-client at runtime**: The ha-label-sidecar runs `apk add --no-cache postgresql-client` at startup. This means the first startup takes longer (network dependency). If Alpine repos are unreachable, the sidecar will fail.

3. **ssm-init uses `latest` tag**: The init container image (`public.ecr.aws/aws-cli/aws-cli:latest`) uses `latest`. This is intentional for always getting the latest AWS CLI, but can be pinned in values if needed.

4. **Memory-backed secrets volume**: The `secrets-vol` uses `emptyDir: medium: Memory`. Credentials exist only in RAM and are never written to disk. This is a security feature, not a bug.

5. **StatefulSet never uses `replicas` from HPA**: Unlike the web chart, the server chart has a fixed `replicaCount` (no HPA). Zabbix HA handles active/standby — not Kubernetes autoscaling.

6. **Pod anti-affinity is "preferred" by default**: Set `zabbixServer.affinity.type=required` if you need hard anti-affinity (pods will NOT schedule on the same node, but may fail to schedule if nodes < replicas).

7. **`ZBX_HANODENAME` = pod hostname**: The HA node name in Postgres matches the StatefulSet pod name (e.g., `zabbix-server-0`). Do NOT change the StatefulSet naming without understanding the impact on HA state.

8. **Sidecar only patches labels on change**: The sidecar compares current vs desired label before calling `kubectl label`. This minimizes API server load in the steady state.

9. **NLB name (`maas`)**: The `loadBalancerName` value sets `aws-load-balancer-name` annotation. Changing this on an existing deployment will cause the AWS Load Balancer Controller to **delete the old NLB and create a new one** (new DNS hostname). Plan accordingly.

---

## Related Files in Other Charts

| This Chart File | Equivalent in Monolithic `zabbix-helm` |
|-----------------|---------------------------------------|
| `zabbix-server-serviceaccount.yaml` | `server-services.yaml` (SA section) |
| `zabbix-server-role.yaml` | `server-services.yaml` (Role section) |
| `zabbix-server-rolebinding.yaml` | `server-services.yaml` (RoleBinding section) |
| `zabbix-server-statefulset.yaml` | `server-statefulset.yaml` |
| `zabbix-server-service-headless.yaml` | `server-services.yaml` (headless Service) |
| `zabbix-server-service-nlb.yaml` | `server-services.yaml` (NLB Service) |

## Related Infrastructure Files

| File | Purpose |
|------|---------|
| `aws-loadbalance-controller/aws-lb-controller-app.yaml` | ArgoCD Application for AWS LB Controller |
| `argocd/maas-project.yaml` | ArgoCD AppProject |
| `zabbix-web-helm/` | Web frontend chart (depends on this server) |
| `zabbix-helm/` | Original monolithic chart (legacy reference) |
