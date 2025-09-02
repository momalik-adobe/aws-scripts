#!/usr/bin/env bash
set -euo pipefail

# Config
REGION=ap-south-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/athena-schedule-role"
ROLE_NAME="${ROLE_ARN##*/}"
OUTPUT="s3://machine-monitoring-raw-data-dev-272103761927/athena-results/"
DB="machine_monitoring_dev"
SCHEDULE_NAME="processed-power-hourly"
CRON_EXPR="cron(5 * * * ? *)"  # change to cron(0/5 * * * ? *) for every 5 minutes

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI is required" >&2; exit 1; }

echo "Region  : ${REGION}"
echo "Account : ${ACCOUNT_ID}"
echo "Role ARN: ${ROLE_ARN}"
echo "DB      : ${DB}"
echo "Results : ${OUTPUT}"

# Discover S3 locations for raw/processed via Glue (best-effort)
RAW_TABLE=raw_machine_json
PROC_TABLE=processed_power
RAW_LOC=$(aws glue get-table --database-name "$DB" --name "$RAW_TABLE" --query 'Table.StorageDescriptor.Location' --output text --region "$REGION" 2>/dev/null || true)
PROC_LOC=$(aws glue get-table --database-name "$DB" --name "$PROC_TABLE" --query 'Table.StorageDescriptor.Location' --output text --region "$REGION" 2>/dev/null || true)

# Fallback patterns if Glue not yet present
if [[ -z "${RAW_LOC}" || "${RAW_LOC}" == "None" ]]; then
  RAW_LOC="s3://machine-monitoring-raw-data-${ENV:-dev}-${ACCOUNT_ID}/raw-data/"
fi
if [[ -z "${PROC_LOC}" || "${PROC_LOC}" == "None" ]]; then
  PROC_LOC="s3://machine-monitoring-processed-data-${ENV:-dev}-${ACCOUNT_ID}/processed/"
fi

# Parse s3 uri into bucket/prefix
parse_s3_assign() {
  local uri="$1"; local no="${uri#s3://}"; local b="${no%%/*}"; local p="${no#*/}"; [ "$p" = "$b" ] && p=""; PARSED_BUCKET="$b"; PARSED_PREFIX="$p";
}

parse_s3_assign "$RAW_LOC";  RAW_BUCKET="$PARSED_BUCKET";  RAW_PREFIX="$PARSED_PREFIX"
parse_s3_assign "$PROC_LOC"; PROC_BUCKET="$PARSED_BUCKET"; PROC_PREFIX="$PARSED_PREFIX"
parse_s3_assign "$OUTPUT";   OUT_BUCKET="$PARSED_BUCKET";  OUT_PREFIX="$PARSED_PREFIX"

echo "RAW S3 : ${RAW_BUCKET}/${RAW_PREFIX}"
echo "PROC S3: ${PROC_BUCKET}/${PROC_PREFIX}"

# Ensure role exists and has S3/Glue/Athena permissions
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Creating role $ROLE_NAME"
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$(jq -n '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"scheduler.amazonaws.com"},Action:"sts:AssumeRole"}]}')" >/dev/null
fi

echo "Updating inline policy on $ROLE_NAME for S3/Glue/Athena"
POLICY=$(jq -n \
  --arg rawb "$RAW_BUCKET" --arg rawp "$RAW_PREFIX" \
  --arg procb "$PROC_BUCKET" --arg procp "$PROC_PREFIX" \
  --arg outb "$OUT_BUCKET" --arg outp "$OUT_PREFIX" '{
  Version:"2012-10-17",
  Statement:[
    {"Effect":"Allow","Action":["athena:StartQueryExecution"],"Resource":"*"},
    {"Effect":"Allow","Action":["glue:GetDatabase","glue:GetTable","glue:GetTables","glue:GetPartitions","glue:GetPartition"],"Resource":"*"},
    {"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket"],
     "Resource":[("arn:aws:s3:::"+$rawb),("arn:aws:s3:::"+$procb),("arn:aws:s3:::"+$outb)]},
    {"Effect":"Allow","Action":["s3:GetObject"],
     "Resource":[("arn:aws:s3:::"+$rawb+"/"+$rawp+"*"),("arn:aws:s3:::"+$procb+"/"+$procp+"*")]},
    {"Effect":"Allow","Action":["s3:PutObject"],
     "Resource":[("arn:aws:s3:::"+$procb+"/"+$procp+"*"),("arn:aws:s3:::"+$outb+"/"+$outp+"*")]}
  ]
}')
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name ${ROLE_NAME}-athena-access --policy-document "$POLICY" >/dev/null

