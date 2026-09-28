# AWS EKS Prerequisites — Grafana Dashboard

> **One-time cluster-level prerequisites for the Grafana Helm chart.**
> Complete these steps once per EKS cluster before deploying the Grafana chart.

---

## Variables

Set all variables before running any commands.

```bash
# ── Cluster ───────────────────────────────────────────────────────────────────
CLUSTER_NAME="MaaS-EKS-Dev-Cluster"
NAMESPACE="zabbix-dev"

# ── Auto-detected (from aws configure / sts) ─────────────────────────────────
AWS_REGION="$(aws configure list | grep region | tr -s " " | cut -d" " -f3)"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ── Tagging ───────────────────────────────────────────────────────────────────
PROJECT_NAME="MaaS"
OWNER="Deployment_Team"
ENVIRONMENT="Development"

# ── SSM Parameter Store paths ────────────────────────────────────────────────
KMS_KEY_ID="788d503f-fefb-4d71-bffe-da6e5ed81224"
GRAFANA_SSM_PATH="/${NAMESPACE}/grafana-secret"
```

> **Verify auto-detected values before proceeding:**
> ```bash
> echo "Region:  $AWS_REGION"
> echo "Account: $AWS_ACCOUNT_ID"
> ```

---

## Step 1: Create Namespace

> **Skip if already created for other Zabbix charts.**

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

---

## Step 2: Store Grafana DB Credentials in SSM Parameter Store

Grafana database credentials are stored as SSM SecureString parameters and
injected into the Grafana pod at startup via an initContainer. No Kubernetes
Secret is created — credentials never touch etcd or EC2 disk.

Replace placeholder values with your actual RDS endpoint and credentials.

```bash
for key_value in \
  "type=postgres" \
  "host=YOUR_RDS_ENDPOINT:5432" \
  "dbname=grafana" \
  "user=grafana" \
  "password=YOUR_GRAFANA_DB_PASSWORD" \
  "sslMode=require"
do
  key=$(echo "$key_value" | cut -d= -f1)
  value=$(echo "$key_value" | cut -d= -f2-)
  aws ssm put-parameter \
    --name "${GRAFANA_SSM_PATH}/${key}" \
    --value "$value" \
    --type SecureString \
    --key-id "$KMS_KEY_ID" \
    --overwrite \
    --region "$AWS_REGION"
  echo "Created/Updated: ${GRAFANA_SSM_PATH}/${key}"
done
```

Verify (should see 6 entries: `type`, `host`, `dbname`, `user`, `password`, `sslMode`):

```bash
aws ssm get-parameters-by-path \
  --path "$GRAFANA_SSM_PATH" \
  --with-decryption \
  --recursive \
  --query "Parameters[*].Name" \
  --output table \
  --region "$AWS_REGION"
```

---

## Step 3: Create IAM Role for Grafana Pod Identity

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
GRAFANA_ROLE_NAME="${NAMESPACE}-grafana-pod-identity-role-${PROJECT_NAME}"

