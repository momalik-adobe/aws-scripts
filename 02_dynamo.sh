#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

exists() { aws dynamodb describe-table --table-name "$1" --region "${AWS_REGION}" >/dev/null 2>&1; }

# Registry
if ! exists "${DDB_REG}"; then
  aws dynamodb create-table --table-name "${DDB_REG}" \
    --attribute-definitions AttributeName=machineId,AttributeType=S AttributeName=plantId,AttributeType=S \
    --key-schema AttributeName=machineId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --global-secondary-indexes '[{"IndexName":"PlantDevicesIndex","KeySchema":[{"AttributeName":"plantId","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}]' \
    --region "${AWS_REGION}"
fi
aws dynamodb wait table-exists --table-name "${DDB_REG}" --region "${AWS_REGION}"
aws dynamodb update-continuous-backups --table-name "${DDB_REG}" --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true --region "${AWS_REGION}" || true

# Hot timeseries
if ! exists "${DDB_HOT}"; then
  aws dynamodb create-table --table-name "${DDB_HOT}" \
    --attribute-definitions AttributeName=plantMachineId,AttributeType=S AttributeName=timestamp,AttributeType=N AttributeName=plantBucket,AttributeType=S AttributeName=plantId,AttributeType=S \
    --key-schema AttributeName=plantMachineId,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
    --global-secondary-indexes '[
      {"IndexName":"PlantBucketTimestampIndex","KeySchema":[{"AttributeName":"plantBucket","KeyType":"HASH"},{"AttributeName":"timestamp","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}},
      {"IndexName":"PlantTimestampIndex","KeySchema":[{"AttributeName":"plantId","KeyType":"HASH"},{"AttributeName":"timestamp","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}
    ]' --region "${AWS_REGION}"
fi
aws dynamodb wait table-exists --table-name "${DDB_HOT}" --region "${AWS_REGION}"
aws dynamodb update-time-to-live --table-name "${DDB_HOT}" --time-to-live-specification "Enabled=true, AttributeName=ttl" --region "${AWS_REGION}" || true

# Latest
if ! exists "${DDB_LATEST}"; then
  aws dynamodb create-table --table-name "${DDB_LATEST}" \
    --attribute-definitions AttributeName=plantMachineId,AttributeType=S AttributeName=plantId,AttributeType=S AttributeName=machineId,AttributeType=S \
    --key-schema AttributeName=plantMachineId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --global-secondary-indexes '[{"IndexName":"PlantIndex","KeySchema":[{"AttributeName":"plantId","KeyType":"HASH"},{"AttributeName":"machineId","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' \
    --region "${AWS_REGION}"
fi
aws dynamodb wait table-exists --table-name "${DDB_LATEST}" --region "${AWS_REGION}"
echo "DynamoDB ready: ${DDB_REG}, ${DDB_HOT}, ${DDB_LATEST}"
