#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deployment script for the E-Commerce Serverless Architecture.

.DESCRIPTION
    This script deploys the CloudFormation templates for the E-Commerce Serverless Architecture.
    It supports deploying the entire stack or individual components.

.PARAMETER Environment
    The environment to deploy to (dev, test, prod).

.PARAMETER EmailAddress
    The email address for SNS notifications.

.PARAMETER S3BucketName
    The name of the S3 bucket to store CloudFormation templates.

.PARAMETER Component
    The specific component to deploy (all, iam, dynamodb, sqs, lambda, sns, api-gateway).

.EXAMPLE
    ./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component all
#>

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [string]$EmailAddress,

    [Parameter(Mandatory=$true)]
    [string]$S3BucketName,

    [Parameter(Mandatory=$false)]
    [ValidateSet("all", "iam", "dynamodb", "sqs", "lambda", "sns", "api-gateway")]
    [string]$Component = "all"
)

# Set the AWS region
$region = "us-east-1"
$stackNamePrefix = "ecommerce-serverless-poc"
$templateDir = Join-Path $PSScriptRoot ".." "cloudformation"

# Function to check if S3 bucket exists, create if it doesn't
function Ensure-S3Bucket {
    param (
        [string]$bucketName
    )

    try {
        Write-Host "Checking if S3 bucket $bucketName exists..."
        $bucketExists = aws s3api head-bucket --bucket $bucketName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Creating S3 bucket $bucketName..."
            aws s3 mb s3://$bucketName --region $region
        }
        else {
            Write-Host "S3 bucket $bucketName already exists."
        }
    }
    catch {
        Write-Error "Error checking/creating S3 bucket: $_"
        exit 1
    }
}

# Function to package CloudFormation templates
function Package-CloudFormationTemplate {
    param (
        [string]$templateFile,
        [string]$s3Bucket,
        [string]$outputFile
    )

    try {
        Write-Host "Packaging CloudFormation template $templateFile..."
        aws cloudformation package `
            --template-file $templateFile `
            --s3-bucket $s3Bucket `
            --output-template-file $outputFile `
            --region $region
    }
    catch {
        Write-Error "Error packaging CloudFormation template: $_"
        exit 1
    }
}

# Function to deploy CloudFormation stack
function Deploy-CloudFormationStack {
    param (
        [string]$stackName,
        [string]$templateFile,
        [hashtable]$parameters,
        [bool]$capabilities = $false
    )

    try {
        Write-Host "Deploying CloudFormation stack $stackName..."
        
        $paramString = ""
        foreach ($key in $parameters.Keys) {
            $paramString += "$key=$($parameters[$key]) "
        }
        
        $cmd = "aws cloudformation deploy " +
               "--template-file $templateFile " +
               "--stack-name $stackName " +
               "--region $region "
        
        if ($paramString) {
            $cmd += "--parameter-overrides $paramString "
        }
        
        if ($capabilities) {
            $cmd += "--capabilities CAPABILITY_NAMED_IAM"
        }
        
        Invoke-Expression $cmd
    }
    catch {
        Write-Error "Error deploying CloudFormation stack: $_"
        exit 1
    }
}

# Ensure S3 bucket exists
Ensure-S3Bucket -bucketName $S3BucketName

# Deploy IAM stack
if ($Component -eq "all" -or $Component -eq "iam") {
    $stackName = "$stackNamePrefix-iam"
    $templateFile = Join-Path $templateDir "iam.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    Deploy-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters -capabilities $true
}

# Deploy DynamoDB stack
if ($Component -eq "all" -or $Component -eq "dynamodb") {
    $stackName = "$stackNamePrefix-dynamodb"
    $templateFile = Join-Path $templateDir "dynamodb.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    Deploy-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
}

# Deploy SQS stack
if ($Component -eq "all" -or $Component -eq "sqs") {
    $stackName = "$stackNamePrefix-sqs"
    $templateFile = Join-Path $templateDir "sqs.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    Deploy-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
}

# Deploy SNS stack
if ($Component -eq "all" -or $Component -eq "sns") {
    $stackName = "$stackNamePrefix-sns"
    $templateFile = Join-Path $templateDir "sns.yaml"
    $parameters = @{
        "Environment" = $Environment
        "EmailAddress" = $EmailAddress
    }
    Deploy-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
}

# Deploy Lambda stack
if ($Component -eq "all" -or $Component -eq "lambda") {
    # Get outputs from previous stacks
    $dynamoDBTableName = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-dynamodb" --query "Stacks[0].Outputs[?OutputKey=='TableName'].OutputValue" --output text --region $region
    $sqsQueueURL = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sqs" --query "Stacks[0].Outputs[?OutputKey=='QueueURL'].OutputValue" --output text --region $region
    $sqsQueueARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sqs" --query "Stacks[0].Outputs[?OutputKey=='QueueARN'].OutputValue" --output text --region $region
    $snsTopicARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sns" --query "Stacks[0].Outputs[?OutputKey=='TopicARN'].OutputValue" --output text --region $region
    $lambdaSQSDynamoDBRoleARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-iam" --query "Stacks[0].Outputs[?OutputKey=='LambdaSQSDynamoDBRoleARN'].OutputValue" --output text --region $region
    $lambdaDynamoDBSNSRoleARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-iam" --query "Stacks[0].Outputs[?OutputKey=='LambdaDynamoDBSNSRoleARN'].OutputValue" --output text --region $region

    $stackName = "$stackNamePrefix-lambda"
    $templateFile = Join-Path $templateDir "lambda.yaml"
    $parameters = @{
        "Environment" = $Environment
        "DynamoDBTableName" = $dynamoDBTableName
        "SQSQueueURL" = $sqsQueueURL
        "SQSQueueARN" = $sqsQueueARN
        "SNSTopicARN" = $snsTopicARN
        "LambdaSQSDynamoDBRoleARN" = $lambdaSQSDynamoDBRoleARN
        "LambdaDynamoDBSNSRoleARN" = $lambdaDynamoDBSNSRoleARN
    }
    Deploy-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters -capabilities $true
}

# Deploy API Gateway stack
if ($Component -eq "all" -or $Component -eq "api-gateway") {
    # Get outputs from previous stacks
    $sqsQueueURL = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sqs" --query "Stacks[0].Outputs[?OutputKey=='QueueURL'].OutputValue" --output text --region $region
    $sqsQueueARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sqs" --query "Stacks[0].Outputs[?OutputKey=='QueueARN'].OutputValue" --output text --region $region

    $stackName = "$stackNamePrefix-api-gateway"
    $templateFile = Join-Path $templateDir "api-gateway.yaml"
    $parameters = @{
        "Environment" = $Environment
        "SQSQueueURL" = $sqsQueueURL
        "SQSQueueARN" = $sqsQueueARN
    }
    Deploy-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
}

# Deploy main stack (if component is "all")
if ($Component -eq "all") {
    # Package the main template
    $mainTemplateFile = Join-Path $templateDir "main.yaml"
    $packagedMainTemplateFile = "packaged-main.yaml"
    Package-CloudFormationTemplate -templateFile $mainTemplateFile -s3Bucket $S3BucketName -outputFile $packagedMainTemplateFile

    # Deploy the main stack
    $stackName = "$stackNamePrefix"
    $parameters = @{
        "Environment" = $Environment
        "EmailAddress" = $EmailAddress
    }
    Deploy-CloudFormationStack -stackName $stackName -templateFile $packagedMainTemplateFile -parameters $parameters -capabilities $true
}

Write-Host "Deployment completed successfully!"
