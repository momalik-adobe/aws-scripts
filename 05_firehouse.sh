#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws logs create-log-stream --log-group-name "${LOG_GROUP}" --log-stream-name "${LOG_STREAM}" --region "${AWS_REGION}" >/dev/null 2>&1 || true

if ! aws firehose describe-delivery-stream --delivery-stream-name "${FIREHOSE}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws firehose create-delivery-stream \
    --delivery-stream-name "${FIREHOSE}" \
    --delivery-stream-type DirectPut \
    --extended-s3-destination-configuration "{
      \"RoleARN\": \"arn:aws:iam::${ACCOUNT_ID}:role/${FIREHOSE_ROLE_NAME}\",
      \"BucketARN\": \"arn:aws:s3:::${RAW_BUCKET}\",
      \"Prefix\": \"raw-data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/\",
      \"ErrorOutputPrefix\": \"error-data/!\",
      \"BufferingHints\": {\"SizeInMBs\": 128, \"IntervalInSeconds\": 300},
      \"CompressionFormat\": \"GZIP\",
      \"CloudWatchLoggingOptions\": {\"Enabled\": true, \"LogGroupName\": \"${LOG_GROUP}\", \"LogStreamName\": \"${LOG_STREAM}\"}
    }" --region "${AWS_REGION}"
fi
echo "Firehose ready: ${FIREHOSE}"
