# AWS EKS Prerequisites — One-Time Cluster Setup

> **This is a one-time cluster-level prerequisite, completely separate from the
> Zabbix Helm chart.** You must complete these steps once per EKS cluster before
> the Zabbix chart's NLB (zabbix-server-active) and ALB (zabbix-web-ingress)
> resources can be provisioned.

---

## Variables

Set all variables before running any commands. Auto-detected values (`AWS_REGION`,
`AWS_ACCOUNT_ID`) are resolved at runtime — verify they are correct before proceeding.

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
ZABBIX_API_PATH="/${NAMESPACE}/zabbix-api-token"

# ── CloudWatch Metric Fetcher ─────────────────────────────────────────────
FETCH_CLOUDWATCH_METRIC_ROLE_NAME="${NAMESPACE}-fetch-cloudWatch-metric-pod-identity-role-${PROJECT_NAME}"

# ── Karpenter ─────────────────────────────────────────────────────────────────
KARPENTER_NAMESPACE="kube-system"
KARPENTER_VERSION="1.14.0"
K8S_VERSION="1.36"
AWS_PARTITION="aws"
TEMPOUT="$(mktemp)"

# ── AWS Load Balancer Controller ──────────────────────────────────────────────
LBC_VERSION="v2.14.1"
LBC_CHART_VERSION="3.4.1"
```

> **Verify auto-detected values before proceeding:**
> ```bash
> echo "Region:  $AWS_REGION"
> echo "Account: $AWS_ACCOUNT_ID"
> ```

---

## Step 1: Install Tools

### 1a: Install eksctl

```bash
# Check if already installed
eksctl version 2>/dev/null && echo "eksctl already installed" || {
  ARCH=amd64
  PLATFORM=$(uname -s)_$ARCH
  curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
  curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check
  tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
  sudo install -m 0755 /tmp/eksctl /usr/local/bin && rm /tmp/eksctl
}

# Verify
eksctl version
```

### 1b: Install Helm

```bash
# Check if already installed
helm version 2>/dev/null && echo "Helm already installed" || {
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
  chmod 700 get_helm.sh
  ./get_helm.sh
}

# Verify
helm version
```

### 1c: Install kubectl

```bash
# Check if already installed
kubectl version --client 2>/dev/null && echo "kubectl already installed" || {
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
  echo "$(cat kubectl.sha256) kubectl" | sha256sum --check
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
}

# Verify
kubectl version --client

# Update kubeconfig for the target cluster
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
```

---

## Step 2: OIDC Configuration

The OIDC provider is required for IRSA and as a cluster identity anchor.

```bash
# Associate the OIDC provider (idempotent — safe to re-run)
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --approve \
  --region "$AWS_REGION"

# Get the OIDC endpoint
OIDC_ENDPOINT="$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --query "cluster.identity.oidc.issuer" \
  --output text)"

echo "OIDC Endpoint: $OIDC_ENDPOINT"

# Build the IAM OIDC provider ARN
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT#https://}"

echo "OIDC Provider ARN: $OIDC_PROVIDER_ARN"

# Tag the OIDC provider
aws iam tag-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
  --tags \
    Key=Owner,Value="$OWNER" \
    Key=Project,Value="$PROJECT_NAME" \
    Key=Environment,Value="$ENVIRONMENT"

# Tag the cluster with karpenter discovery tag (skip if already present)
aws eks tag-resource \
  --resource-arn "$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --query 'cluster.arn' \
    --output text)" \
  --tags "karpenter.sh/discovery=${CLUSTER_NAME}"
```

Verify:

```bash
# Confirm OIDC provider exists
aws iam list-open-id-connect-providers | grep "${OIDC_ENDPOINT#https://}"

# Confirm cluster tag
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.tags" \
  --output table
```

---

## Step 3: Create Namespace

```bash
# Check if namespace already exists
kubectl get namespace "$NAMESPACE" 2>/dev/null && echo "Namespace $NAMESPACE already exists" || {
  kubectl create namespace "$NAMESPACE"
  echo "Created namespace: $NAMESPACE"
}

