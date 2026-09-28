# AWS EKS Prerequisites — Zabbix Server (Native HA)

> **One-time cluster-level prerequisites for the Zabbix Server Helm chart.**
> Complete these steps once per EKS cluster before deploying the Zabbix Server chart.

---

## Variables

Set all variables before running any commands.

```bash
# ── Cluster ───────────────────────────────────────────────────────────────────
CLUSTER_NAME="MaaS-EKS-Dev-Cluster"
NAMESPACE="zabbix-dev"
VPC_ID="vpc-0bc5c5ce263d7b3a0"

# ── Auto-detected (from aws configure / sts) ─────────────────────────────────
AWS_REGION="$(aws configure list | grep region | tr -s " " | cut -d" " -f3)"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ── Tagging ───────────────────────────────────────────────────────────────────
PROJECT_NAME="MaaS"
OWNER="Deployment_Team"
ENVIRONMENT="Development"

# ── SSM Parameter Store paths ────────────────────────────────────────────────
KMS_KEY_ID="788d503f-fefb-4d71-bffe-da6e5ed81224"
ZABBIX_SSM_PATH="/${NAMESPACE}/zabbix-db-secret"
```

> **Verify auto-detected values before proceeding:**
> ```bash
> echo "Region:  $AWS_REGION"
> echo "Account: $AWS_ACCOUNT_ID"
> ```

---

## Step 1: Create Namespace

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

---

## Step 2: Store Zabbix DB Credentials in SSM Parameter Store

> **Skip if already done for zabbix-web-helm.**
> Both Zabbix Server and Web share the same SSM path and IAM role.

Replace placeholder values with your actual RDS endpoint and credentials.

```bash
for key_value in \
  "host=YOUR_RDS_ENDPOINT" \
  "port=5432" \
  "dbname=zabbix" \
  "user=zabbix" \
  "password=YOUR_ZABBIX_DB_PASSWORD"
do
  key=$(echo "$key_value" | cut -d= -f1)
  value=$(echo "$key_value" | cut -d= -f2-)
  aws ssm put-parameter \
    --name "${ZABBIX_SSM_PATH}/${key}" \
    --value "$value" \
    --type SecureString \
    --key-id "$KMS_KEY_ID" \
    --overwrite \
    --region "$AWS_REGION"
  echo "Created/Updated: ${ZABBIX_SSM_PATH}/${key}"
done
```

Verify (should see 5 entries: `host`, `port`, `dbname`, `user`, `password`):

```bash
aws ssm get-parameters-by-path \
  --path "$ZABBIX_SSM_PATH" \
  --with-decryption \
  --recursive \
  --query "Parameters[*].Name" \
  --output table \
  --region "$AWS_REGION"
```

---

## Step 3: Create IAM Role for Zabbix Pod Identity

> **Skip if already done for zabbix-web-helm.**
> Both Zabbix Server and Web share the same IAM role.

### 3a: Create Trust Policy

```bash
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEksAuthToAssumeRoleForPodIdentity",
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF
```

### 3b: Create IAM Role

```bash
ZABBIX_ROLE_NAME="${NAMESPACE}-zabbix-pod-identity-role-${PROJECT_NAME}"

aws iam get-role --role-name "$ZABBIX_ROLE_NAME" 2>/dev/null && {
  echo "Role $ZABBIX_ROLE_NAME already exists — skipping creation"
} || {
  aws iam create-role \
    --role-name "$ZABBIX_ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "IAM role for Zabbix Server and Zabbix Web EKS Pod Identity to access Zabbix secrets in SSM Parameter Store" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created role: $ZABBIX_ROLE_NAME"
}
```

### 3c: Attach inline policy (SSM + KMS permissions)

```bash
cat > zabbix-ssm-kms-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSMReadZabbixSecrets",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": [
        "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${ZABBIX_SSM_PATH}",
        "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${ZABBIX_SSM_PATH}/*"
      ]
    },
    {
      "Sid": "KMSDecryptForSSM",
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${KMS_KEY_ID}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$ZABBIX_ROLE_NAME" \
  --policy-name zabbix-ssm-kms-read \
  --policy-document file://zabbix-ssm-kms-policy.json

echo "Attached inline policy: zabbix-ssm-kms-read"
```

Verify:

```bash
aws iam get-role-policy \
  --role-name "$ZABBIX_ROLE_NAME" \
  --policy-name zabbix-ssm-kms-read \
  --query "PolicyDocument" \
  --output json
```

---

## Step 4: Create Pod Identity Association for Zabbix Server

