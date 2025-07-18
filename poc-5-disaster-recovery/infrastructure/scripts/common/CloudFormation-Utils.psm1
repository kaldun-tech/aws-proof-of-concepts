#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Common CloudFormation utilities for disaster recovery POC scripts.

.DESCRIPTION
    This module provides reusable functions for CloudFormation operations
    including stack deployment, validation, and error handling.
#>

# Function to test if stack exists
function Test-StackExists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )
    
    try {
        $null = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].StackStatus" --output text --region $Region 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

# Function to get stack status
function Get-StackStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )
    
    try {
        $status = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].StackStatus" --output text --region $Region 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $status
        } else {
            return "NOT_FOUND"
        }
    }
    catch {
        return "ERROR"
    }
}

# Function to get stack outputs
function Get-StackOutput {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputKey,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )
    
    try {
        $output = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='$OutputKey'].OutputValue" --output text --region $Region 2>$null
        if ($LASTEXITCODE -eq 0 -and $output -ne "None") {
            return $output
        } else {
            return $null
        }
    }
    catch {
        Write-Warning "Could not get output $OutputKey from stack $StackName"
        return $null
    }
}

# Function to validate stack deployment
function Test-StackDeployment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )
    
    try {
        Write-Verbose "Validating stack deployment: $StackName..."
        $status = Get-StackStatus -StackName $StackName -Region $Region
        
        if ($status -like "*COMPLETE") {
            Write-Host "Stack $StackName deployed successfully with status: $status" -ForegroundColor Green
            return $true
        } else {
            Write-Host "Stack $StackName deployment failed with status: $status" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Error "Error validating stack deployment: $_"
        return $false
    }
}

# Function to get CloudFormation events for troubleshooting
function Get-StackEvents {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$false)]
        [int]$MaxEvents = 10,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )
    
    try {
        $events = aws cloudformation describe-stack-events --stack-name $StackName --query "StackEvents[0:$MaxEvents].{Time:Timestamp,Status:ResourceStatus,Reason:ResourceStatusReason,Resource:LogicalResourceId}" --output table --region $Region 2>$null
        if ($LASTEXITCODE -eq 0 -and $events) {
            return $events
        } else {
            return $null
        }
    }
    catch {
        return $null
    }
}