# Verify
kubectl get namespace "$NAMESPACE"
```

---

## Step 4: Trust Policy (Shared)

This trust policy is used by all Pod Identity IAM roles (Zabbix, Karpenter, LBC).
Create it once — it is referenced by all subsequent `create-role` commands.

```bash
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
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

echo "trust-policy.json created"
cat trust-policy.json
```

---

## Step 5: Zabbix DB Secrets — SSM Parameter Store + Pod Identity

Zabbix Server and Zabbix Web database credentials are stored as SSM
SecureString parameters. Both pods share the **same IAM role** but use
separate ServiceAccounts (`zabbix-web-sa` and `zabbix-ha-sidecar`), each
with its own Pod Identity association.

### 5a: Store Zabbix DB credentials in SSM Parameter Store

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

### 5b: Create IAM Role for Zabbix Pod Identity

```bash
ZABBIX_ROLE_NAME="${NAMESPACE}-zabbix-pod-identity-role-${PROJECT_NAME}"

# Check if role already exists
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

# Verify
aws iam get-role --role-name "$ZABBIX_ROLE_NAME" \
  --query "Role.{RoleName:RoleName,Arn:Arn,CreateDate:CreateDate}" \
  --output table
```

---

### 5c: Attach inline policy (SSM + KMS permissions)

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

### 5d: Create Pod Identity Associations for Zabbix

> **ℹ️ Note:** Pod Identity associations are AWS-level configuration rules that
> map a (namespace, ServiceAccount name) pair to an IAM role. The ServiceAccounts
> do **not** need to exist in the cluster before creating the associations.
> When Helm later creates the ServiceAccounts (`zabbix-web-sa`, `zabbix-ha-sidecar`)
> and their Pods, the EKS Pod Identity Agent will automatically detect the match
> and inject IAM credentials.

```bash
ZABBIX_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ZABBIX_ROLE_NAME}"

# Association 1: zabbix-web Deployment
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

# Association 2: zabbix-server StatefulSet (includes ha-label-sidecar)
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

> **ServiceAccount names** are derived from the Helm release name:
> - `zabbix-web-sa` — Zabbix Web Deployment (`<release>-web-sa`)
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

## Step 6: CloudWatch Metric Fetcher — IAM Role + Pod Identity

The custom `zabbix-aws-monitor` image fetches CloudWatch metrics from client
AWS accounts and pushes them to Zabbix. It needs:
- SSM access to read the Zabbix API token (`${ZABBIX_API_PATH}`)
- `sts:AssumeRole` to assume client monitoring roles (`Precision-Monitoring-Role`)

### 6a: Create IAM Role

```bash
# Check if role already exists
aws iam get-role --role-name "$FETCH_CLOUDWATCH_METRIC_ROLE_NAME" 2>/dev/null && {
  echo "Role $FETCH_CLOUDWATCH_METRIC_ROLE_NAME already exists — skipping creation"
} || {
  aws iam create-role \
    --role-name "$FETCH_CLOUDWATCH_METRIC_ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "IAM role for Custom zabbix-aws-monitor EKS Pod Identity to access Zabbix API in SSM Parameter Store and to Assume other client account to fetch cloudwatch metrics" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created role: $FETCH_CLOUDWATCH_METRIC_ROLE_NAME"
}
```

Verify:

```bash
aws iam get-role --role-name "$FETCH_CLOUDWATCH_METRIC_ROLE_NAME" \
  --query "Role.{RoleName:RoleName,Arn:Arn,CreateDate:CreateDate}" \
  --output table
```

---

### 6b: Attach Inline Policy — SSMReadOnlyZabbixApiToken

```bash
cat > SSMReadOnlyZabbixApiToken-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "SSMReadOnlyZabbixApiToken",
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter"
            ],
            "Resource": "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${ZABBIX_API_PATH}"
        },
        {
            "Sid": "KMSDecryptForZabbixApiToken",
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${KMS_KEY_ID}"
        }
    ]
}
EOF

aws iam put-role-policy \
  --role-name "$FETCH_CLOUDWATCH_METRIC_ROLE_NAME" \
  --policy-name SSMReadOnlyZabbixApiToken \
  --policy-document file://SSMReadOnlyZabbixApiToken-policy.json

echo "Attached inline policy: SSMReadOnlyZabbixApiToken"
```

