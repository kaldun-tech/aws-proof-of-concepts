# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains four AWS proof-of-concept implementations demonstrating different cloud architecture patterns. Each POC is self-contained with its own infrastructure, documentation, and deployment scripts.

## Architecture Structure

The repository follows a consistent pattern across all POCs:

```
poc-{n}-{name}/
├── README.md                    # POC-specific documentation
├── docs/images/                 # Architecture diagrams
├── infrastructure/
│   ├── cloudformation/          # CloudFormation templates
│   └── scripts/                 # PowerShell deployment scripts
└── (additional POC-specific directories)
```

### POC Descriptions

1. **POC 1: Serverless Architecture** - E-commerce backend using API Gateway, Lambda, SQS, DynamoDB, SNS
2. **POC 2: Data Analytics** - Clickstream analytics pipeline with API Gateway, Lambda, Kinesis Firehose, S3, Athena, QuickSight
3. **POC 3: Reliable Multi-Tier** - Highly available web application with VPC, ELB, Auto Scaling, Aurora
4. **POC 4: Migration Analytics** - On-premises to AWS migration strategy (documentation only)

## Deployment Commands

### Standard Deployment Pattern

All POCs follow the same deployment/teardown pattern using PowerShell scripts:

```powershell
# Navigate to POC scripts directory
cd poc-{n}-{name}/infrastructure/scripts

# Deploy entire stack
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name

# Deploy specific component
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component {component-name}

# Teardown infrastructure
./teardown.ps1 -Environment dev -Force $false
```

### Common Parameters

**Deployment Parameters:**
- `Environment`: dev, test, or prod (required)
- `EmailAddress`: For SNS notifications (required for POC 1)
- `S3BucketName`: CloudFormation templates storage (required)
- `Component`: Specific component to deploy (optional, defaults to "all")
- `RunTests`: Run automated tests after deployment (optional, defaults to true)

**Teardown Parameters:**
- `Environment`: Environment to remove (optional, defaults to dev)
- `Force`: Skip confirmation prompts (optional, defaults to false)
- `StackNamePrefix`: CloudFormation stack prefix (varies by POC)

### POC-Specific Components

**POC 1:** iam, dynamodb, sqs, lambda, sns, api-gateway
**POC 2:** iam, s3, lambda, firehose, api-gateway, athena, quicksight
**POC 3:** vpc, staticwebapp

## Infrastructure as Code

All infrastructure is defined using AWS CloudFormation templates in YAML format. Templates are modular and handle dependencies through stack outputs/parameters.

### CloudFormation Stack Naming Convention
- POC 1: `poc-{component}-{environment}`
- POC 2: `poc2-data-analytics-{component}`
- POC 3: `{StackNamePrefix}-{component}-{environment}`

### Key Architectural Patterns

1. **Event-Driven Architecture**: POC 1 demonstrates serverless event chains (SQS → Lambda → DynamoDB → Streams → Lambda → SNS)
2. **Data Pipeline Architecture**: POC 2 shows data ingestion through API Gateway → Lambda → Firehose → S3 → Athena → QuickSight
3. **Multi-Tier Architecture**: POC 3 implements traditional web app layers with reliability features
4. **Migration Strategy**: POC 4 documents lift-and-shift vs re-platforming approaches

## Testing and Validation

Most POCs include automated testing via the deployment scripts. Tests validate:
- Infrastructure deployment success
- API endpoint functionality
- Data flow through pipelines
- Service integration

Access test results through CloudWatch logs and POC-specific validation endpoints.

## Prerequisites

- AWS CLI configured with appropriate credentials
- PowerShell (pwsh) installed
- S3 bucket for CloudFormation template storage
- Basic understanding of AWS services and CloudFormation

## Technical Architecture Details

### POC 1: Serverless E-Commerce Architecture

**Event-Driven Flow:**
1. API Gateway receives POST requests to `/orders` endpoint
2. API Gateway integrates directly with SQS using IAM role credentials
3. SQS triggers Lambda function (POC-Lambda-1) which processes messages and writes to DynamoDB
4. DynamoDB Streams captures table changes and triggers second Lambda (POC-Lambda-2)  
5. Second Lambda publishes notifications to SNS topic which emails subscribers

**Key Components:**
- **IAM Roles**: Separate roles for Lambda-SQS-DynamoDB and Lambda-DynamoDB-SNS operations
- **DynamoDB**: `ecommerce-orders` table with `NEW_IMAGE` streams enabled
- **SQS**: Main queue with dead letter queue for error handling (5 retry attempts)
- **Lambda Functions**: 
  - Lambda 1: Python 3.9, processes SQS messages, writes to DynamoDB table with UUID orderIDs
  - Lambda 2: Python 3.9, processes DynamoDB streams, publishes to SNS with JSON message structure
- **API Gateway**: REST API with direct SQS integration, no Lambda proxy required

**Deployment Strategy**: Dependencies handled through stack outputs/imports (IAM → DynamoDB/SQS/SNS → Lambda → API Gateway)

