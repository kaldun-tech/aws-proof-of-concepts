# teardown.ps1
# Script to tear down the reliable multi-tier infrastructure CloudFormation stacks

<#
.SYNOPSIS
    Tears down the reliable multi-tier infrastructure CloudFormation stacks.

.DESCRIPTION
    This script deletes the CloudFormation stacks for the reliable multi-tier infrastructure
    proof of concept in the correct order to respect dependencies.

.PARAMETER Environment
    The deployment environment (dev, test, prod). Default is dev.

.PARAMETER StackNamePrefix
    Prefix for CloudFormation stack names. Default is WebApp1.

.PARAMETER Region
    AWS region where stacks are deployed. Default is us-east-1.

.PARAMETER Force
    Skip confirmation prompt. Default is $false.

.PARAMETER Component
    Component to tear down (vpc, webapp, all). Default is all.

.EXAMPLE
    .\teardown.ps1 -Environment dev -Force $false
#>

param(
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
    [string]$Component = "all"
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Import AWS PowerShell module if available
if (Get-Module -ListAvailable -Name AWSPowerShell) {
    Import-Module AWSPowerShell
} elseif (Get-Module -ListAvailable -Name AWSPowerShell.NetCore) {
    Import-Module AWSPowerShell.NetCore
} else {
    Write-Error "AWS PowerShell module not found. Please install the AWS Tools for PowerShell."
    exit 1
}

# Set AWS region
Set-DefaultAWSRegion -Region $Region

# Function to check if a stack exists
function Test-StackExists {
    param (
        [string]$StackName
    )
    
    try {
        Get-CFNStack -StackName $StackName -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

# Function to wait for stack deletion to complete
function Wait-StackDeletion {
    param (
        [string]$StackName
    )
    
    Write-Host "Waiting for deletion of stack $StackName to complete..."
    
    do {
        try {
            $stack = Get-CFNStack -StackName $StackName -ErrorAction SilentlyContinue
            $status = $stack.StackStatus
            
            if ($status -like "*DELETE_COMPLETE") {
                Write-Host "Stack $StackName deleted successfully."
                return $true
            } elseif ($status -like "*DELETE_FAILED") {
                Write-Host "Stack $StackName deletion failed with status: $status"
                return $false
            }
            
            Write-Host "Current status: $status - waiting 10 seconds..."
            Start-Sleep -Seconds 10
        } catch {
            # Stack might not exist anymore, which is good
            Write-Host "Stack $StackName deleted successfully."
            return $true
        }
    } while ($true)
}

# Function to delete a stack
function Remove-CloudFormationStack {
    param (
        [string]$StackName
    )
    
    $stackExists = Test-StackExists -StackName $StackName
    
    if ($stackExists) {
        Write-Host "Deleting stack: $StackName"
        Remove-CFNStack -StackName $StackName -Force
        Wait-StackDeletion -StackName $StackName
    } else {
        Write-Host "Stack $StackName does not exist. Skipping deletion."
    }
}

# Main teardown logic
try {
    Write-Host "Starting teardown of reliable multi-tier infrastructure..."
    Write-Host "Environment: $Environment"
    Write-Host "Region: $Region"
    Write-Host "Stack Name Prefix: $StackNamePrefix"
    Write-Host "Component: $Component"
    
    # Confirm teardown unless Force is true
    if (-not $Force) {
        $confirmation = Read-Host "Are you sure you want to tear down the infrastructure? This action cannot be undone. (y/n)"
        if ($confirmation -ne "y") {
            Write-Host "Teardown cancelled."
            exit 0
        }
    }
    
    # Define stack names
    $webAppStackName = "$StackNamePrefix-WebApp"
    $vpcStackName = "$StackNamePrefix-VPC"
    
    # Delete Web Application stack if requested
    if ($Component -eq "webapp" -or $Component -eq "all") {
        Remove-CloudFormationStack -StackName $webAppStackName
    }
    
    # Delete VPC stack if requested and after web app stack is deleted
    if ($Component -eq "vpc" -or $Component -eq "all") {
        # Check if web app stack still exists
        if ($Component -eq "vpc" -and (Test-StackExists -StackName $webAppStackName)) {
            Write-Warning "Web Application stack still exists. Please delete it first before deleting the VPC stack."
            Write-Warning "Run: .\teardown.ps1 -Component webapp"
            exit 1
        }
        
        Remove-CloudFormationStack -StackName $vpcStackName
    }
    
    Write-Host "Teardown completed successfully." -ForegroundColor Green
} catch {
    Write-Host "Teardown failed: $_" -ForegroundColor Red
    exit 1
}

# Function to clean up S3 bucket (optional)
function Remove-S3Bucket {
    param (
        [string]$BucketName
    )
    
    Write-Host "Do you want to delete the S3 bucket containing CloudFormation templates? (y/n)"
    $confirmation = Read-Host
    
    if ($confirmation -eq "y") {
        Write-Host "Emptying and deleting S3 bucket: $BucketName"
        
        # Empty bucket first
        $objects = Get-S3Object -BucketName $BucketName
        
        if ($objects) {
            foreach ($object in $objects) {
                Remove-S3Object -BucketName $BucketName -Key $object.Key -Force
            }
        }
        
        # Delete bucket
        Remove-S3Bucket -BucketName $BucketName -Force
        
        Write-Host "S3 bucket deleted successfully."
    } else {
        Write-Host "S3 bucket not deleted."
    }
}
