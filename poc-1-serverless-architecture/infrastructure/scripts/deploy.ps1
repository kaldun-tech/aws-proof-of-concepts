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

.PARAMETER RunTests
    Whether to run tests after deployment.

.PARAMETER Profile
    The AWS CLI profile to use for authentication. Optional - uses default profile if not specified.

.EXAMPLE
    ./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Component all -RunTests $true

.EXAMPLE
    ./deploy.ps1 -Environment dev -EmailAddress your-email@example.com -S3BucketName your-bucket-name -Profile my-sso-profile
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
    [ValidateSet("all", "iam", "dynamodb", "sqs", "lambda", "sns", "api-gateway", "cloudwatch")]
    [string]$Component = "all",

    [Parameter(Mandatory=$false)]
    [bool]$RunTests = $true,

    [Parameter(Mandatory=$false)]
    [string]$Profile = ""
)

# Set the AWS region
$region = "us-east-1"
$stackNamePrefix = "poc"
$templateDir = Join-Path $PSScriptRoot ".." "cloudformation"

# Set up AWS CLI profile parameter
$awsProfile = ""
if ($Profile) {
    $awsProfile = "--profile $Profile"
    Write-Host "Using AWS profile: $Profile"
    # Verify the profile is working
    try {
        $identity = aws sts get-caller-identity --profile $Profile | ConvertFrom-Json
        Write-Host "Authenticated as: $($identity.Arn)"
    } catch {
        Write-Error "Failed to authenticate with profile '$Profile'. Please check your AWS configuration."
        exit 1
    }
} else {
    # Test default credentials
    try {
        $identity = aws sts get-caller-identity | ConvertFrom-Json
        Write-Host "Using default AWS credentials. Authenticated as: $($identity.Arn)"
    } catch {
        Write-Error "No valid AWS credentials found. Please run 'aws configure' or specify a profile with -Profile parameter."
        exit 1
    }
}

# Function to invoke AWS CLI with proper profile handling
function Invoke-AwsCli {
    param([string]$Command)
    
    if ($awsProfile) {
        $fullCommand = "aws $awsProfile $Command"
    } else {
        $fullCommand = "aws $Command"
    }
    
    Invoke-Expression $fullCommand
}

# Function to check if S3 bucket exists, create if it doesn't
function New-S3Bucket {
    param (
        [string]$bucketName
    )

    try {
        Write-Host "Checking if S3 bucket $bucketName exists..."
        aws s3api head-bucket --bucket $bucketName 2>&1
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
function ConvertTo-CloudFormationPackage {
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
function New-CloudFormationStack {
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
            $cmd += "--capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND"
        }
        
        Write-Host "Executing: $cmd"
        Invoke-Expression $cmd
    }
    catch {
        Write-Error "Error deploying CloudFormation stack: $_"
        exit 1
    }
}

# Function to validate stack deployment success
function Test-StackDeployment {
    param (
        [string]$stackName
    )
    
    try {
        Write-Host "Validating stack deployment: $stackName..."
        $status = aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].StackStatus" --output text --region $region
        
        if ($status -like "*COMPLETE") {
            Write-Host "Stack $stackName deployed successfully with status: $status" -ForegroundColor Green
            return $true
        } else {
            Write-Host "Stack $stackName deployment status: $status" -ForegroundColor Yellow
            if ($status -like "*FAILED" -or $status -like "*ROLLBACK*") {
                Write-Error "Stack deployment failed or is in rollback state"
                return $false
            }
            return $true
        }
    } catch {
        Write-Error "Error validating stack deployment: $_"
        return $false
    }
}

# Ensure S3 bucket exists
New-S3Bucket -bucketName $S3BucketName

