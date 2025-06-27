#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Comprehensive cleanup script for the Data Analytics POC.
.DESCRIPTION
    This script performs a complete cleanup of all resources created by the Data Analytics POC,
    including CloudFormation stacks, S3 bucket contents, and verification of resource deletion.
    It also provides guidance for manual cleanup steps that cannot be automated.
.PARAMETER Environment
    The environment (dev, test, prod) to clean up.
.PARAMETER Region
    The AWS region where resources are deployed.
.PARAMETER StackNamePrefix
    The prefix used for CloudFormation stack names.
.PARAMETER Force
    Skip confirmation prompts.
.EXAMPLE
    ./cleanup.ps1 -Environment dev -Force $true
    Performs a complete cleanup of the dev environment without confirmation prompts.
#>

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [string]$StackNamePrefix = "poc2-data-analytics",

    [Parameter(Mandatory=$false)]
    [bool]$Force = $false
)

# Function to check if a stack exists
function Test-StackExists {
    param (
        [string]$stackName
    )
    
    try {
        $null = aws cloudformation describe-stacks --stack-name $stackName --region $Region 2>$null
        return $true
    } catch {
        return $false
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

# ASCII art banner
function Show-Banner {
    Write-Host ""
    Write-Host "  _____                      _      _         _____                                " -ForegroundColor Red
    Write-Host " / ____|                    | |    | |       / ____|                               " -ForegroundColor Red
    Write-Host "| |     ___  _ __ ___  _ __ | | ___| |_ ___ | |     ___  _ __ ___  _ __  _   _ _ __  " -ForegroundColor Red
    Write-Host "| |    / _ \| '_ ` _ \| '_ \| |/ _ \ __/ _ \| |    / _ \| '_ ` _ \| '_ \| | | | '_ \ " -ForegroundColor Red
    Write-Host "| |___| (_) | | | | | | |_) | |  __/ ||  __/| |___| (_) | | | | | | |_) | |_| | |_) |" -ForegroundColor Red
    Write-Host " \_____\___/|_| |_| |_| .__/|_|\___|\__\___| \_____\___/|_| |_| |_| .__/ \__,_| .__/ " -ForegroundColor Red
    Write-Host "                      | |                                         | |         | |    " -ForegroundColor Red
    Write-Host "                      |_|                                         |_|         |_|    " -ForegroundColor Red
    Write-Host " Data Analytics POC Resource Cleanup                                                " -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

# Main script execution starts here
Show-Banner

# Confirm cleanup
if (-not $Force) {
    Write-Host "WARNING: This script will delete ALL resources created by the Data Analytics POC." -ForegroundColor Red
    Write-Host "This includes CloudFormation stacks, S3 bucket contents, and other resources." -ForegroundColor Red
    Write-Host "Environment: $Environment" -ForegroundColor Yellow
    Write-Host "Region: $Region" -ForegroundColor Yellow
    Write-Host "Stack Name Prefix: $StackNamePrefix" -ForegroundColor Yellow
    Write-Host ""
    $confirmation = Read-Host "Are you sure you want to proceed? (y/n)"
    if ($confirmation -ne "y") {
        Write-Host "Cleanup aborted." -ForegroundColor Yellow
        exit 0
    }
}

# Step 1: Get S3 bucket name and empty it
$s3StackName = "$StackNamePrefix-s3"
$bucketName = $null

if (Test-StackExists -stackName $s3StackName) {
    $s3Outputs = Get-StackOutputs -stackName $s3StackName
    $bucketName = $s3Outputs["BucketName"]
    
    if ($bucketName) {
        Write-Host "Step 1: Emptying S3 bucket '$bucketName'..." -ForegroundColor Cyan
        
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

# Step 2: Run the teardown script to delete CloudFormation stacks
Write-Host "Step 2: Running teardown script to delete CloudFormation stacks..." -ForegroundColor Cyan
$teardownScript = Join-Path $PSScriptRoot "teardown.ps1"
if (Test-Path $teardownScript) {
    & $teardownScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Force $true -Component "all"
} else {
    Write-Host "Teardown script not found at: $teardownScript" -ForegroundColor Red
    Write-Host "Please run the teardown script manually:" -ForegroundColor Yellow
    Write-Host "./teardown.ps1 -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Force `$true -Component all" -ForegroundColor Yellow
}

# Step 3: Verify resource deletion
Write-Host "Step 3: Verifying resource deletion..." -ForegroundColor Cyan

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

# Check S3 buckets
if ($bucketName) {
    Write-Host "Checking if S3 bucket still exists..." -ForegroundColor Yellow
    try {
        $null = aws s3api head-bucket --bucket $bucketName --region $Region 2>$null
        Write-Host "S3 bucket '$bucketName' still exists. You may need to delete it manually." -ForegroundColor Red
    } catch {
        Write-Host "✓ S3 bucket has been deleted" -ForegroundColor Green
    }
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

# Step 4: Manual cleanup instructions
Write-Host "Step 4: Manual cleanup steps" -ForegroundColor Cyan
Write-Host "Some resources require manual cleanup through the AWS Console:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. QuickSight Resources:" -ForegroundColor White
Write-Host "   - Sign in to the QuickSight console: https://quicksight.aws.amazon.com/" -ForegroundColor White
Write-Host "   - Delete any analyses, dashboards, and datasets related to this POC" -ForegroundColor White
Write-Host "   - If desired, delete your QuickSight account from Account settings" -ForegroundColor White
Write-Host ""
Write-Host "2. IAM Roles and Policies:" -ForegroundColor White
Write-Host "   - Check for any remaining IAM roles or policies with names containing:" -ForegroundColor White
Write-Host "     * 'poc2-data-analytics'" -ForegroundColor White
Write-Host "     * 'APIGateway-Firehose'" -ForegroundColor White
Write-Host "     * 'API-Firehose'" -ForegroundColor White
Write-Host ""
Write-Host "3. CloudWatch Logs:" -ForegroundColor White
Write-Host "   - Check for any remaining log groups with names containing:" -ForegroundColor White
Write-Host "     * '/aws/lambda/transform-data-$Environment'" -ForegroundColor White
Write-Host "     * '/aws/kinesisfirehose/'" -ForegroundColor White
Write-Host ""

Write-Host "Cleanup process completed!" -ForegroundColor Green
Write-Host "Please verify in the AWS Console that all resources have been properly deleted." -ForegroundColor Yellow
