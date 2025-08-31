#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

create_bucket () {
  local B="$1"
  if ! aws s3api head-bucket --bucket "${B}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws s3api create-bucket --bucket "${B}" --region "${AWS_REGION}" $( [ "${AWS_REGION}" != "us-east-1" ] && echo --create-bucket-configuration LocationConstraint="${AWS_REGION}" || true )
  fi
  aws s3api put-bucket-encryption --bucket "${B}" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' --region "${AWS_REGION}"
  aws s3api put-public-access-block --bucket "${B}" --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}' --region "${AWS_REGION}"
  aws s3api put-bucket-versioning --bucket "${B}" --versioning-configuration Status=Enabled --region "${AWS_REGION}"
}

create_bucket "${RAW_BUCKET}"
create_bucket "${PROCESSED_BUCKET}"
aws s3api put-object --bucket "${RAW_BUCKET}" --key "${ATHENA_RESULTS_PREFIX}" --region "${AWS_REGION}" >/dev/null || true
echo "S3 ready: ${RAW_BUCKET}, ${PROCESSED_BUCKET}"