# Deploy IAM stack
if ($Component -eq "all" -or $Component -eq "iam") {
    $stackName = "$stackNamePrefix-iam"
    $templateFile = Join-Path $templateDir "iam.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters -capabilities $true
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "IAM stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy DynamoDB stack
if ($Component -eq "all" -or $Component -eq "dynamodb") {
    $stackName = "$stackNamePrefix-dynamodb"
    $templateFile = Join-Path $templateDir "dynamodb.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "DynamoDB stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy SQS stack
if ($Component -eq "all" -or $Component -eq "sqs") {
    $stackName = "$stackNamePrefix-sqs"
    $templateFile = Join-Path $templateDir "sqs.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "SQS stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy SNS stack
if ($Component -eq "all" -or $Component -eq "sns") {
    $stackName = "$stackNamePrefix-sns"
    $templateFile = Join-Path $templateDir "sns.yaml"
    $parameters = @{
        "Environment" = $Environment
        "EmailAddress" = $EmailAddress
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "SNS stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
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
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters -capabilities $true
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "IAM stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy API Gateway stack
if ($Component -eq "all" -or $Component -eq "api-gateway") {
    # Get outputs from previous stacks
    $sqsQueueURL = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sqs" --query "Stacks[0].Outputs[?OutputKey=='QueueURL'].OutputValue" --output text --region $region
    $sqsQueueARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sqs" --query "Stacks[0].Outputs[?OutputKey=='QueueARN'].OutputValue" --output text --region $region
    $apiGatewaySQSRoleARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-iam" --query "Stacks[0].Outputs[?OutputKey=='APIGatewaySQSRoleARN'].OutputValue" --output text --region $region

    $stackName = "$stackNamePrefix-api-gateway"
    $templateFile = Join-Path $templateDir "api-gateway.yaml"
    $parameters = @{
        "Environment" = $Environment
        "SQSQueueURL" = $sqsQueueURL
        "SQSQueueARN" = $sqsQueueARN
        "APIGatewaySQSRoleARN" = $apiGatewaySQSRoleARN
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "DynamoDB stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy main stack (if component is "all")
if ($Component -eq "all") {
    # Package the main template
    $mainTemplateFile = Join-Path $templateDir "main.yaml"
    $packagedMainTemplateFile = "packaged-main.yaml"
    ConvertTo-CloudFormationPackage -templateFile $mainTemplateFile -s3Bucket $S3BucketName -outputFile $packagedMainTemplateFile

    # Deploy the main stack
    $stackName = "$stackNamePrefix-main"
    $parameters = @{
        "Environment" = $Environment
        "EmailAddress" = $EmailAddress
    }
    New-CloudFormationStack -stackName $stackName -templateFile $packagedMainTemplateFile -parameters $parameters -capabilities $true
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "Main stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Function to test the deployed infrastructure
function Test-DeployedInfrastructure {
    param (
        [string]$stackNamePrefix,
        [string]$region
    )
    
    Write-Host "Testing deployed infrastructure..." -ForegroundColor Cyan
    
    # Create a hashtable to store test results
    $testResults = @{}
    
    try {
        # Test 1: Verify API Gateway endpoint is accessible
        $apiUrl = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-api-gateway" --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text --region $region
        if ($apiUrl) {
            Write-Host "API Gateway endpoint: $apiUrl" -ForegroundColor Green
            Write-Host "Testing API Gateway connectivity..." -ForegroundColor Cyan
            try {
                $response = Invoke-WebRequest -Uri $apiUrl -Method GET -TimeoutSec 10 -ErrorAction SilentlyContinue
                Write-Host "API Gateway connectivity test: Success (Status: $($response.StatusCode))" -ForegroundColor Green
                $testResults["APIGateway"] = @{ "Endpoint" = $apiUrl; "Status" = $response.StatusCode; "Connected" = $true }
            } catch {
                Write-Host "API Gateway connectivity test: Failed - $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Note: This might be expected if the API requires authentication or doesn't support GET requests" -ForegroundColor Yellow
                $testResults["APIGateway"] = @{ "Endpoint" = $apiUrl; "Error" = $_.Exception.Message; "Connected" = $false }
            }
        } else {
            Write-Host "API Gateway endpoint not found" -ForegroundColor Yellow
            $testResults["APIGateway"] = @{ "Found" = $false }
        }
        
        # Test 2: Verify DynamoDB table exists and is active
        $tableName = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-dynamodb" --query "Stacks[0].Outputs[?OutputKey=='TableName'].OutputValue" --output text --region $region
        if ($tableName) {
            $tableStatus = aws dynamodb describe-table --table-name $tableName --query "Table.TableStatus" --output text --region $region
            Write-Host "DynamoDB Table '$tableName' status: $tableStatus" -ForegroundColor Green
            $testResults["DynamoDB"] = @{ "TableName" = $tableName; "Status" = $tableStatus }
        } else {
            Write-Host "DynamoDB table not found" -ForegroundColor Yellow
            $testResults["DynamoDB"] = @{ "Found" = $false }
        }
        
        # Test 3: Verify SQS queue is accessible
        $queueUrl = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sqs" --query "Stacks[0].Outputs[?OutputKey=='QueueURL'].OutputValue" --output text --region $region
        if ($queueUrl) {
            # Get queue attributes and extract message count
            $messageCount = (aws sqs get-queue-attributes --queue-url $queueUrl --attribute-names All --region $region | ConvertFrom-Json).Attributes.ApproximateNumberOfMessages
            Write-Host "SQS Queue is accessible: $queueUrl (Messages: $messageCount)" -ForegroundColor Green
            # Store the message count in the test results
            $testResults["SQSQueue"] = @{ "QueueUrl" = $queueUrl; "MessageCount" = $messageCount }
        } else {
            Write-Host "SQS Queue URL not found" -ForegroundColor Yellow
            $testResults["SQSQueue"] = @{ "Found" = $false }
        }
        
        # Test 4: Verify SNS topic exists
        $topicArn = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-sns" --query "Stacks[0].Outputs[?OutputKey=='TopicARN'].OutputValue" --output text --region $region
        if ($topicArn) {
            # Check if topic exists by getting attributes
            aws sns get-topic-attributes --topic-arn $topicArn --region $region | Out-Null
            $subscriptionsCount = (aws sns list-subscriptions-by-topic --topic-arn $topicArn --region $region | ConvertFrom-Json).Subscriptions.Count
            Write-Host "SNS Topic is accessible: $topicArn (Subscriptions: $subscriptionsCount)" -ForegroundColor Green
            $testResults["SNSTopic"] = @{ "TopicArn" = $topicArn; "SubscriptionsCount" = $subscriptionsCount }
        } else {
            Write-Host "SNS Topic ARN not found" -ForegroundColor Yellow
            $testResults["SNSTopic"] = @{ "Found" = $false }
        }
        
        # Test 5: Verify Lambda functions exist and are active
        $lambdaFunctions = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-lambda" --query "Stacks[0].Outputs[?starts_with(OutputKey,'LambdaFunction')].OutputValue" --output text --region $region
        if ($lambdaFunctions) {
            $lambdaResults = @{}
            foreach ($function in $lambdaFunctions.Split()) {
                # Verify function exists
                aws lambda get-function --function-name $function --region $region | Out-Null
                $runtime = aws lambda get-function --function-name $function --query "Configuration.Runtime" --output text --region $region
                $state = aws lambda get-function --function-name $function --query "Configuration.State" --output text --region $region
                $memorySize = aws lambda get-function --function-name $function --query "Configuration.MemorySize" --output text --region $region
                Write-Host "Lambda function '$function' is $state (Runtime: $runtime, Memory: $memorySize MB)" -ForegroundColor Green
                $lambdaResults[$function] = @{ "Runtime" = $runtime; "State" = $state; "MemorySize" = $memorySize }
            }
            $testResults["Lambda"] = $lambdaResults
        } else {
            Write-Host "No Lambda functions found" -ForegroundColor Yellow
            $testResults["Lambda"] = @{ "Found" = $false }
        }
        
        Write-Host "Infrastructure testing completed" -ForegroundColor Cyan
        
        # Return the collected test results
        return $testResults
    } catch {
        Write-Error "Error testing infrastructure: $_"
        return $null
    }
}

Write-Host "Deployment completed successfully!"

# Run infrastructure tests if component is "all" or if explicitly requested, and RunTests is true
if (($Component -eq "all" -or $Component -eq "test") -and $RunTests) {
    Test-DeployedInfrastructure -stackNamePrefix $stackNamePrefix -region $region
}
