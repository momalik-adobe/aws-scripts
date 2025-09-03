#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

# Additional environment variables for transformation
export TRANSFORM_FN="${PROJECT}-firehose-transform-${ENV}"

# Create log group and stream for Firehose
aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws logs create-log-stream --log-group-name "${LOG_GROUP}" --log-stream-name "${LOG_STREAM}" --region "${AWS_REGION}" >/dev/null 2>&1 || true

# Deploy the transformation Lambda function
create_or_update_transform_lambda() {
  local NAME="$1" SRC_FILE="$2"
  local DIR="/tmp/${NAME}"; mkdir -p "${DIR}"
  
  # Copy the transformation Lambda source
  cp "${SRC_FILE}" "${DIR}/lambda_function.py"
  
  # Create deployment package
  (cd "${DIR}" && zip -qr "/tmp/${NAME}.zip" .)
  
  local ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
  
  if ! aws lambda get-function --function-name "${NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "Creating transformation Lambda: ${NAME}"
    aws lambda create-function \
      --function-name "${NAME}" \
      --runtime python3.11 \
      --handler lambda_function.lambda_handler \
      --role "${ROLE_ARN}" \
      --timeout 60 \
      --zip-file fileb:///tmp/${NAME}.zip \
      --region "${AWS_REGION}" >/dev/null
    aws lambda wait function-updated --function-name "${NAME}" --region "${AWS_REGION}"
  else
    echo "Updating transformation Lambda: ${NAME}"
    aws lambda update-function-code \
      --function-name "${NAME}" \
      --zip-file fileb:///tmp/${NAME}.zip \
      --region "${AWS_REGION}" >/dev/null
    aws lambda wait function-updated --function-name "${NAME}" --region "${AWS_REGION}"
  fi
}

# Deploy the transformation Lambda if the source file exists
if [ -f "./firehose_transform_lambda.py" ]; then
  create_or_update_transform_lambda "${TRANSFORM_FN}" "./firehose_transform_lambda.py"
else
  echo "Warning: firehose_transform_lambda.py not found. Skipping transformation Lambda deployment."
fi

# Check if Firehose already exists and delete it to recreate with transformation
if aws firehose describe-delivery-stream --delivery-stream-name "${FIREHOSE}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Deleting existing Firehose to enable transformation: ${FIREHOSE}"
  aws firehose delete-delivery-stream --delivery-stream-name "${FIREHOSE}" --region "${AWS_REGION}"
  
  # Wait for deletion to complete
  echo "Waiting for Firehose deletion to complete..."
  while aws firehose describe-delivery-stream --delivery-stream-name "${FIREHOSE}" --region "${AWS_REGION}" >/dev/null 2>&1; do
    sleep 10
  done
fi

# Create Firehose with data transformation
echo "Creating Firehose with data transformation: ${FIREHOSE}"

# Build the configuration JSON
FIREHOSE_CONFIG=$(cat <<EOF
{
  "RoleARN": "arn:aws:iam::${ACCOUNT_ID}:role/${FIREHOSE_ROLE_NAME}",
  "BucketARN": "arn:aws:s3:::${RAW_BUCKET}",
  "Prefix": "raw-data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/",
  "ErrorOutputPrefix": "error-data/!{firehose:error-output-type}/",
  "BufferingHints": {
    "SizeInMBs": 128,
    "IntervalInSeconds": 300
  },
  "CompressionFormat": "GZIP",
  "CloudWatchLoggingOptions": {
    "Enabled": true,
    "LogGroupName": "${LOG_GROUP}",
    "LogStreamName": "${LOG_STREAM}"
  },
  "ProcessingConfiguration": {
    "Enabled": true,
    "Processors": [
      {
        "Type": "Lambda",
        "Parameters": [
          {
            "ParameterName": "LambdaArn",
            "ParameterValue": "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${TRANSFORM_FN}"
          }
        ]
      }
    ]
  }
}
EOF
)

aws firehose create-delivery-stream \
  --delivery-stream-name "${FIREHOSE}" \
  --delivery-stream-type DirectPut \
  --extended-s3-destination-configuration "${FIREHOSE_CONFIG}" \
  --region "${AWS_REGION}"

echo "Firehose with transformation ready: ${FIREHOSE}"
echo "Transformation Lambda: ${TRANSFORM_FN}"
echo "Records with invalid numeric fields will be dropped before reaching S3"