aws iam get-role --role-name "$GRAFANA_ROLE_NAME" 2>/dev/null && {
  echo "Role $GRAFANA_ROLE_NAME already exists — skipping creation"
} || {
  aws iam create-role \
    --role-name "$GRAFANA_ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "IAM role for Grafana EKS Pod Identity to access Grafana secrets in SSM Parameter Store" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created role: $GRAFANA_ROLE_NAME"
}
```

### 3c: Attach inline policy (SSM + KMS permissions)

```bash
cat > grafana-ssm-kms-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSMReadGrafanaSecrets",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": [
        "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${GRAFANA_SSM_PATH}",
        "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${GRAFANA_SSM_PATH}/*"
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
  --role-name "$GRAFANA_ROLE_NAME" \
  --policy-name grafana-ssm-kms-read \
  --policy-document file://grafana-ssm-kms-policy.json

echo "Attached inline policy: grafana-ssm-kms-read"
```

Verify:

```bash
aws iam get-role-policy \
  --role-name "$GRAFANA_ROLE_NAME" \
  --policy-name grafana-ssm-kms-read \
  --query "PolicyDocument" \
  --output json
```

---

## Step 4: Create Pod Identity Association for Grafana

> **ℹ️ Note:** Pod Identity associations are AWS-level configuration rules that
> map a (namespace, ServiceAccount name) pair to an IAM role. The ServiceAccount
> does **not** need to exist in the cluster before creating the association.
> When Helm creates the ServiceAccount (`grafana-sa`) and its Pods, the EKS
> Pod Identity Agent will automatically detect the match and inject IAM credentials.

```bash
GRAFANA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${GRAFANA_ROLE_NAME}"

EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --service-account grafana-sa \
  --region "$AWS_REGION" \
  --query "associations[0].associationId" \
  --output text 2>/dev/null)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "Pod Identity association for grafana-sa already exists: $EXISTING"
else
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" \
    --service-account grafana-sa \
    --role-arn "$GRAFANA_ROLE_ARN" \
    --region "$AWS_REGION" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created Pod Identity association for grafana-sa"
fi
```

> **ServiceAccount name** is derived from the Helm release name:
> - `grafana-sa` — Grafana Deployment (`<release>-sa`)
>
> If your release name is not `grafana`, substitute accordingly.

Verify:

```bash
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --region "$AWS_REGION" \
  --output table
```

---

## Step 5: Verify Readiness

Before installing the Grafana chart, confirm:

```bash
# 1. Namespace exists
kubectl get namespace "$NAMESPACE"

# 2. IngressClass "alb-public" exists (created by alb-defaults.yaml)
kubectl get ingressclass alb-public

# 3. IngressClassParams "maas-public-alb" exists
kubectl get ingressclassparams maas-public-alb

# 4. SSM parameters are accessible
aws ssm get-parameters-by-path \
  --path "$GRAFANA_SSM_PATH" \
  --with-decryption \
  --query "Parameters[*].Name" \
  --output table \
  --region "$AWS_REGION"

# 5. Pod Identity association exists
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --region "$AWS_REGION" \
  --output table

# 6. RDS is reachable (from a test pod if needed)
kubectl run pg-test --rm -it --restart=Never \
  --image=postgres:15-alpine \
  -n "$NAMESPACE" \
  -- psql "host=YOUR_RDS_ENDPOINT port=5432 dbname=grafana user=grafana password=YOUR_PASSWORD sslmode=require" \
  -c "SELECT 1;"
```

---

## Step 6: Install Grafana Helm Chart

```bash
helm install grafana ./grafana-helm \
  -n "$NAMESPACE"
```

---

## Post-Install: DNS Configuration

After the ALB rule is provisioned:

```bash
# Get the ALB hostname
ALB_HOSTNAME=$(kubectl get ingress grafana-ingress \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB Hostname: $ALB_HOSTNAME"
```

In **Route53** (or your DNS provider), create an **ALIAS** (or CNAME) record:

```
dashboard.prestacknx.co.in  →  $ALB_HOSTNAME
```

Verify:

```bash
curl -I "https://dashboard.prestacknx.co.in/api/health"
```

Default Grafana login: **admin / admin**
(You will be prompted to change the password on first login)

---

## Post-Install: Verify

```bash
# 1. Check pod is Running
kubectl get pods -n "$NAMESPACE" -l app=grafana -o wide

# 2. Check Grafana logs
kubectl logs -n "$NAMESPACE" -l app=grafana -c grafana --tail=20

# 3. Check ssm-init logs (if pods are not starting)
kubectl logs -n "$NAMESPACE" -l app=grafana -c ssm-init

# 4. Verify health endpoint
kubectl exec -n "$NAMESPACE" deploy/grafana -- \
  curl -s http://localhost:3000/api/health
```