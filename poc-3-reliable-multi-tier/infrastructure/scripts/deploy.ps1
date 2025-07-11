# deploy.ps1
# Script to deploy the reliable multi-tier infrastructure CloudFormation stacks

<#
.SYNOPSIS
    Deploys the reliable multi-tier infrastructure CloudFormation stacks.

.DESCRIPTION
    This script deploys the VPC and static web application CloudFormation stacks
    for the reliable multi-tier infrastructure proof of concept.

.PARAMETER Environment
    The deployment environment (dev, test, prod).

.PARAMETER EmailAddress
    Email address for notifications.

.PARAMETER S3BucketName
    S3 bucket name for CloudFormation templates.

.PARAMETER Region
    AWS region to deploy to. Default is us-east-1.

.PARAMETER StackNamePrefix
    Prefix for CloudFormation stack names. Default is WebApp1.

.PARAMETER Component
    Component to deploy (vpc, webapp, all). Default is all.

.PARAMETER RunTests
    Whether to run tests after deployment. Default is $true.

.EXAMPLE
    .\deploy.ps1 -Environment dev -EmailAddress user@example.com -S3BucketName my-bucket
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [string]$EmailAddress,

    [Parameter(Mandatory=$true)]
    [string]$S3BucketName,

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [string]$StackNamePrefix = "WebApp1",

    [Parameter(Mandatory=$false)]
    [ValidateSet("vpc", "webapp", "all")]
    [string]$Component = "all",

    [Parameter(Mandatory=$false)]
    [bool]$RunTests = $true
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
        $stack = Get-CFNStack -StackName $StackName -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

# Function to wait for stack operation to complete
function Wait-StackOperation {
    param (
        [string]$StackName,
        [string]$Operation
    )
    
    Write-Host "Waiting for $Operation operation to complete on stack $StackName..."
    
    do {
        $stack = Get-CFNStack -StackName $StackName
        $status = $stack.StackStatus
        
        if ($status -like "*COMPLETE") {
            Write-Host "Stack $StackName $Operation completed successfully with status: $status"
            return $true
        } elseif ($status -like "*FAILED" -or $status -like "*ROLLBACK*") {
            Write-Host "Stack $StackName $Operation failed with status: $status"
            return $false
        }
        
        Write-Host "Current status: $status - waiting 10 seconds..."
        Start-Sleep -Seconds 10
    } while ($true)
}

# Function to upload templates to S3
function Upload-TemplatesToS3 {
    param (
        [string]$BucketName
    )
    
    Write-Host "Uploading CloudFormation templates to S3 bucket: $BucketName"
    
    # Check if bucket exists, create if not
    try {
        $bucketExists = Get-S3Bucket -BucketName $BucketName -ErrorAction SilentlyContinue
        if (-not $bucketExists) {
            Write-Host "Creating S3 bucket: $BucketName"
            New-S3Bucket -BucketName $BucketName -Region $Region
        }
    } catch {
        Write-Host "Creating S3 bucket: $BucketName"
        New-S3Bucket -BucketName $BucketName -Region $Region
    }
    
    # Upload templates
    $templateDir = Join-Path -Path $PSScriptRoot -ChildPath "..\cloudformation"
    $templates = Get-ChildItem -Path $templateDir -Filter "*.yaml"
    
    foreach ($template in $templates) {
        Write-Host "Uploading template: $($template.Name)"
        Write-S3Object -BucketName $BucketName -File $template.FullName -Key "templates/$($template.Name)" -PublicReadOnly
    }
    
    Write-Host "Templates uploaded successfully."
}

