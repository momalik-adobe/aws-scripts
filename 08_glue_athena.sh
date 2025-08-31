#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

aws glue create-database --database-input "Name=${GLUE_DB}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws athena start-query-execution \
  --query-string "CREATE DATABASE IF NOT EXISTS ${GLUE_DB}" \
  --result-configuration "OutputLocation=s3://${RAW_BUCKET}/${ATHENA_RESULTS_PREFIX}" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "Glue/Athena ready: ${GLUE_DB}, results in s3://${RAW_BUCKET}/${ATHENA_RESULTS_PREFIX}"
