# AWS Proof of Concepts

This repository contains four proof of concept (POC) implementations for AWS solutions architecture patterns. Each POC demonstrates a different architectural approach to solving common cloud challenges.

## Repository Structure

```
aws-proof-of-concepts/
├── poc-1-serverless-architecture/     # Serverless application architecture
├── poc-2-containerized-microservices/ # Container-based microservices
├── poc-3-data-lake-analytics/         # Data lake and analytics platform
├── poc-4-hybrid-cloud-connectivity/   # Hybrid cloud connectivity solution
└── README.md                          # This file
```

## Implementation Approach

Each proof of concept is implemented using:

- **AWS CloudFormation** for infrastructure as code
- **AWS CLI** for deployment and management
- **Architecture diagrams** to visualize the solution
- **Lambda functions** (where applicable) for serverless compute

## Proof of Concepts

### POC 1: Serverless Architecture

A serverless application architecture using AWS Lambda, API Gateway, DynamoDB, and other serverless services.

### POC 2: Containerized Microservices

A microservices architecture using Amazon ECS/EKS, ECR, and related container services.

### POC 3: Data Lake Analytics

A data lake solution using S3, Athena, Glue, and other AWS analytics services.

### POC 4: Hybrid Cloud Connectivity

A hybrid cloud connectivity solution using VPC, Direct Connect, Transit Gateway, and related networking services.

## Getting Started

Each POC directory contains its own README.md with specific instructions for deployment and testing.

## Deployment and Teardown

All POCs in this repository follow a consistent approach to deployment and teardown:

### Deployment

Each POC includes a PowerShell deployment script (`deploy.ps1`) in its `infrastructure/scripts` directory. The script supports deploying the entire stack or individual components:

```powershell
# Navigate to the POC's scripts directory
cd poc-X-name/infrastructure/scripts

# Deploy all components
./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component all -RunTests $true
```

### Teardown

To remove deployed infrastructure, each POC includes a teardown script (`teardown.ps1`) in its `infrastructure/scripts` directory:

```powershell
# Navigate to the POC's scripts directory
cd poc-X-name/infrastructure/scripts

# Remove all components
./teardown.ps1 -Environment dev -Force $false
```

The script will list all stacks that will be deleted and prompt for confirmation unless `-Force $true` is specified.

### Common Parameters

#### Deployment Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Deployment environment (dev, test, prod) | Yes | - |
| EmailAddress | Email address for notifications | Yes | - |
| S3BucketName | S3 bucket for CloudFormation templates | Yes | - |
| Component | Component to deploy (varies by POC) | No | all |
| RunTests | Whether to run tests after deployment | No | $true |

#### Teardown Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Environment name (dev, test, prod) | No | dev |
| StackNamePrefix | Prefix used for all stack names | No | varies by POC |
| Region | AWS region where stacks are deployed | No | us-east-1 |
| Force | Skip confirmation prompt | No | $false |
| Component | Component to delete (varies by POC) | No | all |

Refer to each POC's README.md for specific deployment and teardown instructions.

## Requirements

- AWS CLI configured with appropriate credentials
- PowerShell (pwsh) installed
- Basic understanding of CloudFormation templates
- Python 3.8+ (for Lambda function development)
- Docker (for containerized microservices POC)
