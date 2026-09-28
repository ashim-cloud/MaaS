# Zabbix Server — Helm Chart

Standalone Helm chart for deploying the **Zabbix Server (Native HA)** on **AWS EKS** with external RDS PostgreSQL.

> This chart is a split from the monolithic `zabbix-helm` chart.  
> Each Zabbix component (server, web, aws-monitor, etc.) is now its own chart for **easier troubleshooting, independent scaling, and focused upgrades**.

---

## Architecture

```
                                ┌─────────────────────────────┐
                                │     External Zabbix Agents   │
                                │   (connect on port 10051)    │
                                └──────────────┬──────────────┘
                                               │
                                ┌──────────────▼──────────────┐
                                │     AWS NLB (internet-facing)│
                                │  zabbix-server-active :10051 │
                                │  selector: role=active       │
                                └──────────────┬──────────────┘
                                               │
                    ┌──────────────────────────┬┴────────────────────────────┐
                    │                          │                            │
         ┌──────────▼──────────┐    ┌──────────▼──────────┐                 │
         │  zabbix-server-0    │    │  zabbix-server-1    │    (N replicas) │
         │  ┌───────────────┐  │    │  ┌───────────────┐  │                 │
         │  │  ssm-init     │  │    │  │  ssm-init     │  │                 │
         │  │  (initCont.)  │  │    │  │  (initCont.)  │  │                 │
         │  └──────┬────────┘  │    │  └──────┬────────┘  │                 │
         │         ↓           │    │         ↓           │                 │
         │  /secrets/ (Memory) │    │  /secrets/ (Memory) │                 │
         │     ↓          ↓    │    │     ↓          ↓    │                 │
         │  ┌──────┐ ┌──────┐  │    │  ┌──────┐ ┌──────┐  │                 │
         │  │server│ │HA    │  │    │  │server│ │HA    │  │                 │
         │  │      │ │side- │  │    │  │      │ │side- │  │                 │
         │  │:10051│ │car   │  │    │  │:10051│ │car   │  │                 │
         │  └──────┘ └──┬───┘  │    │  └──────┘ └──┬───┘  │                 │
         │  role=active │      │    │  role=standby│      │                 │
         └──────────────┼──────┘    └──────────────┼──────┘                 │
                        │                          │                        │
                        └──────────┬───────────────┘                        │
                                   │  polls ha_node table                   │
                        ┌──────────▼──────────┐                             │
                        │  RDS PostgreSQL     │                             │
                        │  (external DB)      │                             │
                        └─────────────────────┘                             │
                                                                            │
         ┌───────────────────────────────────────────────────────────────────┘
         │  Headless Service (zabbix-server) — StatefulSet pod DNS
         │  zabbix-server-0.zabbix-server.<ns>.svc.cluster.local
         └───────────────────────────────────────────────────────────────────
```

---

## Resources Created

| File | Kubernetes Resource | Description |
|------|-------------------|-------------|
| `zabbix-server-serviceaccount.yaml` | `ServiceAccount` | HA sidecar + Pod Identity for SSM/IAM access |
| `zabbix-server-role.yaml` | `Role` | Namespace-scoped — get/list/patch pods |
| `zabbix-server-rolebinding.yaml` | `RoleBinding` | Binds Role to ServiceAccount |
| `zabbix-server-statefulset.yaml` | `StatefulSet` | Zabbix Server (HA) with ssm-init + ha-label-sidecar |
| `zabbix-server-service-headless.yaml` | `Service` (Headless) | StatefulSet pod DNS (clusterIP: None) |
| `zabbix-server-service-nlb.yaml` | `Service` (LoadBalancer) | NLB for external agents — routes to active pod only |

---

## Prerequisites

Before installing this chart, ensure the following:

1. **Namespace** exists:
   ```bash
   kubectl create namespace zabbix-dev
   ```

2. **RDS PostgreSQL** database reachable from the EKS cluster with:
   - Zabbix database created
   - Zabbix user with appropriate permissions
   - Security group allowing inbound from EKS node security group

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
     --service-account <RELEASE>-ha-sidecar \
     --role-arn arn:aws:iam::<ACCOUNT>:role/<ROLE_NAME>
   ```

6. **AWS Load Balancer Controller** installed in the cluster (for NLB).

---

## Installation

### Quick Install

```bash
helm install zabbix ./zabbix-server-helm \
  --namespace zabbix-dev \
  --create-namespace
```

### Install with Custom Values

```bash
helm install zabbix ./zabbix-server-helm \
  --namespace zabbix-dev \
  --create-namespace \
  -f my-values.yaml
```

### Upgrade

```bash
helm upgrade zabbix ./zabbix-server-helm \
  --namespace zabbix-dev
