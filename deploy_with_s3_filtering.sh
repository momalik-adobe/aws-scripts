#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Machine Monitoring with S3 Data Filtering ==="
echo "This will enable filtering of invalid numeric records before they reach S3"
echo ""

# Check if transformation Lambda source exists
if [ ! -f "./firehose_transform_lambda.py" ]; then
  echo "Error: firehose_transform_lambda.py not found in current directory"
  echo "This file is required for S3 data filtering"
  exit 1
fi

# Run deployment steps in order
echo "1. Setting up S3 buckets..."
./01_s3.sh

echo "2. Setting up DynamoDB tables..."
./02_dynamo.sh

echo "3. Setting up Kinesis stream..."
./03_kinesis.sh

echo "4. Setting up IAM roles (with transformation permissions)..."
./04_iam_with_transform.sh

echo "5. Setting up Firehose with data transformation..."
./05_firehouse_with_transform.sh

echo "6. Setting up Lambda functions..."
./06_lambdas.sh

echo "7. Setting up IoT rules..."
./07_iot_rules.sh

echo "8. Setting up Glue/Athena..."
./08_glue_athena.sh

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Your S3 data flow now includes filtering:"
echo "  IoT Device → IoT Rule → Firehose → Transform Lambda → S3 (filtered)"
echo ""
echo "Records with invalid numeric fields (kw, kva, kvar) will be:"
echo "  - Dropped (not stored in S3)"
echo "  - Logged as 'Dropped' in CloudWatch"
echo ""
echo "Valid records will be:"
echo "  - Sanitized (converted to proper numeric types)"
echo "  - Stored in S3 with GZIP compression"
echo ""
echo "Next steps:"
echo "  1. Test with sample IoT data"
echo "  2. Monitor CloudWatch logs for dropped records"
echo "  3. Run './10_onboard_things.sh <plantId> <count>' to create devices"
echo "  4. Run './11_Scheduler.sh' to set up hourly data processing"
