#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Teardown script for the Disaster Recovery POC.

.DESCRIPTION
    This script removes the CloudFormation stacks and associated resources for the Disaster Recovery POC.
    WARNING: This will permanently delete all backup data unless explicitly preserved.

.PARAMETER Environment
    The environment to teardown (dev, test, prod).

.PARAMETER Region
    The AWS region where resources are deployed.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER PreserveBucket
    Preserve the backup bucket and its contents (default: false).

.PARAMETER BackupBucketName
    The name of the backup bucket (required if PreserveBucket is true).

.EXAMPLE
    ./teardown.ps1 -Environment dev
    
.EXAMPLE
    ./teardown.ps1 -Environment prod -PreserveBucket $true -BackupBucketName my-backup-bucket -Force $true
#>

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [bool]$Force = $false,

    [Parameter(Mandatory=$false)]
    [bool]$PreserveBucket = $false,

    [Parameter(Mandatory=$false)]
    [string]$BackupBucketName = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Import common modules
$modulePath = Join-Path $PSScriptRoot "common"
if (Test-Path $modulePath) {
    Import-Module (Join-Path $modulePath "CloudFormation-Utils.psm1") -Force
    Import-Module (Join-Path $modulePath "S3-Utils.psm1") -Force
    Write-Host "Loaded common utility modules" -ForegroundColor Green
}

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

$region = $Region
$stackNamePrefix = "disaster-recovery"

# Function to check if stack exists
function Test-StackExists {
    param (
        [string]$stackName
    )
    
    try {
        aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].StackStatus" --output text --region $region 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

# Function to get stack status
function Get-StackStatus {
    param (
        [string]$stackName
    )
    
    try {
        $status = aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].StackStatus" --output text --region $region
        return $status
    }
    catch {
        return "NOT_FOUND"
    }
}

# Function to empty S3 bucket
function Clear-S3Bucket {
    param (
        [string]$bucketName
    )
    
    try {
        Write-Host "Emptying S3 bucket: $bucketName..."
        
        # Delete all object versions and delete markers
        aws s3api list-object-versions --bucket $bucketName --query "Versions[].{Key:Key,VersionId:VersionId}" --output text --region $region | ForEach-Object {
            if ($_ -ne "") {
                $parts = $_ -split "`t"
                if ($parts.Length -eq 2) {
                    aws s3api delete-object --bucket $bucketName --key $parts[0] --version-id $parts[1] --region $region
                }
            }
        }
        
        # Delete delete markers
        aws s3api list-object-versions --bucket $bucketName --query "DeleteMarkers[].{Key:Key,VersionId:VersionId}" --output text --region $region | ForEach-Object {
            if ($_ -ne "") {
                $parts = $_ -split "`t"
                if ($parts.Length -eq 2) {
                    aws s3api delete-object --bucket $bucketName --key $parts[0] --version-id $parts[1] --region $region
                }
            }
        }
        
        # Delete remaining objects
        aws s3 rm s3://$bucketName --recursive --region $region
        
        Write-Host "S3 bucket $bucketName emptied successfully." -ForegroundColor Green
    }
    catch {
        Write-Warning "Error emptying S3 bucket ${bucketName}: $_"
    }
}

# Function to delete CloudFormation stack
function Remove-CloudFormationStack {
    param (
        [string]$stackName
    )
    
    try {
        Write-Host "Deleting CloudFormation stack: $stackName..."
        aws cloudformation delete-stack --stack-name $stackName --region $region
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to initiate deletion of stack $stackName"
            return $false
        }
        
        Write-Host "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name $stackName --region $region
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Stack $stackName deleted successfully." -ForegroundColor Green
            return $true
        } else {
            Write-Error "Failed to delete stack $stackName. Please check the CloudFormation console for details."
            return $false
        }
    }
    catch {
        Write-Error "Error deleting stack ${stackName}: $_"
        return $false
    }
}

# Function to get bucket names from stack
function Get-BucketNamesFromStack {
    param (
        [string]$stackName
    )
    
    try {
        $buckets = @()
        
        # Get main backup bucket
        $backupBucket = aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" --output text --region $region
        if ($backupBucket -and $backupBucket -ne "None") {
            $buckets += $backupBucket
        }
        
        # Get access logs bucket
        $accessLogsBucket = aws cloudformation describe-stack-resources --stack-name $stackName --query "StackResources[?ResourceType=='AWS::S3::Bucket' && LogicalResourceId=='AccessLogsBucket'].PhysicalResourceId" --output text --region $region
        if ($accessLogsBucket -and $accessLogsBucket -ne "None") {
            $buckets += $accessLogsBucket
        }
        
        # Get inventory bucket
        $inventoryBucket = aws cloudformation describe-stack-resources --stack-name $stackName --query "StackResources[?ResourceType=='AWS::S3::Bucket' && LogicalResourceId=='BackupInventory'].PhysicalResourceId" --output text --region $region
        if ($inventoryBucket -and $inventoryBucket -ne "None") {
            $buckets += $inventoryBucket
        }
        
        # Get CloudFormation templates bucket (if it exists)
        if ($BackupBucketName) {
            $cfBucket = "$BackupBucketName-cf-templates"
            try {
                aws s3api head-bucket --bucket $cfBucket --region $region 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $buckets += $cfBucket
                }
            } catch {}
        }
        
        return $buckets
    }
    catch {
        Write-Warning "Error getting bucket names from stack: $_"
        return @()
    }
}

