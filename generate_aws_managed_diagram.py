"""Generate updated AWS architecture diagram with managed services."""
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import ECS, Lambda
from diagrams.aws.database import RDS
from diagrams.aws.storage import S3
from diagrams.aws.network import ELB, APIGateway, Route53
from diagrams.aws.integration import SQS, SNS, Eventbridge
from diagrams.aws.engagement import SES
from diagrams.aws.management import Cloudwatch
from diagrams.onprem.client import Users

# New AWS Architecture with Managed Services
with Diagram("Video Processor - AWS Managed Services", filename="architecture_aws_managed", outformat="png", show=False, direction="LR"):
    users = Users("Users")
    
    with Cluster("AWS Cloud"):
        route53 = Route53("Route53\nDNS")
        api_gw = APIGateway("API Gateway")
        
        with Cluster("VPC"):
            alb = ELB("ALB")
            
            with Cluster("ECS Fargate"):
                auth = ECS("Auth\nService")
                video = ECS("Video\nService")
                job_api = ECS("Job API\nService")
            
            with Cluster("Serverless Processing"):
                video_lambda = Lambda("Video\nProcessor")
                notify_lambda = Lambda("Notification\nHandler")
        
        with Cluster("Managed Data"):
            rds = RDS("RDS\nPostgreSQL")
            s3_input = S3("S3 Input\nVideos")
            s3_output = S3("S3 Output\nFrames")
        
        with Cluster("Messaging"):
            sqs = SQS("SQS\nJob Queue")
            sqs_dlq = SQS("SQS\nDead Letter")
            sns = SNS("SNS\nNotifications")
        
        ses = SES("SES\nEmail")
        cloudwatch = Cloudwatch("CloudWatch\nLogs")
    
    # User flow
    users >> route53 >> api_gw >> alb
    alb >> [auth, video, job_api]
    
    # Data flow
    auth >> rds
    video >> rds
    video >> s3_input
    video >> sqs
    job_api >> rds
    
    # Processing flow
    sqs >> video_lambda
    video_lambda >> s3_input
    video_lambda >> s3_output
    video_lambda >> sns
    sqs >> Edge(label="DLQ") >> sqs_dlq
    
    # Notification flow
    sns >> notify_lambda
    notify_lambda >> ses
    notify_lambda >> rds

print("✅ New architecture diagram generated: architecture_aws_managed.png")