### POC 2: Data Analytics Pipeline

**Data Flow:**
1. API Gateway receives clickstream data (element_clicked, time_spent, source_menu, created_at)
2. Lambda function transforms data and adds newlines for proper formatting
3. Kinesis Data Firehose buffers and delivers data to S3 with partitioning by date/hour
4. Athena queries S3 data using partition projection for efficient querying
5. QuickSight creates visualizations from Athena datasets

**Key Components:**
- **Lambda Transform**: Python 3.8 function adds newlines to incoming JSON records for Firehose
- **Kinesis Firehose**: 
  - Buffers: 60 seconds or 5MB batches
  - S3 prefixes: `data/` for successful records, `error/` for failures
  - Data transformation via Lambda integration
- **S3 Storage**: Partitioned by `yyyy/MM/dd/HH` structure for optimal Athena performance
- **Athena Integration**:
  - Workgroup with CloudWatch metrics enabled
  - Table with partition projection (no manual partition management)
  - Named queries for common analytics patterns
  - JSON SerDe for parsing clickstream data

**Testing**: Automated tests send sample payloads and verify S3 delivery and Athena query execution

### POC 3: Reliable Multi-Tier Web Application

**Four-Tier VPC Architecture:**
1. **ALB Tier** (Public): Application Load Balancer across 3 AZs
2. **App Tier** (Private): EC2 instances with Auto Scaling, internet via NAT Gateways
3. **Database Tier** (Private): DynamoDB table, no internet access
4. **Shared Services Tier** (Public): NAT Gateways and VPC endpoints

**Reliability Features:**
- **Multi-AZ Deployment**: All tiers span 3 Availability Zones
- **Auto Scaling**: Min 3 instances (one per AZ), configurable max capacity
- **Health Checks**: ALB health checks every 15 seconds with 3-check thresholds
- **Network Resilience**: Dedicated NAT Gateway per AZ prevents single points of failure
- **Security**: Multi-layer security with NACLs and Security Groups

**VPC Design:**
- **CIDR**: 10.0.0.0/16 with /24 subnets (256 IPs each)
- **Subnet Allocation**: 
  - ALB: indices 1,2,3
  - App: indices 11,12,13  
  - DB: indices 31,32,33
  - Shared: indices 21,22,23
- **VPC Endpoints**: Gateway endpoints for S3/DynamoDB cost optimization

### POC 4: Migration Strategy (Documentation)
Comprehensive migration planning from on-premises to AWS covering lift-and-shift vs re-platforming approaches for three-tier web applications and Hadoop analytics workloads.

## CloudFormation Template Patterns

### Template Structure
All templates follow consistent patterns:
- **Parameters**: Environment, component-specific settings
- **Resources**: AWS resources with proper tagging
- **Outputs**: Values exported for cross-stack references
- **Dependencies**: Explicit DependsOn relationships where needed

### Cross-Stack Communication
- **Exports/Imports**: Stack outputs referenced via `!ImportValue`
- **Parameter Passing**: Main templates pass outputs as parameters to nested stacks
- **Naming Conventions**: Consistent export naming: `{StackName}-{ResourceType}-{Environment}`

### IAM Patterns
- **Least Privilege**: Granular policies for specific service interactions
- **Service Roles**: Dedicated roles for each service integration
- **Resource-Level Permissions**: ARN-specific permissions where possible

## Deployment Script Architecture

### PowerShell Script Features
- **Parameter Validation**: Enforced parameter sets and validation
- **S3 Bucket Management**: Automatic creation and verification
- **CloudFormation Packaging**: Template packaging for nested stack uploads
- **Deployment Orchestration**: Proper dependency ordering with validation
- **Testing Integration**: Automated testing post-deployment
- **Error Handling**: Comprehensive error checking and rollback capabilities

### Common Functions
- `New-S3Bucket`: S3 bucket creation with error handling
- `ConvertTo-CloudFormationPackage`: Template packaging for S3 upload
- `New-CloudFormationStack`: Stack deployment with parameter handling
- `Test-StackDeployment`: Deployment validation and status checking

## Working with POCs

### Development Workflow
1. Review the POC's README.md for specific architectural details
2. Examine CloudFormation templates to understand service configurations
3. Check deployment scripts for parameter requirements and component dependencies
4. Use deployment scripts for testing changes before committing
5. Follow established naming conventions for new resources
6. Update documentation if adding new components or changing architecture

### Debugging and Troubleshooting
- **CloudFormation Events**: Check stack events for deployment failures
- **CloudWatch Logs**: Lambda function logs, VPC Flow Logs
- **Service-Specific Logs**: API Gateway execution logs, ALB access logs
- **Resource Status**: Use AWS CLI to check resource states and configurations

### Best Practices
- Always deploy to development environment first
- Use the automated testing features to validate functionality
- Check CloudFormation drift detection for configuration changes
- Review IAM policies for security compliance
- Monitor costs using AWS Cost Explorer and budgets