> **ℹ️ Note:** Pod Identity associations are AWS-level configuration rules that
> map a (namespace, ServiceAccount name) pair to an IAM role. The ServiceAccount
> does **not** need to exist in the cluster before creating the association.
> When Helm creates the ServiceAccount (`zabbix-ha-sidecar`) and its Pods, the
> EKS Pod Identity Agent will automatically detect the match and inject IAM credentials.

```bash
ZABBIX_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ZABBIX_ROLE_NAME}"

EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --service-account zabbix-ha-sidecar \
  --region "$AWS_REGION" \
  --query "associations[0].associationId" \
  --output text 2>/dev/null)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "Pod Identity association for zabbix-ha-sidecar already exists: $EXISTING"
else
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" \
    --service-account zabbix-ha-sidecar \
    --role-arn "$ZABBIX_ROLE_ARN" \
    --region "$AWS_REGION" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created Pod Identity association for zabbix-ha-sidecar"
fi
```

> **ServiceAccount name** is derived from the Helm release name:
> - `zabbix-ha-sidecar` — Zabbix Server StatefulSet (`<release>-ha-sidecar`)
>
> If your release name is not `zabbix`, substitute accordingly.

Verify:

```bash
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --region "$AWS_REGION" \
  --output table
```

---

## Step 5: RDS PostgreSQL Database

The Zabbix Server requires an external PostgreSQL database (RDS).

### 5a: Verify RDS connectivity

Ensure the EKS cluster can reach the RDS instance:

```bash
# Verify security groups allow traffic from EKS node subnets to RDS port 5432
# The RDS security group must have an inbound rule:
#   Port 5432 — Source: EKS node security group or VPC CIDR
```

### 5b: Initialize the Zabbix database (first install only)

On first install, Zabbix Server will automatically create the schema. If it fails
(e.g., the database user lacks `CREATE TABLE` permissions), you may need to
manually import the schema:

```bash
# Download the Zabbix schema for your version
# See: https://www.zabbix.com/documentation/current/en/manual/appendix/install/db_scripts

# Import into the RDS database
psql -h YOUR_RDS_ENDPOINT -U zabbix -d zabbix < schema.sql
psql -h YOUR_RDS_ENDPOINT -U zabbix -d zabbix < images.sql
psql -h YOUR_RDS_ENDPOINT -U zabbix -d zabbix < data.sql
```

---

## Step 6: Verify Readiness

Before installing the Zabbix Server chart, confirm:

```bash
# 1. Namespace exists
kubectl get namespace "$NAMESPACE"

# 2. SSM parameters are accessible
aws ssm get-parameters-by-path \
  --path "$ZABBIX_SSM_PATH" \
  --with-decryption \
  --query "Parameters[*].Name" \
  --output table \
  --region "$AWS_REGION"

# 3. Pod Identity association exists
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --region "$AWS_REGION" \
  --output table

# 4. RDS is reachable (from a test pod if needed)
kubectl run pg-test --rm -it --restart=Never \
  --image=postgres:15-alpine \
  -n "$NAMESPACE" \
  -- psql "host=YOUR_RDS_ENDPOINT port=5432 dbname=zabbix user=zabbix password=YOUR_PASSWORD" \
  -c "SELECT 1;"

# 5. Nodes are ready
kubectl get nodes
```

---

## Step 7: Install Zabbix Server Helm Chart

```bash
helm install zabbix ./zabbix-server-helm \
  -n "$NAMESPACE"
```

---

## Post-Install: Verify HA

After pods are running:

```bash
# 1. Check pods
kubectl get pods -n "$NAMESPACE" -l app=zabbix-server -o wide

# 2. Check HA status
kubectl exec -n "$NAMESPACE" zabbix-server-0 -- zabbix_server -R ha_status

# 3. Verify HA labels (one pod = "active", rest = "standby")
kubectl get pods -n "$NAMESPACE" -l app=zabbix-server --show-labels

# 4. Get NLB address (for external agent clients)
kubectl get svc zabbix-server-active -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

External Zabbix agents should connect to the NLB hostname on **port 10051**.

---

## Post-Install: Verify Sidecar

```bash
# Check sidecar logs for HA role monitoring
kubectl logs -n "$NAMESPACE" zabbix-server-0 -c ha-label-sidecar --tail=20
kubectl logs -n "$NAMESPACE" zabbix-server-1 -c ha-label-sidecar --tail=20

# Check ssm-init logs (if pods are not starting)
kubectl logs -n "$NAMESPACE" zabbix-server-0 -c ssm-init
```
