#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Teardown script for the E-Commerce Serverless Architecture.

.DESCRIPTION
    This script deletes all CloudFormation stacks created by the deploy.ps1 script.
    It deletes the stacks in the reverse order of their creation to handle dependencies properly.

.PARAMETER Environment
    The environment name (dev, test, prod).

.PARAMETER StackNamePrefix
    The prefix used for all stack names. If not provided, it will be constructed from the project name and environment.

.PARAMETER Region
    The AWS region where the stacks are deployed.

.PARAMETER Force
    If specified, will not prompt for confirmation before deleting stacks.

.PARAMETER Component
    The specific component to delete (all, iam, dynamodb, sqs, lambda, sns, api-gateway, main).
    Default is "all" which will delete all stacks in the correct order.

.PARAMETER Profile
    The AWS CLI profile to use for authentication. Optional - uses default profile if not specified.

.EXAMPLE
    ./teardown.ps1 -Environment dev -Force $false

.EXAMPLE
    ./teardown.ps1 -Environment dev -Force $false -Profile my-sso-profile
#>

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory=$false)]
    [string]$StackNamePrefix = "",

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [bool]$Force = $false,

    [Parameter(Mandatory=$false)]
    [ValidateSet("all", "iam", "dynamodb", "sqs", "lambda", "sns", "api-gateway", "main")]
    [string]$Component = "all",

    [Parameter(Mandatory=$false)]
    [string]$Profile = ""
)

# Set up AWS CLI profile parameter
if ($Profile) {
    $env:AWS_PROFILE = $Profile
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

# Set the stack name prefix if not provided
if (-not $StackNamePrefix) {
    $StackNamePrefix = "poc"
}

# Function to check if a stack exists
function Test-StackExists {
    param (
        [string]$stackName
    )
    
    try {
        aws cloudformation describe-stacks --stack-name $stackName --region $Region 2>$null
        return $true
    }
    catch {
        return $false
    }
}

# Function to delete a CloudFormation stack
function Remove-CloudFormationStack {
    param (
        [string]$stackName,
        [bool]$waitForCompletion = $true
    )

    if (-not (Test-StackExists -stackName $stackName)) {
        Write-Host "Stack $stackName does not exist. Skipping deletion." -ForegroundColor Yellow
        return $true
    }

    try {
        Write-Host "Deleting CloudFormation stack $stackName..." -ForegroundColor Cyan
        
        # Delete the stack
        aws cloudformation delete-stack --stack-name $stackName --region $Region
        
        if ($waitForCompletion) {
            Write-Host "Waiting for stack deletion to complete..." -ForegroundColor Cyan
            aws cloudformation wait stack-delete-complete --stack-name $stackName --region $Region
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Stack $stackName deleted successfully." -ForegroundColor Green
                return $true
            } else {
                Write-Error "Failed to delete stack $stackName."
                return $false
            }
        } else {
            Write-Host "Stack deletion initiated for $stackName. Not waiting for completion." -ForegroundColor Yellow
            return $true
        }
    }
    catch {
        Write-Error "Error deleting CloudFormation stack: $_"
        return $false
    }
}

# Function to confirm deletion
function Confirm-Deletion {
    param (
        [string]$message
    )
    
    if ($Force) {
        return $true
    }
    
    $confirmation = Read-Host "$message (y/n)"
    return $confirmation -eq "y" -or $confirmation -eq "Y"
}

# Display warning message
Write-Host "WARNING: This script will delete AWS resources. This action cannot be undone." -ForegroundColor Red
Write-Host "The following stacks will be deleted based on your selection:" -ForegroundColor Yellow

# List stacks that will be deleted
$stacksToDelete = @()

if ($Component -eq "all" -or $Component -eq "main") {
    $mainStack = "$StackNamePrefix-main"
    if (Test-StackExists -stackName $mainStack) {
        $stacksToDelete += $mainStack
        Write-Host "- $mainStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "api-gateway") {
    $apiGatewayStack = "$StackNamePrefix-api-gateway"
    if (Test-StackExists -stackName $apiGatewayStack) {
        $stacksToDelete += $apiGatewayStack
        Write-Host "- $apiGatewayStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "lambda") {
    $lambdaStack = "$StackNamePrefix-lambda"
    if (Test-StackExists -stackName $lambdaStack) {
        $stacksToDelete += $lambdaStack
        Write-Host "- $lambdaStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "sns") {
    $snsStack = "$StackNamePrefix-sns"
    if (Test-StackExists -stackName $snsStack) {
        $stacksToDelete += $snsStack
        Write-Host "- $snsStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "sqs") {
    $sqsStack = "$StackNamePrefix-sqs"
    if (Test-StackExists -stackName $sqsStack) {
        $stacksToDelete += $sqsStack
        Write-Host "- $sqsStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "dynamodb") {
    $dynamodbStack = "$StackNamePrefix-dynamodb"
    if (Test-StackExists -stackName $dynamodbStack) {
        $stacksToDelete += $dynamodbStack
        Write-Host "- $dynamodbStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "iam") {
    $iamStack = "$StackNamePrefix-iam"
    if (Test-StackExists -stackName $iamStack) {
        $stacksToDelete += $iamStack
        Write-Host "- $iamStack" -ForegroundColor Yellow
    }
}

# If no stacks found
if ($stacksToDelete.Count -eq 0) {
    Write-Host "No matching stacks found to delete." -ForegroundColor Green
    exit 0
}

# Confirm deletion
if (-not (Confirm-Deletion -message "Are you sure you want to delete these stacks?")) {
    Write-Host "Teardown cancelled." -ForegroundColor Yellow
    exit 0
}

# Delete stacks in reverse order (to handle dependencies)
$success = $true

foreach ($stack in $stacksToDelete) {
    $result = Remove-CloudFormationStack -stackName $stack -waitForCompletion $true
    if (-not $result) {
        $success = $false
        Write-Warning "Failed to delete stack $stack. Continuing with other stacks..."
    }
}

# Final status message
if ($success) {
    Write-Host "All selected stacks have been deleted successfully." -ForegroundColor Green
} else {
    Write-Host "Some stacks could not be deleted. Please check the AWS CloudFormation console for details." -ForegroundColor Red
}

# Check for S3 buckets that might need manual cleanup
Write-Host "`nNOTE: This script does not delete S3 buckets created by the deployment." -ForegroundColor Yellow
Write-Host "If you want to delete associated S3 buckets, you'll need to do so manually using the AWS console or CLI." -ForegroundColor Yellow
