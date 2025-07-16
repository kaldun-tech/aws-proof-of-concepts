#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Teardown script for the Reliable Multi-Tier POC.

.DESCRIPTION
    This script deletes all CloudFormation stacks created by the deploy.ps1 script.
    It deletes the stacks in the reverse order of their creation to handle dependencies properly.

.PARAMETER Environment
    The environment name (dev, test, prod). Default is dev.

.PARAMETER StackNamePrefix
    The prefix used for all stack names. Default is WebApp1.

.PARAMETER Region
    The AWS region where the stacks are deployed. Default is us-east-1.

.PARAMETER Force
    If specified, will not prompt for confirmation before deleting stacks.

.PARAMETER Component
    The specific component to delete (vpc, webapp, all). Default is all.

.PARAMETER Profile
    The AWS profile to use for authentication.

.EXAMPLE
    ./teardown.ps1 -Environment dev -Force $false
    
.EXAMPLE
    ./teardown.ps1 -Environment prod -Component webapp -Profile my-profile
#>

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory=$false)]
    [string]$StackNamePrefix = "WebApp1",

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [bool]$Force = $false,

    [Parameter(Mandatory=$false)]
    [ValidateSet("vpc", "webapp", "all")]
    [string]$Component = "all",
    
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

# Define stack names
$webAppStackName = "$StackNamePrefix-WebApp"
$vpcStackName = "$StackNamePrefix-VPC"

if ($Component -eq "all" -or $Component -eq "webapp") {
    if (Test-StackExists -stackName $webAppStackName) {
        $stacksToDelete += $webAppStackName
        Write-Host "- $webAppStackName" -ForegroundColor Yellow
    }
}

if ($Component -eq "all" -or $Component -eq "vpc") {
    if (Test-StackExists -stackName $vpcStackName) {
        $stacksToDelete += $vpcStackName
        Write-Host "- $vpcStackName" -ForegroundColor Yellow
    }
}

# If no stacks found
if ($stacksToDelete.Count -eq 0) {
    Write-Host "No matching stacks found to delete." -ForegroundColor Green
    exit 0
}

# Dependency check for VPC-only deletion
if ($Component -eq "vpc" -and (Test-StackExists -stackName $webAppStackName)) {
    Write-Host "ERROR: Web Application stack still exists. VPC stack cannot be deleted while it has dependencies." -ForegroundColor Red
    Write-Host "Please delete the webapp component first:" -ForegroundColor Yellow
    Write-Host "  ./teardown.ps1 -Component webapp -Environment $Environment" -ForegroundColor Yellow
    exit 1
}

# Confirm deletion
if (-not (Confirm-Deletion -message "Are you sure you want to delete these stacks?")) {
    Write-Host "Teardown cancelled." -ForegroundColor Yellow
    exit 0
}

# Delete stacks in reverse order (to handle dependencies)
$success = $true

# Delete WebApp stack first (if included)
if ($Component -eq "all" -or $Component -eq "webapp") {
    if (Test-StackExists -stackName $webAppStackName) {
        $result = Remove-CloudFormationStack -stackName $webAppStackName -waitForCompletion $true
        if (-not $result) {
            $success = $false
            Write-Warning "Failed to delete stack $webAppStackName. Continuing with other stacks..."
        }
    }
}

# Delete VPC stack second (if included)
if ($Component -eq "all" -or $Component -eq "vpc") {
    if (Test-StackExists -stackName $vpcStackName) {
        $result = Remove-CloudFormationStack -stackName $vpcStackName -waitForCompletion $true
        if (-not $result) {
            $success = $false
            Write-Warning "Failed to delete stack $vpcStackName. Continuing with other stacks..."
        }
    }
}

# Final status message
if ($success) {
    Write-Host "All selected stacks have been deleted successfully." -ForegroundColor Green
} else {
    Write-Host "Some stacks could not be deleted. Please check the AWS CloudFormation console for details." -ForegroundColor Red
}