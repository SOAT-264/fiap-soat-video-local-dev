#!/bin/bash

echo "Initializing LocalStack AWS services..."

# Wait for LocalStack to be ready
sleep 5

# Create S3 buckets
echo "Creating S3 buckets..."
awslocal s3 mb s3://video-uploads
awslocal s3 mb s3://video-outputs

# Create SNS topics
echo "Creating SNS topics..."
awslocal sns create-topic --name video-events
awslocal sns create-topic --name job-events

# Create SQS queues
echo "Creating SQS queues..."
awslocal sqs create-queue --queue-name job-queue
awslocal sqs create-queue --queue-name notification-queue
awslocal sqs create-queue --queue-name job-queue-dlq
awslocal sqs create-queue --queue-name notification-queue-dlq

# Get queue ARNs
JOB_QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/job-queue --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
NOTIFICATION_QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/notification-queue --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

# Subscribe SQS queues to SNS topics
echo "Setting up SNS to SQS subscriptions..."

# Video events -> Job queue (for processing)
awslocal sns subscribe \
    --topic-arn arn:aws:sns:us-east-1:000000000000:video-events \
    --protocol sqs \
    --notification-endpoint $JOB_QUEUE_ARN

# Job events -> Notification queue (for sending notifications)
awslocal sns subscribe \
    --topic-arn arn:aws:sns:us-east-1:000000000000:job-events \
    --protocol sqs \
    --notification-endpoint $NOTIFICATION_QUEUE_ARN

# Verify SES email identity (for local testing)
echo "Verifying SES email identity..."
awslocal ses verify-email-identity --email-address noreply@videoprocessor.local

# Set S3 bucket policies (allow public read for outputs)
echo "Setting S3 bucket policies..."
awslocal s3api put-bucket-policy --bucket video-outputs --policy '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicRead",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::video-outputs/*"
        }
    ]
}'

echo "LocalStack initialization complete!"
echo ""
echo "Resources created:"
echo "  - S3 Buckets: video-uploads, video-outputs"
echo "  - SNS Topics: video-events, job-events"
echo "  - SQS Queues: job-queue, notification-queue (with DLQs)"
echo "  - SES verified email: noreply@videoprocessor.local"