# Function to deploy VPC stack
function New-VPCStack {
    $vpcStackName = "$StackNamePrefix-VPC"
    $templateUrl = "https://$S3BucketName.s3.amazonaws.com/templates/vpc.yaml"
    
    Write-Host "Deploying VPC stack: $vpcStackName"
    
    $vpcParams = @(
        @{ParameterKey="NamingPrefix"; ParameterValue=$StackNamePrefix}
    )
    
    $stackExists = Test-StackExists -StackName $vpcStackName
    
    if ($stackExists) {
        Write-Host "Updating existing VPC stack: $vpcStackName"
        $changeSetName = "$vpcStackName-changeset-$(Get-Date -Format 'yyyyMMddHHmmss')"
        
        # Create change set
        New-CFNChangeSet -StackName $vpcStackName -ChangeSetName $changeSetName `
            -TemplateURL $templateUrl -Parameter $vpcParams -Capability CAPABILITY_NAMED_IAM
        
        # Wait for change set creation
        $changeSetStatus = ""
        do {
            $changeSetInfo = Get-CFNChangeSet -StackName $vpcStackName -ChangeSetName $changeSetName
            $changeSetStatus = $changeSetInfo.Status
            
            if ($changeSetStatus -eq "CREATE_COMPLETE") {
                # Execute change set
                Start-CFNChangeSet -StackName $vpcStackName -ChangeSetName $changeSetName
                Wait-StackOperation -StackName $vpcStackName -Operation "update"
                break
            } elseif ($changeSetStatus -eq "FAILED") {
                Write-Host "No changes to apply to VPC stack or change set creation failed."
                break
            }
            
            Write-Host "Waiting for change set creation... Current status: $changeSetStatus"
            Start-Sleep -Seconds 5
        } while ($true)
    } else {
        Write-Host "Creating new VPC stack: $vpcStackName"
        New-CFNStack -StackName $vpcStackName -TemplateURL $templateUrl -Parameter $vpcParams -Capability CAPABILITY_NAMED_IAM
        Wait-StackOperation -StackName $vpcStackName -Operation "creation"
    }
}

# Function to deploy Web Application stack
function New-WebAppStack {
    $webAppStackName = "$StackNamePrefix-WebApp"
    $templateUrl = "https://$S3BucketName.s3.amazonaws.com/templates/staticwebapp.yaml"
    
    Write-Host "Deploying Web Application stack: $webAppStackName"
    
    $webAppParams = @(
        @{ParameterKey="NamingPrefix"; ParameterValue=$StackNamePrefix},
        @{ParameterKey="VPCImportName"; ParameterValue="$StackNamePrefix-VPC"}
    )
    
    $stackExists = Test-StackExists -StackName $webAppStackName
    
    if ($stackExists) {
        Write-Host "Updating existing Web Application stack: $webAppStackName"
        $changeSetName = "$webAppStackName-changeset-$(Get-Date -Format 'yyyyMMddHHmmss')"
        
        # Create change set
        New-CFNChangeSet -StackName $webAppStackName -ChangeSetName $changeSetName `
            -TemplateURL $templateUrl -Parameter $webAppParams -Capability CAPABILITY_NAMED_IAM
        
        # Wait for change set creation
        $changeSetStatus = ""
        do {
            $changeSetInfo = Get-CFNChangeSet -StackName $webAppStackName -ChangeSetName $changeSetName
            $changeSetStatus = $changeSetInfo.Status
            
            if ($changeSetStatus -eq "CREATE_COMPLETE") {
                # Execute change set
                Start-CFNChangeSet -StackName $webAppStackName -ChangeSetName $changeSetName
                Wait-StackOperation -StackName $webAppStackName -Operation "update"
                break
            } elseif ($changeSetStatus -eq "FAILED") {
                Write-Host "No changes to apply to Web Application stack or change set creation failed."
                break
            }
            
            Write-Host "Waiting for change set creation... Current status: $changeSetStatus"
            Start-Sleep -Seconds 5
        } while ($true)
    } else {
        Write-Host "Creating new Web Application stack: $webAppStackName"
        New-CFNStack -StackName $webAppStackName -TemplateURL $templateUrl -Parameter $webAppParams -Capability CAPABILITY_NAMED_IAM
        Wait-StackOperation -StackName $webAppStackName -Operation "creation"
    }
}

# Function to run tests
function Invoke-Tests {
    Write-Host "Running tests for the deployed infrastructure..."
    
    # Get the WebsiteURL output from the WebApp stack
    $webAppStackName = "$StackNamePrefix-WebApp"
    $stack = Get-CFNStack -StackName $webAppStackName
    $websiteUrl = ($stack.Outputs | Where-Object { $_.OutputKey -eq "WebsiteURL" }).OutputValue
    
    if ($websiteUrl) {
        Write-Host "Testing website availability at: $websiteUrl"
        
        try {
            $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing
            $statusCode = $response.StatusCode
            
            if ($statusCode -eq 200) {
                Write-Host "Website is accessible. Status code: $statusCode" -ForegroundColor Green
            } else {
                Write-Host "Website returned non-200 status code: $statusCode" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Failed to access website: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "WebsiteURL output not found in stack outputs." -ForegroundColor Yellow
    }
    
    Write-Host "Tests completed."
}

# Main deployment logic
try {
    Write-Host "Starting deployment of reliable multi-tier infrastructure..."
    Write-Host "Environment: $Environment"
    Write-Host "Region: $Region"
    Write-Host "Stack Name Prefix: $StackNamePrefix"
    Write-Host "Component: $Component"
    
    # Upload templates to S3
    Upload-TemplatesToS3 -BucketName $S3BucketName
    
    # Deploy VPC stack if requested
    if ($Component -eq "vpc" -or $Component -eq "all") {
        New-VPCStack
    }
    
    # Deploy Web Application stack if requested
    if ($Component -eq "webapp" -or $Component -eq "all") {
        # Check if VPC stack exists before deploying web app
        $vpcStackName = "$StackNamePrefix-VPC"
        $vpcStackExists = Test-StackExists -StackName $vpcStackName
        
        if (-not $vpcStackExists) {
            Write-Error "VPC stack does not exist. Please deploy the VPC stack first."
            exit 1
        }
        
        New-WebAppStack
    }
    
    # Run tests if requested
    if ($RunTests) {
        Invoke-Tests
    }
    
    Write-Host "Deployment completed successfully." -ForegroundColor Green
} catch {
    Write-Host "Deployment failed: $_" -ForegroundColor Red
    exit 1
}
