# Zabbix Deployment Guide

## 1. Create the PostgreSQL Database

Run the following commands in your PostgreSQL instance:

```sql
CREATE DATABASE zabbix;
\c zabbix

CREATE USER zabbix WITH PASSWORD 'admin';

GRANT ALL PRIVILEGES ON DATABASE zabbix TO zabbix;
GRANT ALL ON SCHEMA public TO zabbix;
GRANT CREATE ON SCHEMA public TO zabbix;

ALTER DATABASE zabbix OWNER TO zabbix;
```

---

## 2. Connect to the Kubernetes Cluster

Run the following command to connect to the Kubernetes cluster:

```bash
source kubectl-connect Zabbix-UAT-Cluster
```

---

## 3. Set Environment Variables

```bash
export CLUSTER_NAME="Zabbix-V1"                  # EKS cluster name
export REGION="ap-south-1"                       # AWS region
export AWS_ACCOUNT_ID="084181807484"             # AWS account ID
export VPC_ID="vpc-08ca854cabed07794"            # VPC ID
export LBC_VERSION="v2.14.1"                     # AWS Load Balancer Controller version
export LBC_CHART_VERSION="3.4.1"                 # Helm chart version
```

---

## 4. Update Kubernetes Configuration

```bash
aws eks update-kubeconfig \
    --region ap-south-1 \
    --name Zabbix-V1
```

---

## 5. Download Deployment Files from S3

Replace `<Bucket-Name>` with your actual S3 bucket name.

```bash
aws s3 cp s3://<Bucket-Name> . --recursive
```

---

## 6. Deploy Zabbix Using Helm

```bash
helm install zabbix ./zabbix-helm \
  --set db.host=zabbix-v1-db.c9ai4u8qw4w8.ap-south-1.rds.amazonaws.com \
  --set db.password=admin \
  --set vpc.id=vpc-08ca854cabed07794 \
  --set "vpc.publicSubnetIds={subnet-025699e23bc752ae9,subnet-0afdeca16199f87bd,subnet-059e7c7d9b016dd7d}"
```

---

## Notes

- Ensure the PostgreSQL database is accessible from the EKS cluster.
- Replace `<Bucket-Name>` with your actual Amazon S3 bucket name.
- Verify that your AWS CLI is configured with the appropriate IAM credentials before running the commands.
- Ensure Helm is installed and configured before deploying the chart.
