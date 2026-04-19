# Production-Ready Terraform + EKS Starter Kit

A practical starter kit for provisioning an Amazon EKS cluster on AWS with Terraform and deploying it through GitHub Actions using GitHub OIDC.

## What this repo creates

- VPC across 2 Availability Zones
- Public and private subnets
- NAT gateway
- Amazon EKS cluster
- Managed node group
- EKS addons: VPC CNI, CoreDNS, kube-proxy
- EKS access entries for platform admins
- GitHub Actions workflow for `plan`, `apply`, and `destroy`
- Sample Kubernetes workload for smoke testing

## Repo layout

```text
.
├── .github/workflows/terraform.yml
├── backend.hcl.example
├── k8s/sample-nginx.yaml
├── main.tf
├── outputs.tf
├── providers.tf
├── terraform.tfvars.example
├── variables.tf
├── versions.tf
└── scripts/bootstrap_github_oidc.sh
```

## Prerequisites

- AWS account with permissions to create IAM, VPC, and EKS resources
- GitHub repository
- Terraform >= 1.8
- AWS CLI configured locally for the one-time bootstrap
- kubectl installed locally for cluster smoke testing

## Quick start

### 1) Create a GitHub repository

Create a public repo and push these files.

### 2) Create Terraform state backend

Create an S3 bucket and DynamoDB table for remote state. The sample bootstrap script can also do this for you.

```bash
aws s3api create-bucket \
  --bucket YOUR_UNIQUE_TF_STATE_BUCKET \
  --region us-east-1

aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 3) Bootstrap GitHub OIDC for this repo

Run the script once from your machine or AWS CloudShell:

```bash
chmod +x scripts/bootstrap_github_oidc.sh
./scripts/bootstrap_github_oidc.sh \
  --github-org YOUR_GITHUB_USER_OR_ORG \
  --github-repo YOUR_REPO_NAME \
  --aws-region us-east-1 \
  --role-name github-actions-terraform-eks \
  --tf-state-bucket YOUR_UNIQUE_TF_STATE_BUCKET \
  --tf-lock-table terraform-locks
```

The script:
- creates the GitHub OIDC provider if missing
- creates an IAM role trusted by your repo's GitHub Actions workflow
- attaches `AdministratorAccess` for fast testing
- prints the IAM role ARN you will add to GitHub repo variables

## 4) Configure GitHub repository variables

In GitHub, open **Settings → Secrets and variables → Actions → Variables** and add:

- `AWS_REGION` = `us-east-1`
- `IAM_ROLE_ARN` = output from the bootstrap script
- `TF_STATE_BUCKET` = your S3 bucket name
- `TF_LOCK_TABLE` = `terraform-locks`
- `TF_STATE_KEY` = `envs/dev/terraform.tfstate`

Add a repo variable or edit `terraform.tfvars` values in the workflow if you want a different cluster name.

## 5) Create your Terraform input file

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit values as needed.

## 6) Run locally once to validate

```bash
cp backend.hcl.example backend.hcl
terraform init -backend-config=backend.hcl
terraform fmt -recursive
terraform validate
terraform plan -var-file=terraform.tfvars
```

### Sample `backend.hcl`

```hcl
bucket         = "YOUR_UNIQUE_TF_STATE_BUCKET"
key            = "envs/dev/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-locks"
encrypt        = true
```

## 7) Apply from GitHub Actions

Go to **Actions → Terraform EKS Starter → Run workflow**.

Choose:
- `environment`: `dev`
- `action`: `apply`

After the workflow completes, get cluster access locally:

```bash
aws eks update-kubeconfig --region us-east-1 --name dev-eks-starter
kubectl get nodes
kubectl apply -f k8s/sample-nginx.yaml
kubectl get svc -n demo
```

## 8) Destroy when done

Run the same workflow with:
- `environment`: `dev`
- `action`: `destroy`

## Notes for public GitHub repos

- For fast testing, the bootstrap role uses `AdministratorAccess`. Replace that with a least-privilege policy before wider use.
- Protect your `main` branch and allow `apply` only from trusted branches or environments.
- Add GitHub environment protection rules before using this beyond a test account.

## Smoke test

```bash
kubectl get pods -A
kubectl apply -f k8s/sample-nginx.yaml
kubectl get pods -n demo
kubectl get svc -n demo
```

## Cost warning

This creates billable AWS resources, including EKS, NAT Gateway, EC2 worker nodes, and load balancer resources if you deploy public services. Destroy the stack after testing.
