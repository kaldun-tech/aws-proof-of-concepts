#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Teardown script for the Data Analytics POC.

.DESCRIPTION
    This script deletes all CloudFormation stacks created by the deploy.ps1 script.
    It deletes the stacks in the reverse order of their creation to handle dependencies properly.

.PARAMETER Environment
    The environment name (dev, test, prod).

.PARAMETER StackNamePrefix
    The prefix used for all stack names. If not provided, it defaults to "poc2-data-analytics".

.PARAMETER Region
    The AWS region where the stacks are deployed.

.PARAMETER Force
    If specified, will not prompt for confirmation before deleting stacks.

.PARAMETER Component
    The specific component to delete (all, iam, s3, lambda, firehose, api-gateway).
    Default is "all" which will delete all stacks in the correct order.

.EXAMPLE
    ./teardown.ps1 -Environment dev -Force $false
#>

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory=$false)]
    [string]$StackNamePrefix = "poc2-data-analytics",

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [bool]$Force = $false,

    [Parameter(Mandatory=$false)]
    [ValidateSet("all", "iam", "s3", "lambda", "firehose", "api-gateway", "athena")]
    [string]$Component = "all",
    
    [Parameter(Mandatory=$false)]
    [bool]$EmptyS3Bucket = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$Verify = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$ShowQuickSightInstructions = $true,
    
    [Parameter(Mandatory=$false)]
    [string]$Profile
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

