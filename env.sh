#!/usr/bin/env bash
set -euo pipefail

# Edit if needed
export PROJECT="machine-monitoring"
export ENV="dev"
export AWS_REGION="${AWS_REGION:-ap-south-1}"

export PROJECT_SAFE="${PROJECT//-/_}"
export ENV_SAFE="${ENV//-/_}"

export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "${AWS_REGION}")"

# Names
export RAW_BUCKET="${PROJECT}-raw-data-${ENV}-${ACCOUNT_ID}"
export PROCESSED_BUCKET="${PROJECT}-processed-data-${ENV}-${ACCOUNT_ID}"
export ATHENA_RESULTS_PREFIX="athena-results/"

export KINESIS_STREAM="${PROJECT}-data-stream-${ENV}"
export FIREHOSE="${PROJECT}-firehose-${ENV}"

export DDB_REG="${PROJECT}-device-registry-${ENV}"
export DDB_HOT="${PROJECT}-realtime-data-${ENV}"
export DDB_LATEST="${PROJECT}-latest-${ENV}"

export GLUE_DB="${PROJECT_SAFE}_${ENV_SAFE}"

export LAMBDA_ROLE_NAME="${PROJECT}-lambda-role-${ENV}"
export IOT_ROLE_NAME="${PROJECT}-iot-rule-role-${ENV}"
export FIREHOSE_ROLE_NAME="${PROJECT}-firehose-role-${ENV}"

export ENRICH_FN="${PROJECT}-enrich-to-kinesis-${ENV}"
export CONSUMER_FN="${PROJECT}-kinesis-to-ddb-${ENV}"
export LATEST_FN="${PROJECT}-latest-updater-${ENV}"



# IoT rules use underscores (hyphens not allowed)
export RT_RULE="${PROJECT_SAFE}_realtime_${ENV_SAFE}"
export FH_RULE="${PROJECT_SAFE}_firehose_${ENV_SAFE}"

# Topics and stream sizing
export IOT_TOPIC_FILTER="+/machine/+/data"
export KINESIS_SHARDS="${KINESIS_SHARDS:-4}"
export HOT_TTL_HOURS="${HOT_TTL_HOURS:-48}"
export PLANT_BUCKETS="${PLANT_BUCKETS:-8}"

# Firehose logging
export LOG_GROUP="/aws/kinesisfirehose/${FIREHOSE}"
export LOG_STREAM="S3Delivery"