# Main teardown logic
try {
    Write-Host "Starting Disaster Recovery POC teardown..." -ForegroundColor Cyan
    Write-Host "Environment: $Environment"
    Write-Host "Region: $region"
    Write-Host "Preserve Backup Bucket: $PreserveBucket"
    Write-Host ""

    # Get stack name
    $mainStackName = "$stackNamePrefix-main-$Environment"
    
    # Check if main stack exists
    if (!(Test-StackExists -stackName $mainStackName)) {
        Write-Host "Main stack $mainStackName does not exist. Nothing to teardown." -ForegroundColor Yellow
        exit 0
    }
    
    # Get stack information
    $stackStatus = Get-StackStatus -stackName $mainStackName
    Write-Host "Current stack status: $stackStatus"
    
    # Get bucket names before stack deletion
    $buckets = Get-BucketNamesFromStack -stackName $mainStackName
    
    if ($buckets.Count -gt 0) {
        Write-Host "`nFound the following S3 buckets associated with this deployment:"
        $buckets | ForEach-Object { Write-Host "  - $_" }
    }
    
    # Confirmation prompt
    if (!$Force) {
        Write-Host "`nWARNING: This will permanently delete the following resources:" -ForegroundColor Red
        Write-Host "- CloudFormation stack: $mainStackName"
        Write-Host "- IAM user and access keys"
        Write-Host "- CloudWatch dashboards, alarms, and log groups"
        
        if (!$PreserveBucket -and $buckets.Count -gt 0) {
            Write-Host "- S3 buckets and ALL backup data:" -ForegroundColor Red
            $buckets | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        } elseif ($PreserveBucket) {
            Write-Host "- S3 support buckets (backup bucket will be preserved):" -ForegroundColor Yellow
            $buckets | Where-Object { $_ -notlike "*$BackupBucketName" -or $_ -like "*-cf-templates" -or $_ -like "*-access-logs" -or $_ -like "*-inventory" } | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        }
        
        $confirm = Read-Host "`nAre you sure you want to continue? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Host "Teardown cancelled by user." -ForegroundColor Yellow
            exit 0
        }
    }
    
    # Empty S3 buckets before stack deletion
    if ($buckets.Count -gt 0) {
        Write-Host "`nEmptying S3 buckets..."
        
        foreach ($bucket in $buckets) {
            # Skip main backup bucket if preserving
            if ($PreserveBucket -and $bucket -eq $BackupBucketName) {
                Write-Host "Preserving backup bucket: $bucket" -ForegroundColor Yellow
                continue
            }
            
            try {
                aws s3api head-bucket --bucket $bucket --region $region 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Clear-S3Bucket -bucketName $bucket
                }
            }
            catch {
                Write-Warning "Could not access bucket $bucket - it may have already been deleted"
            }
        }
    }
    
    # Delete the main stack
    Write-Host "`nDeleting CloudFormation stack..."
    $stackDeleteResult = Remove-CloudFormationStack -stackName $mainStackName
    
    if (-not $stackDeleteResult) {
        Write-Error "Failed to delete CloudFormation stack $mainStackName"
        exit 1
    }
    
    # Verify deletion
    if (!(Test-StackExists -stackName $mainStackName)) {
        Write-Host "`nTeardown completed successfully!" -ForegroundColor Green
        
        if ($PreserveBucket) {
            Write-Host "`nIMPORTANT: Your backup bucket '$BackupBucketName' has been preserved." -ForegroundColor Yellow
            Write-Host "You are still being charged for the stored data."
            Write-Host "To manually delete it later, run:"
            Write-Host "  aws s3 rb s3://$BackupBucketName --force --region $region"
        }
        
        Write-Host "`nAll infrastructure resources have been removed from your AWS account."
    } else {
        Write-Warning "Stack may not have been completely deleted. Check AWS console for details."
    }
    
} catch {
    Write-Error "Teardown failed: $_"
    Write-Host "Check CloudFormation console for detailed error information."
    exit 1
}