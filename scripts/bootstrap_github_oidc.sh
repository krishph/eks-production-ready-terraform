#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  $0 \
    --github-org YOUR_GITHUB_ORG \
    --github-repo YOUR_REPO \
    --aws-region us-east-1 \
    --role-name github-actions-terraform-eks \
    --tf-state-bucket YOUR_UNIQUE_TF_STATE_BUCKET \
    --tf-lock-table terraform-locks
USAGE
}

GITHUB_ORG=""
GITHUB_REPO=""
AWS_REGION="us-east-1"
ROLE_NAME="github-actions-terraform-eks"
TF_STATE_BUCKET=""
TF_LOCK_TABLE="terraform-locks"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-org) GITHUB_ORG="$2"; shift 2 ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --aws-region) AWS_REGION="$2"; shift 2 ;;
    --role-name) ROLE_NAME="$2"; shift 2 ;;
    --tf-state-bucket) TF_STATE_BUCKET="$2"; shift 2 ;;
    --tf-lock-table) TF_LOCK_TABLE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$GITHUB_ORG" || -z "$GITHUB_REPO" || -z "$TF_STATE_BUCKET" ]]; then
  usage
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

ensure_state_backend() {
  if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
    echo "S3 bucket already exists: $TF_STATE_BUCKET"
  else
    echo "Creating S3 bucket: $TF_STATE_BUCKET"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" >/dev/null
    else
      aws s3api create-bucket \
        --bucket "$TF_STATE_BUCKET" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    fi
  fi

  aws s3api put-bucket-versioning \
    --bucket "$TF_STATE_BUCKET" \
    --versioning-configuration Status=Enabled >/dev/null

  aws s3api put-bucket-encryption \
    --bucket "$TF_STATE_BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
      }]
    }' >/dev/null

  if aws dynamodb describe-table --table-name "$TF_LOCK_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "DynamoDB lock table already exists: $TF_LOCK_TABLE"
  else
    echo "Creating DynamoDB lock table: $TF_LOCK_TABLE"
    aws dynamodb create-table \
      --table-name "$TF_LOCK_TABLE" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$AWS_REGION" >/dev/null
  fi
}

ensure_oidc_provider() {
  if aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
    echo "GitHub OIDC provider already exists: $OIDC_PROVIDER_ARN"
  else
    echo "Creating GitHub OIDC provider"
    aws iam create-open-id-connect-provider \
      --url "$OIDC_URL" \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  fi
}

create_or_update_role() {
  cat > "$TMP_DIR/trust-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$OIDC_PROVIDER_ARN"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main",
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:pull_request",
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:dev"
          ]
        }
      }
    }
  ]
}
JSON

  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Updating trust policy on role: $ROLE_NAME"
    aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document "file://$TMP_DIR/trust-policy.json" >/dev/null
  else
    echo "Creating IAM role: $ROLE_NAME"
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$TMP_DIR/trust-policy.json" >/dev/null
  fi

  echo "Attaching AdministratorAccess for fast testing"
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess >/dev/null
}

ensure_state_backend
ensure_oidc_provider
create_or_update_role

cat <<OUTPUT

Bootstrap complete.

Add these GitHub Actions repo variables:

AWS_REGION=$AWS_REGION
IAM_ROLE_ARN=$ROLE_ARN
TF_STATE_BUCKET=$TF_STATE_BUCKET
TF_LOCK_TABLE=$TF_LOCK_TABLE
TF_STATE_KEY=envs/dev/terraform.tfstate

Suggested local backend.hcl:

bucket         = "$TF_STATE_BUCKET"
key            = "envs/dev/terraform.tfstate"
region         = "$AWS_REGION"
dynamodb_table = "$TF_LOCK_TABLE"
encrypt        = true

Role ARN:
$ROLE_ARN
OUTPUT
