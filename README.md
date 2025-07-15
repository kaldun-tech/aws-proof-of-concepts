# AWS Proof of Concepts

This repository contains five proof of concept (POC) implementations for AWS solutions architecture patterns. Each POC demonstrates a different architectural approach to solving common cloud challenges.

## Repository Structure

```
aws-proof-of-concepts/
├── poc-1-serverless-architecture/     # Serverless e-commerce backend
├── poc-2-data-analytics/              # Clickstream data analytics pipeline
├── poc-3-reliable-multi-tier/         # Multi-tier web application infrastructure
├── poc-4-migration-analytics/         # On-premises to AWS migration strategy
├── poc-5-disaster-recovery/           # Personal computer disaster recovery backup
└── README.md                          # This file
```

## Implementation Approach

Each proof of concept is implemented using:

- **AWS CloudFormation** for infrastructure as code
- **AWS CLI** for deployment and management
- **Architecture diagrams** to visualize the solution
- **Lambda functions** (where applicable) for serverless compute

## Proof of Concepts

### POC 1: Serverless E-Commerce Architecture

A serverless e-commerce backend using AWS Lambda, API Gateway, SQS, DynamoDB, and SNS. Demonstrates event-driven architecture with automatic scaling, fault tolerance, and cost optimization.

### POC 2: Data Analytics Pipeline

A clickstream data analytics solution using Amazon API Gateway, Lambda, Kinesis Data Firehose, S3, Athena, and QuickSight to ingest, store, and visualize restaurant menu interaction data.

### POC 3: Reliable Multi-Tier Infrastructure

A highly available multi-tier web application infrastructure using VPC, Application Load Balancer, Auto Scaling Groups, and DynamoDB. Demonstrates AWS reliability best practices across multiple Availability Zones.

### POC 4: On-Premises Migration Strategy

Comprehensive migration planning documentation for moving three-tier web applications and Hadoop analytics workloads from on-premises to AWS, covering lift-and-shift vs re-platforming approaches.

### POC 5: Personal Disaster Recovery

A cost-effective personal computer backup solution using S3 Glacier Deep Archive storage. Includes automated backup scripts, restore workflows, and monitoring for long-term data protection at approximately $1/TB/month.

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
