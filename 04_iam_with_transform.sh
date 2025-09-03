#!/usr/bin/env bash
set -euo pipefail
source ./env.sh

KINESIS_ARN="arn:aws:kinesis:${AWS_REGION}:${ACCOUNT_ID}:stream/${KINESIS_STREAM}"
TRANSFORM_FN="${PROJECT}-firehose-transform-${ENV}"

# Lambda role
aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" >/dev/null 2>&1 || \
aws iam create-role --role-name "${LAMBDA_ROLE_NAME}" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam attach-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true
aws iam put-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-name "${PROJECT}-lambda-inline" --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",\"dynamodb:Query\",\"dynamodb:BatchWriteItem\"],
     \"Resource\":[
       \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_REG}\",
       \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_REG}/index/*\",
       \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_HOT}\",
       \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_HOT}/index/*\",
       \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_LATEST}\",
       \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_LATEST}/index/*\"
     ]},
    {\"Effect\":\"Allow\",\"Action\":[\"kinesis:PutRecord\",\"kinesis:PutRecords\",\"kinesis:DescribeStream\",\"kinesis:GetShardIterator\",\"kinesis:GetRecords\",\"kinesis:ListShards\"],\"Resource\":\"${KINESIS_ARN}\"}
  ]}" >/dev/null

# IoT rule role
aws iam get-role --role-name "${IOT_ROLE_NAME}" >/dev/null 2>&1 || \
aws iam create-role --role-name "${IOT_ROLE_NAME}" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"iot.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam put-role-policy --role-name "${IOT_ROLE_NAME}" --policy-name "${PROJECT}-iot-inline" --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"kinesis:PutRecord\",\"kinesis:PutRecords\"],\"Resource\":\"${KINESIS_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"firehose:PutRecord\",\"firehose:PutRecordBatch\"],\"Resource\":\"*\"}
  ]}" >/dev/null

# Firehose role - UPDATED with Lambda invoke permissions
aws iam get-role --role-name "${FIREHOSE_ROLE_NAME}" >/dev/null 2>&1 || \
aws iam create-role --role-name "${FIREHOSE_ROLE_NAME}" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam put-role-policy --role-name "${FIREHOSE_ROLE_NAME}" --policy-name "${PROJECT}-firehose-inline" --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:AbortMultipartUpload\",\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\",\"s3:ListBucketMultipartUploads\",\"s3:PutObject\"],\"Resource\":[\"arn:aws:s3:::${RAW_BUCKET}\",\"arn:aws:s3:::${RAW_BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"lambda:InvokeFunction\"],\"Resource\":\"arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${TRANSFORM_FN}\"}
  ]}" >/dev/null

aws iam put-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-name "${PROJECT}-lambda-dynamodbstreams" --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:DescribeStream\",\"dynamodb:GetRecords\",\"dynamodb:GetShardIterator\",\"dynamodb:ListStreams\"],\"Resource\":\"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_HOT}/stream/*\"}
  ]
}" >/dev/null

echo "IAM roles ready (with Firehose transformation permissions)."

