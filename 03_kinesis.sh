#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

if ! aws kinesis describe-stream-summary --stream-name "${KINESIS_STREAM}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws kinesis create-stream --stream-name "${KINESIS_STREAM}" --shard-count "${KINESIS_SHARDS}" --region "${AWS_REGION}"
  aws kinesis wait stream-exists --stream-name "${KINESIS_STREAM}" --region "${AWS_REGION}"
fi
echo "Kinesis ready: ${KINESIS_STREAM}"