Verify:

```bash
aws iam get-role-policy \
  --role-name "$FETCH_CLOUDWATCH_METRIC_ROLE_NAME" \
  --policy-name SSMReadOnlyZabbixApiToken \
  --query "PolicyDocument" \
  --output json
```

---

### 6c: Attach Inline Policy — AllowAssumeClientMonitoringRoles

```bash
cat > AllowAssumeClientMonitoringRoles-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowAssumeClientRoles",
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ],
            "Resource": "arn:aws:iam::*:role/Precision-Monitoring-Role"
        }
    ]
}
EOF

aws iam put-role-policy \
  --role-name "$FETCH_CLOUDWATCH_METRIC_ROLE_NAME" \
  --policy-name AllowAssumeClientMonitoringRoles \
  --policy-document file://AllowAssumeClientMonitoringRoles-policy.json

echo "Attached inline policy: AllowAssumeClientMonitoringRoles"
```

Verify:

```bash
aws iam get-role-policy \
  --role-name "$FETCH_CLOUDWATCH_METRIC_ROLE_NAME" \
  --policy-name AllowAssumeClientMonitoringRoles \
  --query "PolicyDocument" \
  --output json
```

---

### 6d: Create Pod Identity Association for fetch-cloudwatch-metric

> **ℹ️ Note:** The ServiceAccount `fetch-cloudwatch-metric` is created by the
> Helm chart. The Pod Identity association can be created before the SA exists —
> see Step 5d note.

```bash
FETCH_CLOUDWATCH_METRIC_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${FETCH_CLOUDWATCH_METRIC_ROLE_NAME}"

EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --service-account fetch-cloudwatch-metric \
  --region "$AWS_REGION" \
  --query "associations[0].associationId" \
  --output text 2>/dev/null)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "Pod Identity association for fetch-cloudwatch-metric already exists: $EXISTING"
else
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" \
    --service-account fetch-cloudwatch-metric \
    --role-arn "$FETCH_CLOUDWATCH_METRIC_ROLE_ARN" \
    --region "$AWS_REGION" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created Pod Identity association for fetch-cloudwatch-metric"
fi
```

Verify:

```bash
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --region "$AWS_REGION" \
  --output table
```

---

## Step 7: Karpenter Installation

### 7a: Deploy CloudFormation Stack

This creates the `KarpenterNodeRole` and controller IAM policies.

```bash
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "${TEMPOUT}"

aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --tags \
    Owner="$OWNER" \
    Environment="$ENVIRONMENT" \
    Project="$PROJECT_NAME"
```

> **Wait until the CloudFormation stack reaches `CREATE_COMPLETE` before
> continuing.** The following commands depend on the IAM policies created
> by this stack.

Verify:

```bash
aws cloudformation describe-stacks \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --query "Stacks[0].StackStatus" \
  --output text
```

---

### 7b: Tag CloudFormation-Created IAM Policies

```bash
for POLICY_SUFFIX in \
  NodeLifecyclePolicy \
  IAMIntegrationPolicy \
  EKSIntegrationPolicy \
  InterruptionPolicy \
  ResourceDiscoveryPolicy \
  ZonalShiftPolicy
do
  POLICY_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterController${POLICY_SUFFIX}-${CLUSTER_NAME}"

  aws iam tag-policy \
    --policy-arn "$POLICY_ARN" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"

  echo "Tagged: $POLICY_ARN"
done
```

---

### 7c: Create IAM Role for Karpenter Controller

