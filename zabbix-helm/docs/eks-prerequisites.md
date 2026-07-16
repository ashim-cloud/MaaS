# AWS EKS Prerequisites — One-Time Cluster Setup

> **This is a one-time cluster-level prerequisite, completely separate from the
> Zabbix Helm chart.** You must complete these steps once per EKS cluster before
> the Zabbix chart's NLB (zabbix-server-active) and ALB (zabbix-web-ingress)
> resources can be provisioned. The AWS Load Balancer Controller is a shared
> cluster component — it is NOT installed by the Zabbix chart.

## Variables — Replace Before Running

```bash
export CLUSTER_NAME="zabbix-pre-prod-cluster"       # Your EKS cluster name
export REGION="eu-north-1"                       # AWS region
export AWS_ACCOUNT_ID="084181807484"             # Your AWS account ID
export VPC_ID="vpc-011799d0e8ea3e107"            # VPC where the cluster runs
export LBC_VERSION="v2.14.1"                     # AWS LB Controller version
export LBC_CHART_VERSION="3.4.1"                 # Helm chart version for LBC
```

---

## Step 1: Associate IAM OIDC Provider

The AWS Load Balancer Controller uses IAM Roles for Service Accounts (IRSA),
which requires an OIDC provider associated with your cluster.

```bash
# Verify the OIDC issuer exists
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.identity.oidc.issuer" \
  --output text \
  --region "$REGION"

# Install eksctl if not present
curl --silent --location \
  "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" \
  | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

# Associate the OIDC provider
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --approve \
  --region "$REGION"
```

---

## Step 2: Create IAM Policy

Download the official IAM policy document and create it in your AWS account.

```bash
curl -O "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

> **Note:** If the policy already exists (e.g., from a previous cluster), this
> command will fail. You can skip it — the existing policy ARN is reusable
> across clusters.

---

## Step 3: Create IAM Role + Kubernetes ServiceAccount (IRSA)

This creates a Kubernetes ServiceAccount in `kube-system` that is bound to an
IAM role with the LB controller permissions.

```bash
eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --approve \
  --region "$REGION"
```

Verify:

```bash
kubectl get serviceaccount aws-load-balancer-controller -n kube-system
eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION"
```

---

## Step 4: Install AWS Load Balancer Controller via Helm

```bash
# Install Helm if not present
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh

# Add the EKS Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Verify chart availability
helm search repo eks/aws-load-balancer-controller --versions
```

Install the controller:

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set vpcId="$VPC_ID" \
  --version "$LBC_CHART_VERSION"
```

> **Why `--set vpcId` is explicit:** Pod-level IMDS auto-detection of the VPC ID
> is unreliable in EKS (particularly with managed node groups or when the IMDS
> hop limit is restrictive). Without this flag, the controller may enter
> `CrashLoopBackOff` with `failed to get VPC ID` errors.

Verify:

```bash
kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller

# Both pods should be Running (the chart deploys 2 replicas by default)
kubectl get deployment aws-load-balancer-controller -n kube-system
```

---

## Step 5: Verify End-to-End Readiness

Before installing the Zabbix chart, confirm:

```bash
# 1. LB Controller pods are Running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 2. IngressClass "alb" exists (created by the LB Controller)
kubectl get ingressclass alb

# 3. Nodes are Ready
kubectl get nodes

# 4. RDS database is reachable from the cluster VPC
#    (verify security groups allow traffic from your EKS node subnets to RDS port 5432)
```

---

## What Comes Next

Once all prerequisites are green, install the Zabbix chart:

```bash
helm install zabbix ./zabbix-helm \
  --set db.host=YOUR_RDS_ENDPOINT \
  --set db.password=YOUR_DB_PASSWORD \
  --set vpc.id=vpc-xxx \
  --set "vpc.publicSubnetIds={subnet-aaa,subnet-bbb,subnet-ccc}"
```
