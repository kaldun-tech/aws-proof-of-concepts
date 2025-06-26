# Data Analytics Proof of Concept

## Overview
This proof of concept demonstrates a data analytics solution for ingesting, storing, and visualizing clickstream data using AWS managed services. The implementation focuses on using CloudFormation for infrastructure provisioning and AWS CLI for deployment and management.

## Business Context
A restaurant owner needs an analytics solution to derive insights from clickstream data related to menu items ordered in their restaurant. With limited staff for running and maintaining the solution, this POC leverages fully managed AWS services to minimize operational overhead.

## Architecture
The architecture follows this flow:
1. Amazon API Gateway ingests clickstream data
2. AWS Lambda transforms the data
3. Amazon Kinesis Data Firehose delivers the data to Amazon S3
4. Amazon Athena queries the data stored in S3
5. Amazon QuickSight visualizes the data through dashboards

![Architecture Diagram](docs/images/poc2-architecture.png)

## Directory Structure
```
poc-2-data-analytics/
├── docs/                       # Documentation
│   └── images/                 # Architecture diagrams and screenshots
├── infrastructure/             # Infrastructure as Code
│   ├── cloudformation/         # CloudFormation templates
│   │   ├── iam.yaml            # IAM policies and roles
│   │   ├── api-gateway.yaml    # API Gateway resources
│   │   ├── lambda.yaml         # Lambda function resources with embedded code
│   │   ├── firehose.yaml       # Kinesis Data Firehose resources
│   │   ├── s3.yaml             # S3 bucket resources
│   │   └── athena.yaml         # Athena resources
│   └── scripts/                # Deployment and utility scripts
└── README.md                   # This file
```

## Implementation Plan

1. Set up IAM policies and roles
   - Create CloudFormation templates for IAM policies and roles
   - Define policies for Lambda, Kinesis Data Firehose, S3, and Athena
   - Implement least privilege access for each service

2. Create S3 bucket for data storage
   - Create CloudFormation template for S3 bucket
   - Configure bucket policies and lifecycle rules
   - Set up appropriate partitioning structure for efficient querying

3. Create Lambda function for data transformation
   - Create CloudFormation template for Lambda function
   - Implement function code to transform clickstream data
   - Add proper error handling and logging

4. Set up Kinesis Data Firehose delivery stream
   - Create CloudFormation template for Firehose delivery stream
   - Configure S3 as the destination
   - Set up data transformation using Lambda

5. Create API Gateway REST API
   - Create CloudFormation template for API Gateway
   - Configure API resources, methods, and integration with Lambda
   - Set up appropriate request/response mappings
   - Deploy API to a stage

6. Create Athena table and queries
   - Create CloudFormation template for Athena resources
   - Define table schema for clickstream data
   - Create sample queries for common analytics use cases

7. Set up QuickSight dashboards (manual step)
   - Connect QuickSight to Athena
   - Create datasets based on Athena queries
   - Design visualizations and dashboards

## Deployment and Teardown Instructions

### Prerequisites
- AWS CLI installed and configured with appropriate credentials
- PowerShell (pwsh) installed
- S3 bucket for CloudFormation templates
- Email address for notifications (if applicable)

### Deployment

This project includes a comprehensive PowerShell deployment script that handles all aspects of deploying the infrastructure. You can deploy the entire stack or individual components.

#### Deploy the Entire Stack

```powershell
# Navigate to the scripts directory
cd infrastructure/scripts

# Deploy all components
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component all -RunTests $true
```

#### Deploy Individual Components

You can deploy specific components by changing the `-Component` parameter:

```powershell
# Deploy only IAM resources
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component iam

# Deploy only S3
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component s3

# Deploy only Lambda functions
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component lambda

# Deploy only Firehose
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component firehose

# Deploy only API Gateway
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component api-gateway

# Deploy only Athena resources
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component athena
```

#### Deployment Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Deployment environment (dev, test, prod) | Yes | - |
| EmailAddress | Email address for notifications | Yes | - |
| S3BucketName | S3 bucket for CloudFormation templates | Yes | - |
| Component | Component to deploy (all, iam, s3, lambda, firehose, api-gateway, athena) | No | all |
| RunTests | Whether to run tests after deployment | No | $true |

### Teardown

To remove the deployed infrastructure, use the teardown script:

```powershell
# Navigate to the scripts directory
cd infrastructure/scripts

# Remove all components
./teardown.ps1 -Environment dev -Force $false
```

The script will list all stacks that will be deleted and prompt for confirmation unless `-Force $true` is specified.

#### Teardown Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Environment name (dev, test, prod) | No | dev |
| StackNamePrefix | Prefix used for all stack names | No | poc |
| Region | AWS region where stacks are deployed | No | us-east-1 |
| Force | Skip confirmation prompt | No | $false |
| Component | Component to delete (all, iam, s3, lambda, firehose, api-gateway, athena) | No | all |

## Testing

### Testing the API Gateway

1. Get the API Gateway URL:
```powershell
aws cloudformation describe-stacks --stack-name "poc-api-gateway" --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text
```

2. Send a test clickstream event to the API:
```powershell
$payload = @{
    "timestamp" = (Get-Date).ToString("o")
    "menuItem" = "Pasta Carbonara"
    "quantity" = 2
    "price" = 15.99
    "customerId" = "cust123"
    "restaurantId" = "rest456"
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri "https://your-api-id.execute-api.us-east-1.amazonaws.com/dev/events" -Body $payload -ContentType "application/json"
```

### Verifying Data Flow

1. Check S3 for delivered data:
```powershell
aws s3 ls s3://your-bucket-name/clickstream-data/ --recursive
```

2. Query data with Athena:
```sql
SELECT 
    menuItem, 
    COUNT(*) as order_count, 
    SUM(quantity) as total_quantity, 
    SUM(price * quantity) as total_revenue
FROM clickstream_data
GROUP BY menuItem
ORDER BY total_revenue DESC
LIMIT 10;
```

## Architecture Diagram

The architecture diagram is available in the `docs/images/` directory. It visualizes the flow of data through the analytics pipeline:

1. Client sends clickstream data to API Gateway
2. API Gateway triggers Lambda function for transformation
3. Lambda function sends data to Kinesis Data Firehose
4. Firehose delivers data to S3 in optimized format
5. Athena queries data directly from S3
6. QuickSight creates visualizations from Athena queries

## References

- [AWS Documentation: Amazon Kinesis Data Firehose](https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html)
- [AWS Documentation: Amazon Athena](https://docs.aws.amazon.com/athena/latest/ug/what-is.html)
- [AWS Documentation: Amazon QuickSight](https://docs.aws.amazon.com/quicksight/latest/user/welcome.html)
