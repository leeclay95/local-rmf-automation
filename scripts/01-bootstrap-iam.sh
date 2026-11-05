#!/usr/bin/env bash
# Mint the lab's emulated IAM user inside Floci and write its key to aws/credentials.
#
# Why this is needed: Floci's EKS cluster auth works exactly like real EKS. The
# bearer token `aws eks get-token` produces is a SigV4-presigned STS
# GetCallerIdentity request, and Floci's token webhook verifies that signature
# against an access key it holds in its own IAM store. The throwaway "test"/"test"
# key that Floci accepts on its REST surface is not in that store, so kubectl
# would get 401 "invalid bearer token". So we create a real (emulated) IAM user
# first, then use its key for everything else.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
source "$LAB_DIR/env.sh" >/dev/null

USER_NAME="${LAB_IAM_USER:-terraform-lab}"

# A fresh clone has no aws/credentials -- it is gitignored, because this script
# rewrites [floci-lab] with a real (emulated) key. Seed it from the template so
# the [floci-bootstrap] profile exists before the first AWS call is made.
if [ ! -f "$AWS_SHARED_CREDENTIALS_FILE" ]; then
  echo "==> seeding $AWS_SHARED_CREDENTIALS_FILE from aws/credentials.example"
  cp "$LAB_DIR/aws/credentials.example" "$AWS_SHARED_CREDENTIALS_FILE"
  chmod 600 "$AWS_SHARED_CREDENTIALS_FILE"
fi

echo "==> waiting for Floci"
for _ in $(seq 1 60); do
  curl -fsS http://localhost:4566/_floci/health >/dev/null 2>&1 && break
  sleep 2
done

echo "==> creating emulated IAM user: $USER_NAME"
aws --profile floci-bootstrap iam create-user --user-name "$USER_NAME" >/dev/null 2>&1 || true
aws --profile floci-bootstrap iam attach-user-policy \
  --user-name "$USER_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess >/dev/null 2>&1 || true

# Reuse the existing key if aws/credentials already holds a working one.
if aws --profile floci-lab sts get-caller-identity >/dev/null 2>&1 \
   && [ "$(aws --profile floci-lab configure get aws_access_key_id)" != "test" ]; then
  echo "==> [floci-lab] already holds a minted key; keeping it"
else
  echo "==> minting access key"
  # One key per user in the emulator; clear any stale ones first.
  for old in $(aws --profile floci-bootstrap iam list-access-keys --user-name "$USER_NAME" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
    aws --profile floci-bootstrap iam delete-access-key \
      --user-name "$USER_NAME" --access-key-id "$old" >/dev/null 2>&1 || true
  done
  KEY_JSON="$(aws --profile floci-bootstrap iam create-access-key --user-name "$USER_NAME")"
  AK="$(jq -r .AccessKey.AccessKeyId <<<"$KEY_JSON")"
  SK="$(jq -r .AccessKey.SecretAccessKey <<<"$KEY_JSON")"

  aws --profile floci-lab configure set aws_access_key_id     "$AK"
  aws --profile floci-lab configure set aws_secret_access_key "$SK"
  chmod 600 "$AWS_SHARED_CREDENTIALS_FILE"
  echo "==> wrote $AK to [floci-lab] in $AWS_SHARED_CREDENTIALS_FILE"
fi

echo "==> identity"
aws --profile floci-lab sts get-caller-identity
echo "==> user arn"
aws --profile floci-lab iam get-user --user-name "$USER_NAME" --query 'User.Arn' --output text
