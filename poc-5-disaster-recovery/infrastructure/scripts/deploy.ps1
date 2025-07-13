#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deployment script for the Disaster Recovery POC.

.DESCRIPTION
    This script deploys the CloudFormation templates for the Disaster Recovery POC.
    It creates S3 storage, IAM users, and monitoring infrastructure for personal file backups.

.PARAMETER Environment
    The environment to deploy to (dev, test, prod).

.PARAMETER BackupBucketName
    The name of the S3 bucket for backups (must be globally unique).

.PARAMETER UserEmail
    The email address for backup notifications.

.PARAMETER Region
    The AWS region to deploy to.

.PARAMETER RetentionYears
    Number of years to retain backups.

.PARAMETER CostThresholdUSD
    Monthly cost threshold for alerts (USD).

.PARAMETER Component
    The specific component to deploy (all, iam, s3, cloudwatch).

.EXAMPLE
    ./deploy.ps1 -Environment dev -BackupBucketName my-backup-bucket-unique-name -UserEmail user@example.com
#>

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]*[a-z0-9]$')]
    [string]$BackupBucketName,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')]
    [string]$UserEmail,

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 10)]
    [int]$RetentionYears = 7,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 1000)]
    [int]$CostThresholdUSD = 50,

    [Parameter(Mandatory=$false)]
    [ValidateSet("all", "iam", "s3", "cloudwatch")]
    [string]$Component = "all"
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Set the AWS region
$region = $Region
$stackNamePrefix = "disaster-recovery"
$templateDir = Join-Path $PSScriptRoot ".." "cloudformation"

# Function to check if S3 bucket exists for CloudFormation templates
function Test-S3Bucket {
    param (
        [string]$bucketName
    )

    try {
        Write-Host "Checking if S3 bucket $bucketName exists..."
        aws s3api head-bucket --bucket $bucketName --region $region 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "S3 bucket $bucketName exists." -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Host "S3 bucket $bucketName does not exist." -ForegroundColor Yellow
        return $false
    }
    return $false
}

# Function to create S3 bucket for CloudFormation templates
function New-S3Bucket {
    param (
        [string]$bucketName
    )

    try {
        Write-Host "Creating S3 bucket $bucketName for CloudFormation templates..."
        if ($region -eq "us-east-1") {
            aws s3 mb s3://$bucketName --region $region
        } else {
            aws s3api create-bucket --bucket $bucketName --region $region --create-bucket-configuration LocationConstraint=$region
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create S3 bucket"
        }
        
        Write-Host "S3 bucket $bucketName created successfully." -ForegroundColor Green
    }
    catch {
        Write-Error "Error creating S3 bucket: $_"
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
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to package CloudFormation template"
        }
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
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to deploy CloudFormation stack"
        }
        
        Write-Host "Stack $stackName deployed successfully." -ForegroundColor Green
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
            Write-Host "Stack $stackName deployment failed with status: $status" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Error "Error validating stack deployment: $_"
        return $false
    }
}

# Function to get stack outputs
function Get-StackOutput {
    param (
        [string]$stackName,
        [string]$outputKey
    )
    
    try {
        $output = aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].Outputs[?OutputKey=='$outputKey'].OutputValue" --output text --region $region
        return $output
    }
    catch {
        Write-Warning "Could not get output $outputKey from stack $stackName"
        return $null
    }
}

# Main deployment logic
try {
    Write-Host "Starting Disaster Recovery POC deployment..." -ForegroundColor Cyan
    Write-Host "Environment: $Environment"
    Write-Host "Backup Bucket: $BackupBucketName"
    Write-Host "Region: $region"
    Write-Host "Component: $Component"
    Write-Host "Retention Years: $RetentionYears"
    Write-Host ""

    # S3 bucket for CloudFormation templates
    $cfTemplatesBucket = "$BackupBucketName-cf-templates"
    
    if (!(Test-S3Bucket -bucketName $cfTemplatesBucket)) {
        New-S3Bucket -bucketName $cfTemplatesBucket
    }

    # Package main template
    $mainTemplateFile = Join-Path $templateDir "main.yaml"
    $packagedMainTemplate = Join-Path $templateDir "main-packaged.yaml"
    
    ConvertTo-CloudFormationPackage -templateFile $mainTemplateFile -s3Bucket $cfTemplatesBucket -outputFile $packagedMainTemplate

    # Deploy components based on parameter
    $stackName = "$stackNamePrefix-main-$Environment"
    
    if ($Component -eq "all") {
        Write-Host "Deploying complete disaster recovery infrastructure..."
        
        $parameters = @{
            Environment = $Environment
            BackupBucketName = $BackupBucketName
            UserEmail = $UserEmail
            RetentionYears = $RetentionYears
            CostThresholdUSD = $CostThresholdUSD
        }
        
        New-CloudFormationStack -stackName $stackName -templateFile $packagedMainTemplate -parameters $parameters -capabilities $true
        
        if (Test-StackDeployment -stackName $stackName) {
            Write-Host "`nDeployment completed successfully!" -ForegroundColor Green
            
            # Get important outputs
            $bucketName = Get-StackOutput -stackName $stackName -outputKey "BackupBucketName"
            $accessKeyId = Get-StackOutput -stackName $stackName -outputKey "AccessKeyId"
            $secretAccessKey = Get-StackOutput -stackName $stackName -outputKey "SecretAccessKey"
            $dashboardURL = Get-StackOutput -stackName $stackName -outputKey "DashboardURL"
            
            Write-Host "`n=== DEPLOYMENT SUMMARY ===" -ForegroundColor Cyan
            Write-Host "Backup Bucket: $bucketName"
            Write-Host "Dashboard URL: $dashboardURL"
            Write-Host ""
            Write-Host "=== AWS CREDENTIALS ===" -ForegroundColor Yellow
            Write-Host "IMPORTANT: Store these credentials securely!"
            Write-Host "Access Key ID: $accessKeyId"
            Write-Host "Secret Access Key: $secretAccessKey"
            Write-Host ""
            Write-Host "=== NEXT STEPS ===" -ForegroundColor Cyan
            Write-Host "1. Configure AWS CLI profile:"
            Write-Host "   aws configure --profile disaster-recovery"
            Write-Host "2. Copy backup configuration:"
            Write-Host "   cp examples/backup-config.json backup-config.json"
            Write-Host "3. Edit backup-config.json with your file paths"
            Write-Host "4. Run initial backup:"
            Write-Host "   ./infrastructure/scripts/backup.ps1 -ConfigFile backup-config.json"
        }
    } else {
        Write-Host "Individual component deployment not implemented yet. Please use 'all' for now."
        exit 1
    }

} catch {
    Write-Error "Deployment failed: $_"
    Write-Host "Check CloudFormation console for detailed error information."
    exit 1
}