```bash
KARPENTER_ROLE_NAME="${CLUSTER_NAME}-karpenter"

# Check if role already exists
aws iam get-role --role-name "$KARPENTER_ROLE_NAME" 2>/dev/null && {
  echo "Role $KARPENTER_ROLE_NAME already exists — skipping creation"
} || {
  aws iam create-role \
    --role-name "$KARPENTER_ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "Pod Identity role for Karpenter controller on ${CLUSTER_NAME}" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created role: $KARPENTER_ROLE_NAME"
}

# Attach all 6 Karpenter policies to the role
for POLICY_SUFFIX in \
  NodeLifecyclePolicy \
  IAMIntegrationPolicy \
  EKSIntegrationPolicy \
  InterruptionPolicy \
  ResourceDiscoveryPolicy \
  ZonalShiftPolicy
do
  aws iam attach-role-policy \
    --role-name "$KARPENTER_ROLE_NAME" \
    --policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterController${POLICY_SUFFIX}-${CLUSTER_NAME}"
  echo "Attached: KarpenterController${POLICY_SUFFIX}-${CLUSTER_NAME}"
done
```

Verify:

```bash
aws iam list-attached-role-policies \
  --role-name "$KARPENTER_ROLE_NAME" \
  --query "AttachedPolicies[*].PolicyName" \
  --output table
```

---

### 7d: Create Pod Identity for Karpenter

```bash
EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$KARPENTER_NAMESPACE" \
  --service-account karpenter \
  --region "$AWS_REGION" \
  --query "associations[0].associationId" \
  --output text 2>/dev/null)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "Pod Identity association for karpenter already exists: $EXISTING"
else
  aws eks create-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${KARPENTER_NAMESPACE}" \
    --service-account karpenter \
    --role-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_ROLE_NAME}" \
    --region "$AWS_REGION" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created Pod Identity association for karpenter"
fi
```

Verify:

```bash
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$KARPENTER_NAMESPACE" \
  --region "$AWS_REGION" \
  --output table
```

---

### 7e: Spot SLR + Access Entry

```bash
# Create Spot service-linked role (idempotent — || true handles "already exists")
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true

# Create access entry for Karpenter worker nodes
aws eks create-access-entry \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --principal-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --type EC2_LINUX
```

Verify:

```bash
aws eks list-access-entries \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --output table
```

---

### 7f: Tag Subnets and Security Groups

Karpenter uses the `karpenter.sh/discovery` tag to discover which subnets
and security groups to use for provisioned nodes.

```bash
# Tag subnets from all node groups
for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
  aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
      --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text)
  echo "Tagged subnets for nodegroup: $NODEGROUP"
done

# Tag the cluster security group
SECURITY_GROUPS=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
  --output text)

aws ec2 create-tags \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
  --resources "${SECURITY_GROUPS}"

echo "Tagged security group: $SECURITY_GROUPS"
```

Verify:

```bash
aws ec2 describe-subnets \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query "Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone}" \
  --output table

aws ec2 describe-security-groups \
  --group-ids "$SECURITY_GROUPS" \
  --query "SecurityGroups[*].{GroupId:GroupId,GroupName:GroupName}" \
  --output table
```

---

### 7g: Install Karpenter via Helm

```bash
export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
export KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=700m \
  --set controller.resources.requests.memory=700Mi \
  --set controller.resources.limits.cpu=700m \
  --set controller.resources.limits.memory=700Mi \
  --wait
```

Verify:

```bash
kubectl get pods -n "$KARPENTER_NAMESPACE" -l app.kubernetes.io/name=karpenter

kubectl get deployment karpenter -n "$KARPENTER_NAMESPACE"
```

---

## Step 8: AWS Load Balancer Controller

### 8a: Create IAM Policy

```bash
curl -O "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

# Check if policy already exists
aws iam get-policy \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  2>/dev/null && {
  echo "Policy AWSLoadBalancerControllerIAMPolicy already exists — skipping creation"
} || {
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created policy: AWSLoadBalancerControllerIAMPolicy"
}
```

Verify:

```bash
aws iam get-policy \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --query "Policy.{PolicyName:PolicyName,Arn:Arn}" \
  --output table
```

---

### 8b: Create IAM Role

