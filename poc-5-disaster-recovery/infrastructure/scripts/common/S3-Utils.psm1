#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Common S3 utilities for disaster recovery POC scripts.

.DESCRIPTION
    This module provides reusable functions for S3 operations
    including bucket management, packaging, and cleanup.
#>

# Function to test if S3 bucket exists
function Test-S3Bucket {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$BucketName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )

    try {
        Write-Verbose "Checking if S3 bucket $BucketName exists..."
        aws s3api head-bucket --bucket $BucketName --region $Region 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Verbose "S3 bucket $BucketName exists."
            return $true
        } else {
            Write-Verbose "S3 bucket $BucketName does not exist."
            return $false
        }
    }
    catch {
        Write-Verbose "S3 bucket $BucketName does not exist or is not accessible."
        return $false
    }
}

# Function to create S3 bucket
function New-S3Bucket {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$BucketName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )

    try {
        Write-Host "Creating S3 bucket $BucketName..." -ForegroundColor Cyan
        
        if ($Region -eq "us-east-1") {
            aws s3 mb s3://$BucketName --region $Region
        } else {
            aws s3api create-bucket --bucket $BucketName --region $Region --create-bucket-configuration LocationConstraint=$Region
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create S3 bucket"
        }
        
        Write-Host "S3 bucket $BucketName created successfully." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Error creating S3 bucket: $_"
        return $false
    }
}

# Function to package CloudFormation templates
function ConvertTo-CloudFormationPackage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$TemplateFile,
        
        [Parameter(Mandatory=$true)]
        [string]$S3Bucket,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputFile,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )

    try {
        Write-Host "Packaging CloudFormation template $TemplateFile..." -ForegroundColor Cyan
        
        # Validate input template exists
        if (-not (Test-Path $TemplateFile)) {
            throw "Template file not found: $TemplateFile"
        }
        
        # Ensure output directory exists
        $outputDir = Split-Path $OutputFile -Parent
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        
        aws cloudformation package `
            --template-file $TemplateFile `
            --s3-bucket $S3Bucket `
            --output-template-file $OutputFile `
            --region $Region
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to package CloudFormation template"
        }
        
        # Validate output file was created
        if (-not (Test-Path $OutputFile)) {
            throw "Packaged template file was not created: $OutputFile"
        }
        
        Write-Host "Template packaged successfully: $OutputFile" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Error packaging CloudFormation template: $_"
        return $false
    }
}

# Function to empty S3 bucket (for cleanup)
function Clear-S3Bucket {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$BucketName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1",
        
        [Parameter(Mandatory=$false)]
        [switch]$IncludeVersions
    )
    
    try {
        Write-Host "Emptying S3 bucket: $BucketName..." -ForegroundColor Cyan
        
        if ($IncludeVersions) {
            # Delete all object versions and delete markers
            $versions = aws s3api list-object-versions --bucket $BucketName --query "Versions[].{Key:Key,VersionId:VersionId}" --output text --region $Region 2>$null
            if ($versions) {
                $versions | ForEach-Object {
                    if ($_ -ne "") {
                        $parts = $_ -split "`t"
                        if ($parts.Length -eq 2) {
                            aws s3api delete-object --bucket $BucketName --key $parts[0] --version-id $parts[1] --region $Region 2>$null
                        }
                    }
                }
            }
            
            # Delete delete markers
            $deleteMarkers = aws s3api list-object-versions --bucket $BucketName --query "DeleteMarkers[].{Key:Key,VersionId:VersionId}" --output text --region $Region 2>$null
            if ($deleteMarkers) {
                $deleteMarkers | ForEach-Object {
                    if ($_ -ne "") {
                        $parts = $_ -split "`t"
                        if ($parts.Length -eq 2) {
                            aws s3api delete-object --bucket $BucketName --key $parts[0] --version-id $parts[1] --region $Region 2>$null
                        }
                    }
                }
            }
        }
        
        # Delete remaining objects
        aws s3 rm s3://$BucketName --recursive --region $Region 2>$null
        
        Write-Host "S3 bucket $BucketName emptied successfully." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Error emptying S3 bucket ${BucketName}: $_"
        return $false
    }
}

# Function to get bucket names from CloudFormation stack
function Get-BucketNamesFromStack {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )
    
    try {
        $buckets = @()
        
        # Get S3 bucket resources from stack
        $bucketResources = aws cloudformation describe-stack-resources --stack-name $StackName --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" --output text --region $Region 2>$null
        
        if ($bucketResources -and $bucketResources -ne "None") {
            $bucketResources -split "`t" | ForEach-Object {
                if ($_ -and $_ -ne "None") {
                    $buckets += $_
                }
            }
        }
        
        # Also check for outputs that might contain bucket names
        $outputs = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?contains(OutputKey, 'Bucket')].OutputValue" --output text --region $Region 2>$null
        
        if ($outputs -and $outputs -ne "None") {
            $outputs -split "`t" | ForEach-Object {
                if ($_ -and $_ -ne "None" -and $buckets -notcontains $_) {
                    $buckets += $_
                }
            }
        }
        
        return $buckets
    }
    catch {
        Write-Warning "Error getting bucket names from stack: $_"
        return @()
    }
}

# Function to validate S3 bucket access
function Test-S3BucketAccess {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$BucketName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1",
        
        [Parameter(Mandatory=$false)]
        [string[]]$RequiredPermissions = @('s3:ListBucket', 's3:GetObject', 's3:PutObject')
    )
    
    $accessResults = @{
        BucketExists = $false
        CanList = $false
        CanRead = $false
        CanWrite = $false
        Errors = @()
    }
    
    try {
        # Test bucket existence
        $accessResults.BucketExists = Test-S3Bucket -BucketName $BucketName -Region $Region
        
        if ($accessResults.BucketExists) {
            # Test list permissions
            try {
                aws s3 ls s3://$BucketName --region $Region 2>$null | Out-Null
                $accessResults.CanList = ($LASTEXITCODE -eq 0)
            }
            catch {
                $accessResults.Errors += "List permission test failed: $_"
            }
            
            # Test read permissions (try to get bucket location)
            try {
                aws s3api get-bucket-location --bucket $BucketName --region $Region 2>$null | Out-Null
                $accessResults.CanRead = ($LASTEXITCODE -eq 0)
            }
            catch {
                $accessResults.Errors += "Read permission test failed: $_"
            }
            
            # Test write permissions (try to upload a small test object)
            try {
                $testKey = "test-access-$(Get-Date -Format 'yyyyMMddHHmmss').txt"
                "test" | aws s3 cp - s3://$BucketName/$testKey --region $Region 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $accessResults.CanWrite = $true
                    # Clean up test object
                    aws s3 rm s3://$BucketName/$testKey --region $Region 2>$null
                }
            }
            catch {
                $accessResults.Errors += "Write permission test failed: $_"
            }
        }
        
        return $accessResults
    }
    catch {
        $accessResults.Errors += "General access test failed: $_"
        return $accessResults
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Test-S3Bucket',
    'New-S3Bucket',
    'ConvertTo-CloudFormationPackage',
    'Clear-S3Bucket',
    'Get-BucketNamesFromStack',
    'Test-S3BucketAccess'
)