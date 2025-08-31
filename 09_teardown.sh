#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

read -r -p "Type 'destroy ${PROJECT}/${ENV}' to continue: " ans
[[ "${ans:-}" == "destroy ${PROJECT}/${ENV}" ]] || { echo "Aborted."; exit 1; }

aws iot delete-topic-rule --rule-name "${RT_RULE}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws iot delete-topic-rule --rule-name "${FH_RULE}" --region "${AWS_REGION}" >/dev/null 2>&1 || true

for FN in "${CONSUMER_FN}" "${LATEST_FN}" "${ENRICH_FN}"; do
  for UUID in $(aws lambda list-event-source-mappings --function-name "${FN}" --region "${AWS_REGION}" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null || true); do
    aws lambda delete-event-source-mapping --uuid "${UUID}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
  done
done

for FN in "${ENRICH_FN}" "${CONSUMER_FN}" "${LATEST_FN}"; do
  aws lambda delete-function --function-name "${FN}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
  aws logs delete-log-group --log-group-name "/aws/lambda/${FN}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
done

aws firehose delete-delivery-stream --delivery-stream-name "${FIREHOSE}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws logs delete-log-group --log-group-name "${LOG_GROUP}" --region "${AWS_REGION}" >/dev/null 2>&1 || true

if aws kinesis describe-stream-summary --stream-name "${KINESIS_STREAM}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws kinesis delete-stream --stream-name "${KINESIS_STREAM}" --enforce-consumer-deletion --region "${AWS_REGION}" >/dev/null 2>&1 || true
  aws kinesis wait stream-not-exists --stream-name "${KINESIS_STREAM}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
fi

for T in "${DDB_LATEST}" "${DDB_HOT}" "${DDB_REG}"; do
  aws dynamodb delete-table --table-name "${T}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
  aws dynamodb wait table-not-exists --table-name "${T}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
done

aws glue delete-database --name "${GLUE_DB}" --region "${AWS_REGION}" >/dev/null 2>&1 || true

for B in "${RAW_BUCKET}" "${PROCESSED_BUCKET}"; do
  if aws s3api head-bucket --bucket "${B}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws s3 rm "s3://${B}" --recursive --region "${AWS_REGION}" >/dev/null 2>&1 || true
    aws s3 rb "s3://${B}" --force --region "${AWS_REGION}" >/dev/null 2>&1 || true
  fi
done

aws iam detach-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true
aws iam delete-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-name "${PROJECT}-lambda-inline" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${LAMBDA_ROLE_NAME}" >/dev/null 2>&1 || true

aws iam delete-role-policy --role-name "${IOT_ROLE_NAME}" --policy-name "${PROJECT}-iot-inline" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${IOT_ROLE_NAME}" >/dev/null 2>&1 || true

aws iam delete-role-policy --role-name "${FIREHOSE_ROLE_NAME}" --policy-name "${PROJECT}-firehose-inline" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${FIREHOSE_ROLE_NAME}" >/dev/null 2>&1 || true

echo "Teardown complete."
