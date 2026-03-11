Write-Host "Initializing LocalStack AWS services..."

# Wait for LocalStack to be ready
Start-Sleep -Seconds 5

# Create S3 buckets
Write-Host "Creating S3 buckets..."
awslocal s3 mb s3://video-uploads
awslocal s3 mb s3://video-outputs

# Create SNS topics
Write-Host "Creating SNS topics..."
awslocal sns create-topic --name video-events
awslocal sns create-topic --name job-events

# Create SQS queues
Write-Host "Creating SQS queues..."
awslocal sqs create-queue --queue-name job-queue
awslocal sqs create-queue --queue-name notification-queue
awslocal sqs create-queue --queue-name job-queue-dlq
awslocal sqs create-queue --queue-name notification-queue-dlq

# Get queue ARNs
$jobQueueArn = awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/job-queue --attribute-names QueueArn --query 'Attributes.QueueArn' --output text
$notificationQueueArn = awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/notification-queue --attribute-names QueueArn --query 'Attributes.QueueArn' --output text

# Subscribe SQS queues to SNS topics
Write-Host "Setting up SNS to SQS subscriptions..."

# Video events -> Job queue (for processing)
awslocal sns subscribe `
    --topic-arn arn:aws:sns:us-east-1:000000000000:video-events `
    --protocol sqs `
    --notification-endpoint $jobQueueArn

# Job events -> Notification queue (for sending notifications)
awslocal sns subscribe `
    --topic-arn arn:aws:sns:us-east-1:000000000000:job-events `
    --protocol sqs `
    --notification-endpoint $notificationQueueArn

# Allow SNS to publish to SQS queues
Write-Host "Applying SQS queue policies for SNS delivery..."
$jobQueuePolicyJson = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid = "AllowVideoEventsTopic"
            Effect = "Allow"
            Principal = "*"
            Action = "sqs:SendMessage"
            Resource = $jobQueueArn
            Condition = @{
                ArnEquals = @{
                    "aws:SourceArn" = "arn:aws:sns:us-east-1:000000000000:video-events"
                }
            }
        }
    )
} | ConvertTo-Json -Depth 10

$notificationQueuePolicyJson = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid = "AllowJobEventsTopic"
            Effect = "Allow"
            Principal = "*"
            Action = "sqs:SendMessage"
            Resource = $notificationQueueArn
            Condition = @{
                ArnEquals = @{
                    "aws:SourceArn" = "arn:aws:sns:us-east-1:000000000000:job-events"
                }
            }
        }
    )
} | ConvertTo-Json -Depth 10

$jobQueuePolicyPath = Join-Path $env:TEMP "job-queue-policy.json"
$notificationQueuePolicyPath = Join-Path $env:TEMP "notification-queue-policy.json"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($jobQueuePolicyPath, $jobQueuePolicyJson, $utf8NoBom)
[System.IO.File]::WriteAllText($notificationQueuePolicyPath, $notificationQueuePolicyJson, $utf8NoBom)

awslocal sqs set-queue-attributes --queue-url http://localhost:4566/000000000000/job-queue --attributes Policy=file://$jobQueuePolicyPath
awslocal sqs set-queue-attributes --queue-url http://localhost:4566/000000000000/notification-queue --attributes Policy=file://$notificationQueuePolicyPath

# Verify SES email identity (for local testing)
Write-Host "Verifying SES email identity..."
awslocal ses verify-email-identity --email-address noreply@videoprocessor.local

# Set S3 bucket policies (allow public read for outputs)
Write-Host "Setting S3 bucket policies..."
$bucketPolicyJson = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid = "PublicRead"
            Effect = "Allow"
            Principal = "*"
            Action = "s3:GetObject"
            Resource = "arn:aws:s3:::video-outputs/*"
        }
    )
} | ConvertTo-Json -Depth 10

$bucketPolicyPath = Join-Path $env:TEMP "video-outputs-policy.json"
[System.IO.File]::WriteAllText($bucketPolicyPath, $bucketPolicyJson, $utf8NoBom)

awslocal s3api put-bucket-policy --bucket video-outputs --policy file://$bucketPolicyPath

Write-Host "LocalStack initialization complete!"
Write-Host ""
Write-Host "Resources created:"
Write-Host "  - S3 Buckets: video-uploads, video-outputs"
Write-Host "  - SNS Topics: video-events, job-events"
Write-Host "  - SQS Queues: job-queue, notification-queue (with DLQs)"
Write-Host "  - SES verified email: noreply@videoprocessor.local"