```

---

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `zabbix.version` | Zabbix version (image tag) | `7.0.30` |
| `zabbix.baseImage` | Base image variant | `ubuntu` |
| `zabbixServer.replicaCount` | Number of HA replicas | `2` |
| `zabbixServer.image.repository` | Server image repository | `zabbix/zabbix-server-pgsql` |
| `zabbixServer.affinity.type` | Anti-affinity: `preferred` or `required` | `preferred` |
| `zabbixServer.affinity.weight` | Anti-affinity weight (1-100) | `100` |
| `zabbixServer.serviceAccount.create` | Create the ServiceAccount | `true` |
| `zabbixServer.rbac.create` | Create Role + RoleBinding | `true` |
| `zabbixServer.haSidecar.image` | Sidecar image (needs kubectl + psql) | `alpine/k8s:1.31.0` |
| `zabbixServer.haSidecar.labelName` | HA role label key | `role` |
| `zabbixServer.haSidecar.pollIntervalSeconds` | HA poll interval | `60` |
| `zabbixServer.ssmInit.image` | AWS CLI image for SSM fetch | `public.ecr.aws/aws-cli/aws-cli:latest` |
| `zabbixServer.ssmInit.region` | AWS region for SSM | `ap-south-1` |
| `zabbixServer.ssmInit.parameterPath` | SSM path prefix for DB creds | `/zabbix-dev/zabbix-db-secret` |
| `zabbixServer.headlessService.enabled` | Deploy headless Service | `true` |
| `zabbixServer.nlbService.enabled` | Deploy NLB Service | `true` |
| `zabbixServer.nlbService.loadBalancerName` | Custom name for the AWS NLB | `maas` |
| `zabbixServer.nlbService.scheme` | NLB scheme | `internet-facing` |
| `zabbixServer.nlbService.preserveClientIp` | Preserve client IP | `true` |
| `vpc.publicSubnetIds` | Public subnets for NLB | *(set in values)* |

---

## Chart Structure

```
zabbix-server-helm/
├── Chart.yaml                                       # Chart metadata (v0.1.0)
├── values.yaml                                      # Default configuration
├── README.md                                        # This file
└── templates/
    ├── _helpers.tpl                                 # Template helper functions
    ├── NOTES.txt                                    # Post-install instructions
    ├── zabbix-server-serviceaccount.yaml             # ServiceAccount (HA sidecar + Pod Identity)
    ├── zabbix-server-role.yaml                       # Role (pod get/list/patch)
    ├── zabbix-server-rolebinding.yaml                # RoleBinding
    ├── zabbix-server-statefulset.yaml                # StatefulSet (server + sidecar)
    ├── zabbix-server-service-headless.yaml            # Headless Service (pod DNS)
    └── zabbix-server-service-nlb.yaml                # NLB Service (external agents)
```

---

## HA Behavior

### How Native HA Works

1. **StatefulSet** deploys N replicas (default: 2) — each runs `zabbix-server` with `ZBX_HANODENAME` set to the pod name.
2. Zabbix Server uses PostgreSQL's `ha_node` table for leader election — one pod becomes **active**, the rest are **standby**.
3. The **HA label sidecar** in each pod polls the `ha_node` table every 60 seconds and patches the pod's `role` label:
   - `role=active` — this pod is the current leader
   - `role=standby` — this pod is on standby
4. The **NLB Service** selects only `role=active` pods, so external agents always connect to the active node.
5. If the active node fails, Zabbix HA automatically promotes a standby node. The sidecar detects the change and updates labels within 60 seconds.

### Failover Timeline

```
T+0s    Active pod fails
T+~30s  Zabbix HA detects failure, promotes standby in ha_node table
T+~60s  Sidecar on new active pod detects role change, patches label
T+~60s  NLB routes traffic to the new active pod
```

---

## Troubleshooting

### Pods stuck in Init (ssm-init)

```bash
# Check ssm-init logs
kubectl logs -n zabbix-dev <pod-name> -c ssm-init

# Verify Pod Identity association
aws eks list-pod-identity-associations \
  --cluster-name <CLUSTER_NAME> \
  --namespace zabbix-dev

# Verify SSM parameters exist
aws ssm get-parameters-by-path \
  --path "/zabbix-dev/zabbix-db-secret" \
  --with-decryption \
  --query "Parameters[*].Name"
```

### Server CrashLoopBackOff

```bash
# Check server container logs
kubectl logs -n zabbix-dev <pod-name> -c zabbix-server --tail=50

# Common causes:
# - Database not reachable (check RDS security groups)
# - Database not initialized (first install requires schema creation)
# - Wrong DB credentials in SSM
```

### HA labels not being set

```bash
# Check sidecar logs
kubectl logs -n zabbix-dev <pod-name> -c ha-label-sidecar --tail=50

# Verify RBAC permissions
kubectl auth can-i get pods -n zabbix-dev \
  --as=system:serviceaccount:zabbix-dev:zabbix-ha-sidecar

kubectl auth can-i patch pods -n zabbix-dev \
  --as=system:serviceaccount:zabbix-dev:zabbix-ha-sidecar

# Check current labels
kubectl get pods -n zabbix-dev -l app=zabbix-server --show-labels
```

### NLB not provisioning

```bash
# Check NLB service status
kubectl describe svc zabbix-server-active -n zabbix-dev

# Check AWS LB Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

### No active pod (NLB has no targets)

```bash
# Check HA status from inside a server pod
kubectl exec -n zabbix-dev zabbix-server-0 -- zabbix_server -R ha_status

# Query ha_node table directly
kubectl exec -n zabbix-dev zabbix-server-0 -c ha-label-sidecar -- \
  sh -c 'PGPASSWORD=$(cat /secrets/password) psql -h $(cat /secrets/host) \
    -p $(cat /secrets/port) -U $(cat /secrets/user) -d $(cat /secrets/dbname) \
    -c "SELECT * FROM ha_node;"'
```

---

## Migrating from Monolithic Chart

If you're migrating from the monolithic `zabbix-helm` chart:

1. Resource names remain identical when using the same release name (e.g., `zabbix`).
2. Values structure is slightly reorganized:
   - `zabbixServer.service.nlb.*` → `zabbixServer.nlbService.*`
   - New flags: `serviceAccount.create`, `rbac.create`, `headlessService.enabled`, `nlbService.enabled`
3. Install this chart **before** removing the server resources from the monolithic chart to avoid downtime.
4. The StatefulSet uses the same `serviceName`, so existing persistent pod DNS names are preserved.

---

## License

Internal — Platform Team
