"""Generate architecture diagrams for Video Processor microservices."""
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import ECS, Lambda
from diagrams.aws.database import RDS, ElastiCache
from diagrams.aws.storage import S3
from diagrams.aws.network import ELB, APIGateway, Route53
from diagrams.aws.integration import SQS, SNS
from diagrams.aws.security import Cognito
from diagrams.aws.management import Cloudwatch
from diagrams.onprem.client import Users
from diagrams.onprem.container import Docker

# AWS Architecture
with Diagram("Video Processor - AWS Architecture", filename="architecture_aws", outformat="png", show=False):
    users = Users("Users")
    route53 = Route53("DNS")
    
    with Cluster("AWS Cloud"):
        api_gateway = APIGateway("API Gateway")
        
        with Cluster("Application Load Balancer"):
            alb = ELB("ALB")
        
        with Cluster("ECS Cluster"):
            with Cluster("Auth Service"):
                auth_service = ECS("Auth\nPort 8001")
            
            with Cluster("Video Service"):
                video_service = ECS("Video\nPort 8002")
            
            with Cluster("Job Service"):
                job_service = ECS("Job\nPort 8003")
            
            with Cluster("Notification Service"):
                notification_service = ECS("Notification\nPort 8004")
            
            with Cluster("Workers"):
                workers = ECS("Celery Workers")
        
        with Cluster("Data Layer"):
            rds = RDS("PostgreSQL")
            redis = ElastiCache("Redis")
            s3 = S3("S3 Bucket")
        
        with Cluster("Messaging"):
            sqs = SQS("SQS Queue")
            sns = SNS("SNS Topic")
    
    # Connections
    users >> route53 >> api_gateway >> alb
    alb >> auth_service
    alb >> video_service
    alb >> job_service
    alb >> notification_service
    
    auth_service >> rds
    video_service >> rds
    video_service >> s3
    job_service >> rds
    job_service >> s3
    job_service >> sqs
    notification_service >> rds
    notification_service >> sns
    
    workers >> sqs
    workers >> s3
    workers >> rds
    workers >> redis

# Local Development Architecture
with Diagram("Video Processor - Local Development", filename="architecture_local", outformat="png", show=False):
    users = Users("Developer")
    
    with Cluster("Docker Compose"):
        with Cluster("API Services"):
            auth = Docker("Auth\n:8001")
            video = Docker("Video\n:8002")
            job = Docker("Job\n:8003")
            notify = Docker("Notification\n:8004")
        
        with Cluster("Workers"):
            celery = Docker("Celery\nWorker")
            flower = Docker("Flower\n:5555")
        
        with Cluster("Infrastructure"):
            postgres = Docker("PostgreSQL\n:5433")
            redis_svc = Docker("Redis\n:6379")
            rabbitmq = Docker("RabbitMQ\n:5672")
            minio = Docker("MinIO\n:9000")
    
    users >> auth
    users >> video
    users >> job
    users >> notify
    
    auth >> postgres
    video >> postgres
    video >> minio
    job >> postgres
    job >> minio
    job >> rabbitmq
    notify >> postgres
    
    celery >> rabbitmq
    celery >> minio
    celery >> redis_svc

print("✅ Diagrams generated: architecture_aws.png, architecture_local.png")