# Function to check if a stack exists
function Test-StackExists {
    param (
        [string]$stackName
    )
    
    try {
        aws cloudformation describe-stacks --stack-name $stackName --region $Region 2>$null
        return $LASTEXITCODE -eq 0
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
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to initiate deletion of stack $stackName"
            return $false
        }
        
        if ($waitForCompletion) {
            Write-Host "Waiting for stack deletion to complete..." -ForegroundColor Cyan
            aws cloudformation wait stack-delete-complete --stack-name $stackName --region $Region
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Stack $stackName deleted successfully." -ForegroundColor Green
                return $true
            } else {
                Write-Error "Failed to delete stack $stackName. Please check the CloudFormation console for details."
                return $false
            }
        } else {
            Write-Host "Stack deletion initiated for $stackName. Not waiting for completion." -ForegroundColor Yellow
            return $true
        }
    }
    catch {
        Write-Error "Error deleting CloudFormation stack $stackName: $_"
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

if ($Component -eq "all" -or $Component -eq "athena") {
    $athenaStack = "$StackNamePrefix-athena"
    if (Test-StackExists -stackName $athenaStack) {
        $stacksToDelete += $athenaStack
        Write-Host "- $athenaStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "api-gateway") {
    $apiGatewayStack = "$StackNamePrefix-api-gateway"
    if (Test-StackExists -stackName $apiGatewayStack) {
        $stacksToDelete += $apiGatewayStack
        Write-Host "- $apiGatewayStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "firehose") {
    $firehoseStack = "$StackNamePrefix-firehose"
    if (Test-StackExists -stackName $firehoseStack) {
        $stacksToDelete += $firehoseStack
        Write-Host "- $firehoseStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "lambda") {
    $lambdaStack = "$StackNamePrefix-lambda"
    if (Test-StackExists -stackName $lambdaStack) {
        $stacksToDelete += $lambdaStack
        Write-Host "- $lambdaStack" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "s3") {
    $s3Stack = "$StackNamePrefix-s3"
    if (Test-StackExists -stackName $s3Stack) {
        $stacksToDelete += $s3Stack
        Write-Host "- $s3Stack" -ForegroundColor Yellow
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

# Verify resource deletion if requested
if ($Verify) {
    Write-Host ""
    Write-Host "Verifying resource deletion..." -ForegroundColor Cyan

    # Check CloudFormation stacks
    Write-Host "Checking for remaining CloudFormation stacks..." -ForegroundColor Yellow
    $remainingStacks = aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?contains(StackName, '$StackNamePrefix')].StackName" --output json --region $Region | ConvertFrom-Json
    if ($remainingStacks -and $remainingStacks.Count -gt 0) {
        Write-Host "The following stacks still exist:" -ForegroundColor Red
        foreach ($stack in $remainingStacks) {
            Write-Host "- $stack" -ForegroundColor Red
        }
    } else {
        Write-Host "✓ All CloudFormation stacks have been deleted" -ForegroundColor Green
    }

    # Check Lambda functions
    Write-Host "Checking for remaining Lambda functions..." -ForegroundColor Yellow
    $lambdaFunctions = aws lambda list-functions --query "Functions[?contains(FunctionName, 'transform-data-$Environment')].FunctionName" --output json --region $Region | ConvertFrom-Json
    if ($lambdaFunctions -and $lambdaFunctions.Count -gt 0) {
        Write-Host "The following Lambda functions still exist:" -ForegroundColor Red
        foreach ($function in $lambdaFunctions) {
            Write-Host "- $function" -ForegroundColor Red
        }
    } else {
        Write-Host "✓ All Lambda functions have been deleted" -ForegroundColor Green
    }

    # Check API Gateway
    Write-Host "Checking for remaining API Gateway APIs..." -ForegroundColor Yellow
    $apis = aws apigateway get-rest-apis --query "items[?contains(name, '$StackNamePrefix')].name" --output json --region $Region | ConvertFrom-Json
    if ($apis -and $apis.Count -gt 0) {
        Write-Host "The following API Gateway APIs still exist:" -ForegroundColor Red
        foreach ($api in $apis) {
            Write-Host "- $api" -ForegroundColor Red
        }
    } else {
        Write-Host "✓ All API Gateway APIs have been deleted" -ForegroundColor Green
    }

    # Check Firehose delivery streams
    Write-Host "Checking for remaining Firehose delivery streams..." -ForegroundColor Yellow
    $deliveryStreams = aws firehose list-delivery-streams --query "DeliveryStreamNames[?contains(@, '$StackNamePrefix')]" --output json --region $Region | ConvertFrom-Json
    if ($deliveryStreams -and $deliveryStreams.Count -gt 0) {
        Write-Host "The following Firehose delivery streams still exist:" -ForegroundColor Red
        foreach ($stream in $deliveryStreams) {
            Write-Host "- $stream" -ForegroundColor Red
        }
    } else {
        Write-Host "✓ All Firehose delivery streams have been deleted" -ForegroundColor Green
    }

    # Check Athena workgroups
    Write-Host "Checking for remaining Athena workgroups..." -ForegroundColor Yellow
    $workgroups = aws athena list-work-groups --query "WorkGroups[?contains(Name, 'data-analytics-workgroup-$Environment')].Name" --output json --region $Region | ConvertFrom-Json
    if ($workgroups -and $workgroups.Count -gt 0) {
        Write-Host "The following Athena workgroups still exist:" -ForegroundColor Red
        foreach ($workgroup in $workgroups) {
            Write-Host "- $workgroup" -ForegroundColor Red
        }
    } else {
        Write-Host "✓ All Athena workgroups have been deleted" -ForegroundColor Green
    }
}

# Function to get stack outputs
function Get-StackOutputs {
    param (
        [string]$stackName
    )
    
    $outputs = @{}
    
    if (Test-StackExists -stackName $stackName) {
        $outputsJson = aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].Outputs" --output json --region $Region
        $outputsArray = $outputsJson | ConvertFrom-Json
        
        foreach ($output in $outputsArray) {
            $outputs[$output.OutputKey] = $output.OutputValue
        }
    }
    
    return $outputs
}

# Empty S3 bucket if requested
if ($EmptyS3Bucket) {
    $s3StackName = "$StackNamePrefix-s3"
    $bucketName = $null

    if (Test-StackExists -stackName $s3StackName) {
        $s3Outputs = Get-StackOutputs -stackName $s3StackName
        $bucketName = $s3Outputs["BucketName"]
        
        if ($bucketName) {
            Write-Host "Emptying S3 bucket '$bucketName' before deletion..." -ForegroundColor Cyan
            
            # Check if bucket exists
            try {
                $null = aws s3api head-bucket --bucket $bucketName --region $Region 2>$null
                
                # Empty the bucket
                Write-Host "Deleting all objects in bucket '$bucketName'..." -ForegroundColor Yellow
                aws s3 rm s3://$bucketName --recursive --region $Region
                
                # Clean up Athena query results
                Write-Host "Cleaning up Athena query results..." -ForegroundColor Yellow
                aws s3 rm s3://$bucketName/athena-results/ --recursive --region $Region 2>$null
                
                Write-Host "✓ S3 bucket emptied successfully" -ForegroundColor Green
            } catch {
                Write-Host "S3 bucket '$bucketName' does not exist or is not accessible. Skipping." -ForegroundColor Yellow
            }
        } else {
            Write-Host "Could not find BucketName output in S3 stack. Skipping bucket emptying." -ForegroundColor Yellow
        }
    } else {
        Write-Host "S3 stack '$s3StackName' does not exist. Skipping bucket emptying." -ForegroundColor Yellow
    }
}

# Show QuickSight cleanup instructions if requested
if ($ShowQuickSightInstructions) {
    Write-Host ""
    Write-Host "QuickSight Manual Cleanup Instructions:" -ForegroundColor Cyan
    Write-Host "1. Sign in to the QuickSight console: https://quicksight.aws.amazon.com/" -ForegroundColor White
    Write-Host "2. Delete analyses: Navigate to Analyses tab, click ellipsis (⋮) menu, select Delete" -ForegroundColor White
    Write-Host "3. Delete dashboards: Navigate to Dashboards tab, click ellipsis (⋮) menu, select Delete" -ForegroundColor White
    Write-Host "4. Delete datasets: Navigate to Datasets tab, click ellipsis (⋮) menu, select Delete" -ForegroundColor White
    Write-Host "5. Delete data sources: Navigate to Datasets > New dataset, click ellipsis (⋮) menu, select Delete data source" -ForegroundColor White
    Write-Host "6. Optional - Delete QuickSight account: Profile > Manage QuickSight > Account settings > Delete account" -ForegroundColor White
    Write-Host ""
}
