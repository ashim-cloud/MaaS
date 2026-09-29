# AWS EKS Prerequisites — Zabbix Web Frontend

> **One-time cluster-level prerequisites for the Zabbix Web Helm chart.**
> Complete these steps once per EKS cluster before deploying the Zabbix Web chart.

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

> **Skip if already done for zabbix-server-helm.**
> Both Zabbix Web and Zabbix Server share the same SSM path and IAM role.

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

> **Skip if already done for zabbix-server-helm.**
> Both Zabbix Web and Server share the same IAM role.

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

---

## Step 4: Create Pod Identity Association for Zabbix Web

> **ℹ️ Note:** Pod Identity associations are AWS-level configuration rules that
> map a (namespace, ServiceAccount name) pair to an IAM role. The ServiceAccount
> does **not** need to exist in the cluster before creating the association.
> When Helm creates the ServiceAccount (`zabbix-web-sa`) and its Pods, the EKS
> Pod Identity Agent will automatically detect the match and inject IAM credentials.

```bash
ZABBIX_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ZABBIX_ROLE_NAME}"

EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --service-account zabbix-web-sa \
  --region "$AWS_REGION" \
  --query "associations[0].associationId" \
  --output text 2>/dev/null)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "Pod Identity association for zabbix-web-sa already exists: $EXISTING"
else
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" \
    --service-account zabbix-web-sa \
    --role-arn "$ZABBIX_ROLE_ARN" \
    --region "$AWS_REGION" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created Pod Identity association for zabbix-web-sa"
fi
```

> **ServiceAccount name** is derived from the Helm release name:
> - `zabbix-web-sa` — Zabbix Web Deployment (`<release>-web-sa`)
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

## Step 5: Verify Readiness

Before installing the Zabbix Web chart, confirm:

```bash
# 1. IngressClass "alb-public" exists (created by alb-defaults.yaml)
kubectl get ingressclass alb-public

# 2. IngressClassParams "maas-public-alb" exists
kubectl get ingressclassparams maas-public-alb

# 3. Zabbix Server is deployed and running
kubectl get pods -n "$NAMESPACE" -l app=zabbix-server

# 4. Zabbix Server active service exists
kubectl get svc zabbix-server-active -n "$NAMESPACE"

# 5. Pod Identity association for zabbix-web-sa exists
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --region "$AWS_REGION" \
  --output table
```

---

## Step 6: Install Zabbix Web Helm Chart

```bash
helm install zabbix ./zabbix-web-helm \
  -n "$NAMESPACE"
```

---

## Post-Install: DNS Configuration

After the ALB rule is provisioned:

```bash
# Get the ALB hostname
ALB_HOSTNAME=$(kubectl get ingress zabbix-web-ingress \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB Hostname: $ALB_HOSTNAME"
```

In **Route53** (or your DNS provider), create an **ALIAS** (or CNAME) record:

```
monitoring.prestacknx.co.in  →  $ALB_HOSTNAME
```

Verify:

```bash
curl -I "https://monitoring.prestacknx.co.in/"
```

Default Zabbix login: **Admin / zabbix**
