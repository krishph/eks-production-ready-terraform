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
POLICY_NAME="${ROLE_NAME}-policy"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Fetch the current TLS thumbprint from GitHub's OIDC endpoint rather than
# hardcoding it — the hardcoded value silently breaks when GitHub rotates certs.
fetch_oidc_thumbprint() {
  echo "Fetching current GitHub OIDC TLS thumbprint..."
  THUMBPRINT=$(echo | openssl s_client \
    -servername "$OIDC_HOST" \
    -connect "${OIDC_HOST}:443" 2>/dev/null \
    | openssl x509 -fingerprint -noout -sha1 \
    | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

  if [[ -z "$THUMBPRINT" ]]; then
    echo "ERROR: Failed to fetch OIDC thumbprint from ${OIDC_HOST}" >&2
    exit 1
  fi
  echo "Thumbprint: $THUMBPRINT"
}

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
      --thumbprint-list "$THUMBPRINT" >/dev/null
  fi
}

create_least_privilege_policy() {
  cat > "$TMP_DIR/iam-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKS",
      "Effect": "Allow",
      "Action": ["eks:*"],
      "Resource": "*"
    },
    {
      "Sid": "EC2",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:AssociateRouteTable",
        "ec2:AttachInternetGateway",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateInternetGateway",
        "ec2:CreateNatGateway",
        "ec2:CreateRoute",
        "ec2:CreateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSubnet",
        "ec2:CreateTags",
        "ec2:CreateVpc",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteNatGateway",
        "ec2:DeleteRoute",
        "ec2:DeleteRouteTable",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSubnet",
        "ec2:DeleteVpc",
        "ec2:DescribeAddresses",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeNatGateways",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeVpcs",
        "ec2:DetachInternetGateway",
        "ec2:DisassociateAddress",
        "ec2:DisassociateRouteTable",
        "ec2:ModifySubnetAttribute",
        "ec2:ModifyVpcAttribute",
        "ec2:ReleaseAddress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateLaunchTemplate",
        "ec2:DeleteLaunchTemplate",
        "ec2:RunInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAM",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:AttachRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:CreateOpenIDConnectProvider",
        "iam:CreatePolicy",
        "iam:CreatePolicyVersion",
        "iam:CreateRole",
        "iam:DeleteInstanceProfile",
        "iam:DeleteOpenIDConnectProvider",
        "iam:DeletePolicy",
        "iam:DeletePolicyVersion",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:GetInstanceProfile",
        "iam:GetOpenIDConnectProvider",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:ListPolicyVersions",
        "iam:ListRolePolicies",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:TagOpenIDConnectProvider",
        "iam:TagPolicy",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:UpdateAssumeRolePolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TerraformStateBucket",
      "Effect": "Allow",
      "Action": [
        "s3:DeleteObject",
        "s3:GetBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::${TF_STATE_BUCKET}",
        "arn:aws:s3:::${TF_STATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "TerraformStateLock",
      "Effect": "Allow",
      "Action": [
        "dynamodb:DeleteItem",
        "dynamodb:GetItem",
        "dynamodb:PutItem"
      ],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${TF_LOCK_TABLE}"
    },
    {
      "Sid": "KMS",
      "Effect": "Allow",
      "Action": [
        "kms:CreateAlias",
        "kms:CreateKey",
        "kms:DeleteAlias",
        "kms:DescribeKey",
        "kms:EnableKeyRotation",
        "kms:GetKeyPolicy",
        "kms:GetKeyRotationStatus",
        "kms:ListAliases",
        "kms:ListResourceTags",
        "kms:PutKeyPolicy",
        "kms:ScheduleKeyDeletion",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:UpdateKeyDescription"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:DeleteRetentionPolicy",
        "logs:DescribeLogGroups",
        "logs:ListTagsLogGroup",
        "logs:ListTagsForResource",
        "logs:PutRetentionPolicy",
        "logs:TagResource",
        "logs:UntagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoScaling",
      "Effect": "Allow",
      "Action": [
        "autoscaling:CreateAutoScalingGroup",
        "autoscaling:DeleteAutoScalingGroup",
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:UpdateAutoScalingGroup"
      ],
      "Resource": "*"
    }
  ]
}
JSON

  if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1; then
    echo "Updating existing IAM policy: $POLICY_NAME"
    # Delete old non-default versions to stay within the 5-version limit
    OLD_VERSIONS=$(aws iam list-policy-versions \
      --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text)
    for v in $OLD_VERSIONS; do
      aws iam delete-policy-version \
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" \
        --version-id "$v" >/dev/null
    done
    aws iam create-policy-version \
      --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" \
      --policy-document "file://$TMP_DIR/iam-policy.json" \
      --set-as-default >/dev/null
  else
    echo "Creating least-privilege IAM policy: $POLICY_NAME"
    aws iam create-policy \
      --policy-name "$POLICY_NAME" \
      --policy-document "file://$TMP_DIR/iam-policy.json" >/dev/null
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

  echo "Attaching least-privilege policy to role: $ROLE_NAME"
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null
}

fetch_oidc_thumbprint
ensure_state_backend
ensure_oidc_provider
create_least_privilege_policy
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
