#!/usr/bin/env bash
set -euo pipefail

echo "Initializing LocalStack AWS services..."

# Aguarda o LocalStack ficar pronto para aceitar os comandos awslocal.
sleep 5

ensure_bucket() {
		local bucket_name="$1"

		if awslocal s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
				echo "S3 bucket already exists: ${bucket_name}"
				return 0
		fi

		awslocal s3 mb "s3://${bucket_name}" >/dev/null
		echo "S3 bucket created: ${bucket_name}"
}

ensure_subscription() {
		local topic_arn="$1"
		local queue_arn="$2"
		local existing_subscription=""

		existing_subscription="$(awslocal sns list-subscriptions-by-topic --topic-arn "${topic_arn}" --query "Subscriptions[?Endpoint=='${queue_arn}' && Protocol=='sqs'].SubscriptionArn | [0]" --output text)"

		if [[ "${existing_subscription}" == "None" || -z "${existing_subscription}" ]]; then
				awslocal sns subscribe \
						--topic-arn "${topic_arn}" \
						--protocol sqs \
						--notification-endpoint "${queue_arn}" >/dev/null
				echo "Subscription created: ${topic_arn} -> ${queue_arn}"
		else
				echo "Subscription already exists: ${topic_arn} -> ${queue_arn}"
		fi
}

echo "Creating S3 buckets..."
ensure_bucket "video-uploads"
ensure_bucket "video-outputs"

echo "Creating SNS topics..."
video_events_topic_arn="$(awslocal sns create-topic --name video-events --query 'TopicArn' --output text)"
job_events_topic_arn="$(awslocal sns create-topic --name job-events --query 'TopicArn' --output text)"

echo "Creating SQS queues..."
job_queue_url="$(awslocal sqs create-queue --queue-name job-queue --query 'QueueUrl' --output text)"
notification_queue_url="$(awslocal sqs create-queue --queue-name notification-queue --query 'QueueUrl' --output text)"
awslocal sqs create-queue --queue-name job-queue-dlq >/dev/null
awslocal sqs create-queue --queue-name notification-queue-dlq >/dev/null

job_queue_arn="$(awslocal sqs get-queue-attributes --queue-url "${job_queue_url}" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
notification_queue_arn="$(awslocal sqs get-queue-attributes --queue-url "${notification_queue_url}" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"

echo "Setting up SNS to SQS subscriptions..."
ensure_subscription "${video_events_topic_arn}" "${job_queue_arn}"
ensure_subscription "${job_events_topic_arn}" "${notification_queue_arn}"

echo "Applying SQS queue policies for SNS delivery..."
job_queue_policy_path="$(mktemp)"
notification_queue_policy_path="$(mktemp)"
bucket_policy_path="$(mktemp)"

cleanup_temp_files() {
		rm -f "${job_queue_policy_path}" "${notification_queue_policy_path}" "${bucket_policy_path}"
}

trap cleanup_temp_files EXIT

cat > "${job_queue_policy_path}" <<EOF
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowVideoEventsTopic",
			"Effect": "Allow",
			"Principal": "*",
			"Action": "sqs:SendMessage",
			"Resource": "${job_queue_arn}",
			"Condition": {
				"ArnEquals": {
					"aws:SourceArn": "${video_events_topic_arn}"
				}
			}
		}
	]
}
EOF

cat > "${notification_queue_policy_path}" <<EOF
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowJobEventsTopic",
			"Effect": "Allow",
			"Principal": "*",
			"Action": "sqs:SendMessage",
			"Resource": "${notification_queue_arn}",
			"Condition": {
				"ArnEquals": {
					"aws:SourceArn": "${job_events_topic_arn}"
				}
			}
		}
	]
}
EOF

awslocal sqs set-queue-attributes --queue-url "${job_queue_url}" --attributes "Policy=file://${job_queue_policy_path}" >/dev/null
awslocal sqs set-queue-attributes --queue-url "${notification_queue_url}" --attributes "Policy=file://${notification_queue_policy_path}" >/dev/null

echo "Verifying SES email identity..."
awslocal ses verify-email-identity --email-address noreply@videoprocessor.local >/dev/null

echo "Setting S3 bucket policy..."
cat > "${bucket_policy_path}" <<EOF
{
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
}
EOF

awslocal s3api put-bucket-policy --bucket video-outputs --policy "file://${bucket_policy_path}" >/dev/null

echo "LocalStack initialization complete!"
echo
echo "Resources created:"
echo "  - S3 Buckets: video-uploads, video-outputs"
echo "  - SNS Topics: video-events, job-events"
echo "  - SQS Queues: job-queue, notification-queue (with DLQs)"
echo "  - SES verified email: noreply@videoprocessor.local"