```bash
LBC_ROLE_NAME="AWSLoadBalancerControllerRole-${PROJECT_NAME}"

# Check if role already exists
aws iam get-role --role-name "$LBC_ROLE_NAME" 2>/dev/null && {
  echo "Role $LBC_ROLE_NAME already exists — skipping creation"
} || {
  aws iam create-role \
    --role-name "$LBC_ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created role: $LBC_ROLE_NAME"
}

# Attach the LBC IAM policy
aws iam attach-role-policy \
  --role-name "$LBC_ROLE_NAME" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

echo "Attached AWSLoadBalancerControllerIAMPolicy to $LBC_ROLE_NAME"
```

Verify:

```bash
aws iam get-role --role-name "$LBC_ROLE_NAME" \
  --query "Role.{RoleName:RoleName,Arn:Arn}" \
  --output table

aws iam list-attached-role-policies \
  --role-name "$LBC_ROLE_NAME" \
  --query "AttachedPolicies[*].PolicyName" \
  --output table
```

---

### 8c: Create ServiceAccount + Pod Identity

```bash
# Create the ServiceAccount (skip if already exists)
kubectl get serviceaccount aws-load-balancer-controller -n kube-system 2>/dev/null && {
  echo "ServiceAccount aws-load-balancer-controller already exists"
} || {
  kubectl create serviceaccount aws-load-balancer-controller -n kube-system
  echo "Created ServiceAccount: aws-load-balancer-controller"
}

# Create Pod Identity association
EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace kube-system \
  --service-account aws-load-balancer-controller \
  --region "$AWS_REGION" \
  --query "associations[0].associationId" \
  --output text 2>/dev/null)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "Pod Identity association for aws-load-balancer-controller already exists: $EXISTING"
else
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace kube-system \
    --service-account aws-load-balancer-controller \
    --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LBC_ROLE_NAME}" \
    --region "$AWS_REGION" \
    --tags \
      Key=Owner,Value="$OWNER" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT"
  echo "Created Pod Identity association for aws-load-balancer-controller"
fi
```

Verify:

```bash
kubectl get serviceaccount aws-load-balancer-controller -n kube-system

aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace kube-system \
  --region "$AWS_REGION" \
  --output table
```

---

### 8d: Install LBC via Helm

```bash
# Add the EKS Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set vpcId="$VPC_ID" \
  --version "$LBC_CHART_VERSION"
```

> **Why `serviceAccount.create=false`:** The ServiceAccount was created
> manually in Step 8c so we could attach the Pod Identity association.
> The Helm chart must reuse it, not create a new one.

> **Why `--set vpcId` is explicit:** Pod-level IMDS auto-detection of the VPC ID
> is unreliable in EKS (particularly with managed node groups or when the IMDS
> hop limit is restrictive). Without this flag, the controller may enter
> `CrashLoopBackOff` with `failed to get VPC ID` errors.

Verify:

```bash
# Both pods should be Running (the chart deploys 2 replicas by default)
kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller

kubectl get deployment aws-load-balancer-controller -n kube-system
```

---

## Step 9: Verify End-to-End Readiness

Before installing the Zabbix chart, confirm:

```bash
# 1. LB Controller pods are Running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 2. IngressClass "alb" exists (created by the LB Controller)
kubectl get ingressclass alb

# 3. Karpenter pods are Running
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# 4. Nodes are Ready
kubectl get nodes

# 5. RDS database is reachable from the cluster VPC
#    (verify security groups allow traffic from your EKS node subnets to RDS port 5432)
```

---

## Step 10: Install Zabbix Helm Chart

```bash
helm install zabbix ./zabbix-helm \
  -n "$NAMESPACE"
```

---

## Kubernetes-Native Monitoring Setup (post-install)

> **These steps are performed AFTER `helm install` completes successfully.**
> The Helm chart automatically creates the `kube-state-metrics` Deployment,
> Service, and the `zabbix-k8s-monitoring` ServiceAccount/RBAC/token Secret.
> The steps below wire them into the Zabbix frontend.

### Step A: Confirm metrics-server is Running

EKS clusters typically include metrics-server by default. Verify:

```bash
kubectl get deployment metrics-server -n kube-system
```

If it is not present, install it:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

