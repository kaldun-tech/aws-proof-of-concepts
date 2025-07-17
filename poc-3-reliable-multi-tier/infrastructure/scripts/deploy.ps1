#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deployment script for the Reliable Multi-Tier POC.

.DESCRIPTION
    This script deploys the VPC and static web application CloudFormation stacks
    for the reliable multi-tier infrastructure proof of concept using AWS CLI.

.PARAMETER Environment
    The deployment environment (dev, test, prod).

.PARAMETER EmailAddress
    Email address for notifications (currently unused but kept for future expansion).

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

.PARAMETER Profile
    The AWS CLI profile to use for authentication. Optional - uses default profile if not specified.

.EXAMPLE
    .\deploy.ps1 -Environment dev -S3BucketName my-bucket
    
.EXAMPLE
    .\deploy.ps1 -Environment dev -S3BucketName my-bucket -Profile my-sso-profile
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment,

    [Parameter(Mandatory=$false)]
    [string]$EmailAddress = "",

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
    [bool]$RunTests = $true,

    [Parameter(Mandatory=$false)]
    [string]$Profile = ""
)

# Set error action preference
$ErrorActionPreference = "Stop"

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
        [string]$StackName
    )
    
    try {
        aws cloudformation describe-stacks --stack-name $StackName --region $Region 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

# Function to create or update CloudFormation stack
function New-CloudFormationStack {
    param (
        [string]$stackName,
        [string]$templateFile,
        [hashtable]$parameters = @{},
        [bool]$capabilities = $false
    )

    Write-Host "Processing CloudFormation stack: $stackName"

    # Build parameter overrides
    $parameterOverrides = @()
    foreach ($param in $parameters.GetEnumerator()) {
        $parameterOverrides += "$($param.Key)=$($param.Value)"
    }

    # Build the command
    $deployCmd = "aws cloudformation deploy --template-file `"$templateFile`" --stack-name $stackName --region $Region"
    
    if ($parameterOverrides.Count -gt 0) {
        $deployCmd += " --parameter-overrides " + ($parameterOverrides -join " ")
    }
    
    if ($capabilities) {
        $deployCmd += " --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND"
    }

    Write-Host "Executing: $deployCmd"
    
    try {
        Invoke-Expression $deployCmd
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Stack $stackName deployed successfully." -ForegroundColor Green
            return $true
        } else {
            Write-Error "Stack $stackName deployment failed."
            return $false
        }
    }
    catch {
        Write-Error "Error deploying stack ${stackName}: $_"
        return $false
    }
}

# Function to create S3 bucket if it doesn't exist
function New-S3Bucket {
    param (
        [string]$bucketName
    )
    
    Write-Host "Checking if S3 bucket $bucketName exists..."
    
    aws s3api head-bucket --bucket $bucketName --region $Region 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "S3 bucket $bucketName already exists."
    } else {
        Write-Host "Creating S3 bucket $bucketName..."
        aws s3 mb s3://$bucketName --region $Region
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create S3 bucket $bucketName"
            exit 1
        }
        Write-Host "S3 bucket $bucketName created successfully."
    }
}

# Function to upload templates to S3
function ConvertTo-CloudFormationPackage {
    param (
        [string]$templateDir,
        [string]$bucketName
    )
    
    Write-Host "Uploading CloudFormation templates to S3..."
    
    $templates = Get-ChildItem -Path $templateDir -Filter "*.yaml"
    
    foreach ($template in $templates) {
        Write-Host "Uploading $($template.Name)..."
        aws s3 cp $template.FullName s3://$bucketName/templates/$($template.Name) --region $Region
    }
    
    Write-Host "Templates uploaded successfully."
}

# Main deployment logic
Write-Host "Starting Reliable Multi-Tier Infrastructure deployment..."
Write-Host "Environment: $Environment"
Write-Host "Region: $Region"
Write-Host "Stack Prefix: $StackNamePrefix"
Write-Host "Component: $Component"

# Create S3 bucket for templates
New-S3Bucket -bucketName $S3BucketName

# Upload templates
$templateDir = Join-Path $PSScriptRoot "..\cloudformation"
ConvertTo-CloudFormationPackage -templateDir $templateDir -bucketName $S3BucketName

# Deploy VPC stack
if ($Component -eq "all" -or $Component -eq "vpc") {
    $vpcStackName = "$StackNamePrefix-VPC"
    $vpcTemplateFile = Join-Path $templateDir "vpc-alb-app-db.yaml"
    $vpcParameters = @{
        "NamingPrefix" = $StackNamePrefix
    }
    
    $result = New-CloudFormationStack -stackName $vpcStackName -templateFile $vpcTemplateFile -parameters $vpcParameters -capabilities $true
    if (-not $result) {
        Write-Error "VPC stack deployment failed. Stopping deployment."
        exit 1
    }
}

# Deploy Web Application stack
if ($Component -eq "all" -or $Component -eq "webapp") {
    $webAppStackName = "$StackNamePrefix-WebApp"
    $webAppTemplateFile = Join-Path $templateDir "staticwebapp.yaml"
    $webAppParameters = @{
        "NamingPrefix" = $StackNamePrefix
        "VPCImportName" = "$StackNamePrefix-VPC"
    }
    
    $result = New-CloudFormationStack -stackName $webAppStackName -templateFile $webAppTemplateFile -parameters $webAppParameters -capabilities $true
    if (-not $result) {
        Write-Error "Web Application stack deployment failed. Stopping deployment."
        exit 1
    }
}

Write-Host "Deployment completed successfully!" -ForegroundColor Green

# Run tests if requested
if ($RunTests) {
    Write-Host "Running basic infrastructure tests..."
    
    # Test VPC stack
    if ($Component -eq "all" -or $Component -eq "vpc") {
        $vpcStackName = "$StackNamePrefix-VPC"
        if (Test-StackExists -StackName $vpcStackName) {
            Write-Host "✓ VPC stack $vpcStackName exists and is deployed" -ForegroundColor Green
        } else {
            Write-Host "✗ VPC stack $vpcStackName not found" -ForegroundColor Red
        }
    }
    
    # Test Web App stack
    if ($Component -eq "all" -or $Component -eq "webapp") {
        $webAppStackName = "$StackNamePrefix-WebApp"
        if (Test-StackExists -StackName $webAppStackName) {
            Write-Host "✓ Web App stack $webAppStackName exists and is deployed" -ForegroundColor Green
            
            # Get the Application Load Balancer URL
            try {
                $albUrl = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='ApplicationURL'].OutputValue" --output text --region $Region
                if ($albUrl -and $albUrl -ne "None") {
                    Write-Host "✓ Application URL: $albUrl" -ForegroundColor Green
                }
            } catch {
                Write-Host "Could not retrieve Application URL" -ForegroundColor Yellow
            }
        } else {
            Write-Host "✗ Web App stack $webAppStackName not found" -ForegroundColor Red
        }
    }
    
    Write-Host "Infrastructure testing completed"
}

Write-Host "POC3 Reliable Multi-Tier deployment complete!"