# Athena SQL (IST-partitioned)
QUERY=$(cat <<'SQL'
INSERT INTO machine_monitoring_dev.processed_power
WITH last AS (
  SELECT
    date_format(date_add('hour', -1, current_timestamp), '%Y') AS y,
    date_format(date_add('hour', -1, current_timestamp), '%m') AS m,
    date_format(date_add('hour', -1, current_timestamp), '%d') AS d,
    date_format(date_add('hour', -1, current_timestamp), '%H') AS h
),
raw_ist AS (
  SELECT r.*,
         (from_unixtime(CAST(r.receivedAt AS bigint)/1000) AT TIME ZONE 'Asia/Kolkata') AS ts_ist
  FROM machine_monitoring_dev.raw_machine_json r, last
  WHERE r.year  = last.y
    AND r.month = last.m
    AND r.day   = last.d
    AND r.hour  = last.h
)
SELECT
  CAST(r.macId AS varchar)                AS macId,
  CAST(r.slaveName AS varchar)            AS slaveName,
  CAST(r.slaveId AS integer)              AS slaveId,
  CAST(r.kw AS double)                    AS kw,
  CAST(r.kvar AS double)                  AS kvar,
  CAST(r.kva AS double)                   AS kva,
  from_unixtime(CAST(r.receivedAt AS bigint)/1000) AS receivedAt_utc,
  CAST(r.plantId AS varchar)              AS plantId,
  date_format(r.ts_ist, '%Y')             AS year,
  date_format(r.ts_ist, '%m')             AS month,
  date_format(r.ts_ist, '%d')             AS day,
  CAST(r.machineId AS varchar)            AS machineId
FROM raw_ist r;
SQL
)

# Build Input and Target JSON
INPUT=$(jq -nc --arg q "$QUERY" --arg db "$DB" --arg out "$OUTPUT" \
  '{QueryString:$q, QueryExecutionContext:{Database:$db}, ResultConfiguration:{OutputLocation:$out}}')
TARGET=$(jq -nc --arg arn "arn:aws:scheduler:::aws-sdk:athena:startQueryExecution" \
  --arg role "$ROLE_ARN" --arg input "$INPUT" \
  '{Arn:$arn, RoleArn:$role, Input:$input}')

# Create or update the schedule (IST timezone)
echo "Ensuring schedule: ${SCHEDULE_NAME}"
if aws scheduler get-schedule --name "${SCHEDULE_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  aws scheduler update-schedule \
    --name "${SCHEDULE_NAME}" \
    --schedule-expression "$CRON_EXPR" \
    --schedule-expression-timezone "Asia/Kolkata" \
    --flexible-time-window Mode=OFF \
    --target "$TARGET" \
    --region "$REGION" | cat
  echo "Updated schedule: ${SCHEDULE_NAME}"
else
  aws scheduler create-schedule \
    --name "${SCHEDULE_NAME}" \
    --schedule-expression "$CRON_EXPR" \
    --schedule-expression-timezone "Asia/Kolkata" \
    --flexible-time-window Mode=OFF \
    --target "$TARGET" \
    --region "$REGION" | cat
  echo "Created schedule: ${SCHEDULE_NAME}"
fi

echo "Listing schedules in ${REGION}..."
aws scheduler list-schedules --region "$REGION" | jq '.Schedules[].Name' | cat