# Function to deploy CloudFormation stack with enhanced error handling
function New-CloudFormationStack {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$true)]
        [string]$TemplateFile,
        
        [Parameter(Mandatory=$false)]
        [hashtable]$Parameters = @{},
        
        [Parameter(Mandatory=$false)]
        [bool]$Capabilities = $false,
        
        [Parameter(Mandatory=$false)]
        [int]$MaxRetries = 3,
        
        [Parameter(Mandatory=$false)]
        [int]$RetryDelaySeconds = 30,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1"
    )

    $retryCount = 0
    $lastError = $null
    
    while ($retryCount -lt $MaxRetries) {
        try {
            Write-Host "Deploying CloudFormation stack $StackName (attempt $($retryCount + 1)/$MaxRetries)..." -ForegroundColor Cyan
            
            # Validate template file exists
            if (-not (Test-Path $TemplateFile)) {
                throw "Template file not found: $TemplateFile"
            }
            
            # Validate parameters
            foreach ($key in $Parameters.Keys) {
                if ($null -eq $Parameters[$key] -or $Parameters[$key] -eq "") {
                    Write-Warning "Parameter '$key' is null or empty"
                }
            }
            
            # Build parameter string
            $paramString = ""
            if ($Parameters.Count -gt 0) {
                $paramArray = @()
                foreach ($key in $Parameters.Keys) {
                    $paramArray += "$key=$($Parameters[$key])"
                }
                $paramString = $paramArray -join " "
            }
            
            # Build AWS CLI command
            $cmdArgs = @(
                "cloudformation", "deploy",
                "--template-file", "`"$TemplateFile`"",
                "--stack-name", $StackName,
                "--region", $Region,
                "--no-fail-on-empty-changeset"
            )
            
            if ($paramString) {
                $cmdArgs += @("--parameter-overrides", $paramString)
            }
            
            if ($Capabilities) {
                $cmdArgs += @("--capabilities", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND")
            }
            
            Write-Verbose "Executing: aws $($cmdArgs -join ' ')"
            
            # Execute deployment
            & aws @cmdArgs
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Stack $StackName deployed successfully." -ForegroundColor Green
                return $true
            } else {
                $lastError = "CloudFormation deploy failed with exit code $LASTEXITCODE"
                throw $lastError
            }
        }
        catch {
            $lastError = $_.Exception.Message
            $retryCount++
            
            if ($retryCount -lt $MaxRetries) {
                Write-Warning "Deployment attempt $retryCount failed: $lastError"
                Write-Host "Waiting $RetryDelaySeconds seconds before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryDelaySeconds
                
                # Check if the stack is in a failed state that requires manual intervention
                $stackStatus = Get-StackStatus -StackName $StackName -Region $Region
                if ($stackStatus -like "*ROLLBACK_FAILED*" -or $stackStatus -like "*DELETE_FAILED*") {
                    Write-Error "Stack $StackName is in state $stackStatus which requires manual intervention. Cannot retry automatically."
                    throw "Stack in non-recoverable state: $stackStatus"
                }
            } else {
                Write-Error "All deployment attempts failed. Last error: $lastError"
                
                # Get detailed CloudFormation events for troubleshooting
                $events = Get-StackEvents -StackName $StackName -Region $Region
                if ($events) {
                    Write-Host "Recent CloudFormation events for troubleshooting:" -ForegroundColor Yellow
                    Write-Host $events
                }
                
                throw $lastError
            }
        }
    }
    
    return $false
}

# Function to delete CloudFormation stack
function Remove-CloudFormationStack {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$StackName,
        
        [Parameter(Mandatory=$false)]
        [string]$Region = "us-east-1",
        
        [Parameter(Mandatory=$false)]
        [int]$TimeoutMinutes = 30
    )
    
    try {
        Write-Host "Deleting CloudFormation stack: $StackName..." -ForegroundColor Cyan
        
        # Initiate stack deletion
        aws cloudformation delete-stack --stack-name $StackName --region $Region
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to initiate deletion of stack $StackName"
            return $false
        }
        
        Write-Host "Waiting for stack deletion to complete (timeout: $TimeoutMinutes minutes)..."
        
        # Wait for deletion with timeout
        $timeout = New-TimeSpan -Minutes $TimeoutMinutes
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        do {
            Start-Sleep -Seconds 30
            $status = Get-StackStatus -StackName $StackName -Region $Region
            
            if ($status -eq "NOT_FOUND") {
                Write-Host "Stack $StackName deleted successfully." -ForegroundColor Green
                return $true
            }
            
            if ($status -like "*DELETE_FAILED*") {
                Write-Error "Stack deletion failed with status: $status"
                $events = Get-StackEvents -StackName $StackName -Region $Region
                if ($events) {
                    Write-Host "Recent events:" -ForegroundColor Yellow
                    Write-Host $events
                }
                return $false
            }
            
            Write-Host "Current status: $status (elapsed: $($stopwatch.Elapsed.ToString('mm\:ss')))"
            
        } while ($stopwatch.Elapsed -lt $timeout)
        
        Write-Warning "Stack deletion timed out after $TimeoutMinutes minutes. Current status: $status"
        return $false
        
    }
    catch {
        Write-Error "Error deleting stack ${StackName}: $_"
        return $false
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Test-StackExists',
    'Get-StackStatus', 
    'Get-StackOutput',
    'Test-StackDeployment',
    'Get-StackEvents',
    'New-CloudFormationStack',
    'Remove-CloudFormationStack'
)