metrics-server provides the `metrics.k8s.io` API used by Zabbix's per-node
Kubelet HTTP checks and is required for the `{$KUBE.STATE.METRICS.ENDPOINT}`
data to populate correctly.

---

### Step B: Confirm kube-state-metrics is Running

The chart deploys kube-state-metrics into `kube-system`:

```bash
kubectl get deployment kube-state-metrics -n kube-system
kubectl get svc kube-state-metrics -n kube-system
```

Both should show as `Running` / `ClusterIP`. If `kubeStateMetrics.enabled` was
set to `false` at install time (because you have an existing KSM deployment),
verify your existing KSM service is reachable on port 8080 and note its
in-cluster DNS name to use in Step D.

---

### Step C: Extract the K8s API Token

The chart creates a static long-lived ServiceAccount token Secret. After the
chart is installed and pods are Ready, extract the token:

```bash
kubectl get secret zabbix-k8s-monitoring-token \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' | base64 -d
```

> **Note:** It may take a few seconds after install for the Kubernetes token
> controller to populate `.data.token`. If the output is empty, wait 10–15
> seconds and retry.

Copy the decoded token string — you will paste it into a Zabbix macro in Step D.

---

### Step D: Configure Zabbix Host and Macros

1. In the Zabbix frontend, go to **Data collection → Hosts → Create host**.

2. On the **Templates** tab, link **exactly these two templates**:
   - `Kubernetes cluster state by HTTP`
   - `Kubernetes API server by HTTP`

   > **Do NOT manually link** `Kubernetes nodes by HTTP` or `Kubelet by HTTP`.
   > These templates are auto-linked per discovered node by the LLD rules inside
   > `Kubernetes cluster state by HTTP`. Adding them manually creates duplicate
   > items and alert noise. Within a few minutes of the host becoming active,
   > per-node hosts will appear automatically under Data collection → Hosts.

3. On the **Macros** tab, set the following host-level macros:

   | Macro | Value | Type |
   |-------|-------|------|
   | `{$KUBE.API.ENDPOINT}` | `https://kubernetes.default.svc.cluster.local:443` | Text |
   | `{$KUBE.API.TOKEN}` | *(paste the token from Step C)* | **Secret text** |
   | `{$KUBE.STATE.METRICS.ENDPOINT}` | `http://kube-state-metrics.kube-system.svc.cluster.local:8080` | Text |

   > Set `{$KUBE.API.TOKEN}` to type **Secret text** so the token value is
   > masked in the UI and audit logs.

4. Save the host. Zabbix will begin collecting data immediately.

---

### Step E: Verify Port 10250 Accessibility (Kubelet Metrics)

The `Kubernetes cluster state by HTTP` template's LLD discovery creates per-node
hosts, and those hosts use Kubelet HTTP checks on port 10250. Zabbix Server must
be able to reach each worker node's IP on port 10250.

Check your EKS node security group:

```bash
# Find the node security group
aws ec2 describe-security-groups \
  --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" \
  --query "SecurityGroups[*].{ID:GroupId,Name:GroupName}" \
  --output table \
  --region "$AWS_REGION"
```

EKS's default self-referencing node security group rule typically allows
all traffic between nodes, so Zabbix Server pods (which run on nodes) can
usually reach port 10250 on other nodes without additional rules. If Kubelet
items show `Connection refused` or timeout errors, add an inbound rule:

```
Protocol: TCP
Port: 10250
Source: Node security group ID (self-referencing)
```

---

### Step F: Validate in the Frontend

1. Go to **Monitoring → Latest data**, filter by the Kubernetes host you created.
   - Items should begin populating within 1–2 minutes of the host being enabled.

2. Go to **Data collection → Hosts**.
   - Within 5–10 minutes, per-node hosts named `Kubelet <node-name>` should
     appear automatically — these are created by the LLD discovery rules inside
     `Kubernetes cluster state by HTTP`.
   - This replaces the old approach of manually adding/removing node hosts.
     Host lifecycle (add on node join, remove on node drain) is now fully
     automated by Zabbix's built-in discovery.