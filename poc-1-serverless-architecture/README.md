# E-Commerce Serverless Architecture Proof of Concept

## Overview
This proof of concept demonstrates a serverless architecture for an e-commerce web backend using AWS Lambda, API Gateway, SQS, DynamoDB, DynamoDB Streams, and SNS. The implementation focuses on using CloudFormation for infrastructure provisioning and AWS CLI for deployment and management.

## Business Context
An e-commerce company selling cleaning supplies needs a serverless web backend that can easily scale in and out as demand changes. The company experiences frequent spikes in demand and requires an architecture with decoupled application components.

## Architecture
The architecture follows this flow:
1. REST API (API Gateway) places a database entry in an SQS queue
2. SQS invokes the first Lambda function (POC-Lambda-1)
3. Lambda function inserts the entry into a DynamoDB table
4. DynamoDB Streams captures the new entry and invokes a second Lambda function (POC-Lambda-2)
5. The second Lambda function passes the database entry to SNS
6. SNS sends a notification to the specified email address

![Architecture Diagram](docs/images/architecture-diagram.png)

## Directory Structure
```
poc-1-serverless-architecture/
├── src/                        # Source code
│   ├── lambda/                 # Lambda function code
│   │   ├── poc-lambda-1/       # First Lambda function (SQS to DynamoDB)
│   │   └── poc-lambda-2/       # Second Lambda function (DynamoDB to SNS)
│   └── api/                    # API Gateway configuration
├── docs/                       # Documentation
│   ├── images/                 # Architecture diagrams and screenshots
│   └── guides/                 # Implementation guides and notes
├── infrastructure/             # Infrastructure as Code
│   ├── cloudformation/         # CloudFormation templates
│   │   ├── main.yaml           # Main stack template
│   │   ├── iam.yaml            # IAM policies and roles
│   │   ├── api-gateway.yaml    # API Gateway resources
│   │   ├── sqs.yaml            # SQS queue resources
│   │   ├── lambda.yaml         # Lambda functions resources
│   │   ├── dynamodb.yaml       # DynamoDB table and streams
│   │   └── sns.yaml            # SNS topic and subscriptions
│   └── scripts/                # Deployment and utility scripts
└── README.md                   # This file
```

## Implementation Plan

1. Set up IAM policies and roles
   - Create CloudFormation templates for IAM policies and roles
   - Define policies for Lambda-SQS-DynamoDB role and Lambda-DynamoDB-SNS role
   - Implement least privilege access for each service

2. Create DynamoDB table
   - Create CloudFormation template for DynamoDB table
   - Configure primary key and capacity settings
   - Enable DynamoDB Streams for capturing table modifications

3. Set up SQS queue
   - Create CloudFormation template for SQS queue
   - Configure queue settings and permissions
   - Set up dead-letter queue for error handling

4. Implement first Lambda function (POC-Lambda-1)
   - Create CloudFormation template for Lambda function
   - Implement function code to process SQS messages and write to DynamoDB
   - Configure SQS as trigger for the Lambda function
   - Add proper error handling and logging

5. Enable DynamoDB Streams
   - Configure DynamoDB Streams in CloudFormation template
   - Set up stream to capture item-level changes

6. Create SNS topic and subscription
   - Create CloudFormation template for SNS topic
   - Configure email subscription for notifications
   - Set up appropriate access policies

7. Implement second Lambda function (POC-Lambda-2)
   - Create CloudFormation template for second Lambda function
   - Implement function code to process DynamoDB stream events and publish to SNS
   - Configure DynamoDB Streams as trigger for the Lambda function
   - Add proper error handling and logging

8. Create API Gateway REST API
   - Create CloudFormation template for API Gateway
   - Configure API resources, methods, and integration with SQS
   - Set up appropriate request/response mappings
   - Deploy API to a stage

## CloudFormation Deployment

### Prerequisites
- AWS CLI installed and configured
- S3 bucket for CloudFormation templates (optional)
- Email address for SNS notifications

### Deployment Steps

1. Create an S3 bucket for CloudFormation templates (optional):
```bash
aws s3 mb s3://ecommerce-serverless-poc-templates
```

2. Package the CloudFormation templates:
```bash
aws cloudformation package \
  --template-file infrastructure/cloudformation/main.yaml \
  --s3-bucket ecommerce-serverless-poc-templates \
  --output-template-file packaged-main.yaml
```

3. Deploy the main stack with all nested stacks:
```bash
aws cloudformation deploy \
  --template-file packaged-main.yaml \
  --stack-name ecommerce-serverless-poc \
  --parameter-overrides \
      Environment=dev \
      EmailAddress=your-email@example.com \
  --capabilities CAPABILITY_NAMED_IAM
```

4. Deploy individual components (if not using nested stacks):

   a. Deploy IAM resources:
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation/iam.yaml \
     --stack-name ecommerce-serverless-poc-iam \
     --capabilities CAPABILITY_NAMED_IAM
   ```

   b. Deploy DynamoDB table:
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation/dynamodb.yaml \
     --stack-name ecommerce-serverless-poc-dynamodb
   ```

   c. Deploy SQS queue:
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation/sqs.yaml \
     --stack-name ecommerce-serverless-poc-sqs
   ```

   d. Deploy Lambda functions:
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation/lambda.yaml \
     --stack-name ecommerce-serverless-poc-lambda \
     --capabilities CAPABILITY_IAM
   ```

   e. Deploy SNS topic:
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation/sns.yaml \
     --stack-name ecommerce-serverless-poc-sns \
     --parameter-overrides EmailAddress=your-email@example.com
   ```

   f. Deploy API Gateway:
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation/api-gateway.yaml \
     --stack-name ecommerce-serverless-poc-api
   ```

## Architecture Diagram

The architecture diagram is available in the `docs/images/` directory. It visualizes the flow of data through the serverless architecture:

1. Client sends request to API Gateway
2. API Gateway places message in SQS queue
3. SQS triggers Lambda function 1 (POC-Lambda-1)
4. Lambda function 1 writes data to DynamoDB
5. DynamoDB Streams captures the change and triggers Lambda function 2 (POC-Lambda-2)
6. Lambda function 2 publishes message to SNS topic
7. SNS sends email notification to subscribed email address

## Testing

### Testing the API Gateway

1. Get the API Gateway URL:
```bash
aws cloudformation describe-stacks \
  --stack-name ecommerce-serverless-poc-api \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" \
  --output text
```

2. Send a test request to the API:
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"productId": "12345", "productName": "Eco-Friendly Cleaner", "quantity": 2, "customerEmail": "customer@example.com"}' \
  https://your-api-id.execute-api.us-east-1.amazonaws.com/dev/orders
```

### Verifying the Flow

1. Check SQS queue for messages:
```bash
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/your-account-id/ecommerce-orders-queue \
  --attribute-names ApproximateNumberOfMessages
```

2. Check DynamoDB for inserted items:
```bash
aws dynamodb scan \
  --table-name ecommerce-orders
```

3. Verify email notification received at the subscribed email address.
