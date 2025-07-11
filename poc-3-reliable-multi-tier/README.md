# POC 3: Reliable Multi-Tier Infrastructure

This proof of concept demonstrates how to deploy a reliable multi-tier infrastructure using AWS CloudFormation, following the AWS Well-Architected Reliability pillar best practices.

## Architecture Overview

This POC deploys a reliable multi-tier web application architecture with the following components:

1. **VPC Infrastructure**: A secure network foundation with public, private, and database subnets across multiple Availability Zones
2. **Static Web Application**: A highly available web application deployed across multiple AZs with auto-scaling capabilities

## Components

The infrastructure is deployed using the following CloudFormation templates:

- `vpc.yaml`: Creates a multi-tier VPC with subnets for application load balancer, application, database, and shared services
- `staticwebapp.yaml`: Deploys a highly-available, scalable web application with an Application Load Balancer, Auto Scaling Group, and DynamoDB table

## Prerequisites

- AWS CLI installed and configured with appropriate credentials
- PowerShell installed
- AWS account with permissions to create the required resources

## Deployment

To deploy the infrastructure, use the provided `deploy.ps1` script:

```powershell
cd poc-3-reliable-multi-tier\infrastructure\scripts
.\deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name
```

### Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Deployment environment (dev, test, prod) | Yes | - |
| EmailAddress | Email address for notifications | Yes | - |
| S3BucketName | S3 bucket for CloudFormation templates | Yes | - |
| Region | AWS region to deploy to | No | us-east-1 |
| StackNamePrefix | Prefix for CloudFormation stack names | No | WebApp1 |

## Teardown

To remove the deployed infrastructure, use the provided `teardown.ps1` script:

```powershell
cd poc-3-reliable-multi-tier\infrastructure\scripts
.\teardown.ps1 -Environment dev -Force $false
```

### Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Environment name (dev, test, prod) | No | dev |
| StackNamePrefix | Prefix used for all stack names | No | WebApp1 |
| Region | AWS region where stacks are deployed | No | us-east-1 |
| Force | Skip confirmation prompt | No | $false |

## Reliability Features

This POC demonstrates the following reliability best practices:

1. **Multi-AZ Deployment**: Resources are deployed across multiple Availability Zones
2. **Auto Scaling**: Web application tier scales automatically based on demand
3. **Load Balancing**: Application Load Balancer distributes traffic across healthy instances
4. **Health Checks**: Continuous monitoring of instance health
5. **VPC Flow Logs**: Network traffic logging for troubleshooting and security analysis

## Testing Reliability

After deployment, you can test the reliability of the infrastructure by:

1. Accessing the web application URL provided in the CloudFormation outputs
2. Simulating instance failures to verify auto-recovery
3. Testing scaling capabilities by generating load

## Resources

- [AWS Well-Architected Framework - Reliability Pillar](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
- [AWS CloudFormation Documentation](https://docs.aws.amazon.com/cloudformation/)
