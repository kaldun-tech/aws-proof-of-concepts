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

.PARAMETER TestSize
    Size of tests to run (minimal, standard, comprehensive). Default is standard.

.PARAMETER IncludeFailoverTest
    Include failover testing (will terminate instances for testing). Default is $false.

.PARAMETER Profile
    The AWS CLI profile to use for authentication. Optional - uses default profile if not specified.

.EXAMPLE
    .\deploy.ps1 -Environment dev -EmailAddress user@example.com -S3BucketName my-bucket
    
.EXAMPLE
    .\deploy.ps1 -Environment dev -EmailAddress user@example.com -S3BucketName my-bucket -RunTests $true -TestSize comprehensive -IncludeFailoverTest

.EXAMPLE
    .\deploy.ps1 -Environment dev -EmailAddress user@example.com -S3BucketName my-bucket -Profile my-sso-profile
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
    [bool]$RunTests = $true,

    [Parameter(Mandatory=$false)]
    [ValidateSet("minimal", "standard", "comprehensive")]
    [string]$TestSize = "standard",

    [Parameter(Mandatory=$false)]
    [bool]$IncludeFailoverTest = $false,

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

# AWS CLI is used for all operations - no PowerShell modules needed

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

# Function to wait for stack operation to complete
function Wait-StackOperation {
    param (
        [string]$StackName,
        [string]$Operation
    )
    
    Write-Host "Waiting for $Operation operation to complete on stack $StackName..."
    
    do {
        try {
            $status = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].StackStatus" --output text --region $Region
            
            if ($status -like "*COMPLETE") {
                Write-Host "Stack $StackName $Operation completed successfully with status: $status"
                return $true
            } elseif ($status -like "*FAILED" -or $status -like "*ROLLBACK*") {
                Write-Host "Stack $StackName $Operation failed with status: $status"
                return $false
            }
            
            Write-Host "Current status: $status - waiting 10 seconds..."
            Start-Sleep -Seconds 10
        }
        catch {
            Write-Host "Error checking stack status: $_"
            return $false
        }
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
        aws s3api head-bucket --bucket $BucketName --region $Region 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Creating S3 bucket: $BucketName"
            aws s3 mb s3://$BucketName --region $Region
        }
    } catch {
        Write-Host "Creating S3 bucket: $BucketName"
        aws s3 mb s3://$BucketName --region $Region
    }
    
    # Upload templates
    $templateDir = Join-Path -Path $PSScriptRoot -ChildPath "..\cloudformation"
    $templates = Get-ChildItem -Path $templateDir -Filter "*.yaml"
    
    foreach ($template in $templates) {
        Write-Host "Uploading template: $($template.Name)"
        aws s3 cp $template.FullName s3://$BucketName/templates/$($template.Name) --region $Region
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

# Function to run comprehensive tests
function Invoke-ComprehensiveTests {
    param (
        [string]$testSize,
        [bool]$includeFailoverTest
    )
    
    try {
        Write-Host "Starting comprehensive deployment validation tests..." -ForegroundColor Cyan
        
        # Get script directory relative to current location
        $scriptDir = $PSScriptRoot
        $testsDir = Join-Path (Split-Path $scriptDir -Parent) ".." "tests"
        
        # Test 1: Infrastructure validation
        $infraTestScript = Join-Path $testsDir "Test-Infrastructure.ps1"
        if (Test-Path $infraTestScript) {
            Write-Host "`nRunning infrastructure validation tests..." -ForegroundColor Yellow
            try {
                & $infraTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose
                $infraSuccess = $LASTEXITCODE -eq 0
                if ($infraSuccess) {
                    Write-Host "✓ Infrastructure tests passed" -ForegroundColor Green
                } else {
                    Write-Host "⚠️  Infrastructure tests had issues (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "❌ Infrastructure tests failed: $_" -ForegroundColor Red
                $infraSuccess = $false
            }
        } else {
            Write-Host "⚠️  Infrastructure test script not found: $infraTestScript" -ForegroundColor Yellow
            $infraSuccess = $false
        }
        
        # Test 2: Load balancer and reliability tests
        $lbTestScript = Join-Path $testsDir "Test-LoadBalancerReliability.ps1"
        if (Test-Path $lbTestScript) {
            Write-Host "`nRunning load balancer and reliability tests..." -ForegroundColor Yellow
            try {
                if ($includeFailoverTest) {
                    & $lbTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -TestFailover -Verbose
                } else {
                    & $lbTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose
                }
                $lbSuccess = $LASTEXITCODE -eq 0
                if ($lbSuccess) {
                    Write-Host "✓ Load balancer and reliability tests passed" -ForegroundColor Green
                } else {
                    Write-Host "⚠️  Load balancer tests had issues (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "❌ Load balancer tests failed: $_" -ForegroundColor Red
                $lbSuccess = $false
            }
        } else {
            Write-Host "⚠️  Load balancer test script not found: $lbTestScript" -ForegroundColor Yellow
            $lbSuccess = $false
        }
        
        # Test 3: Database connectivity tests
        $dbTestScript = Join-Path $testsDir "Test-DatabaseConnectivity.ps1"
        if (Test-Path $dbTestScript) {
            Write-Host "`nRunning database connectivity tests..." -ForegroundColor Yellow
            try {
                if ($testSize -eq "comprehensive") {
                    & $dbTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -TestDataOperations -Verbose
                } else {
                    & $dbTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose
                }
                $dbSuccess = $LASTEXITCODE -eq 0
                if ($dbSuccess) {
                    Write-Host "✓ Database connectivity tests passed" -ForegroundColor Green
                } else {
                    Write-Host "⚠️  Database tests had issues (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "❌ Database tests failed: $_" -ForegroundColor Red
                $dbSuccess = $false
            }
        } else {
            Write-Host "⚠️  Database test script not found: $dbTestScript" -ForegroundColor Yellow
            $dbSuccess = $false
        }
        
        # Test 4: End-to-end integration tests (if comprehensive or standard)
        $e2eSuccess = $true
        if ($testSize -in @("standard", "comprehensive")) {
            $e2eTestScript = Join-Path $testsDir "integration" "Test-EndToEnd.ps1"
            if (Test-Path $e2eTestScript) {
                Write-Host "`nRunning end-to-end integration tests..." -ForegroundColor Yellow
                try {
                    if ($includeFailoverTest) {
                        & $e2eTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -TestSize $testSize -IncludeFailoverTest -CleanupAfterTest -Verbose
                    } else {
                        & $e2eTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -TestSize $testSize -CleanupAfterTest -Verbose
                    }
                    $e2eSuccess = $LASTEXITCODE -eq 0
                    if ($e2eSuccess) {
                        Write-Host "✓ End-to-end tests passed" -ForegroundColor Green
                    } else {
                        Write-Host "⚠️  End-to-end tests had issues (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "❌ End-to-end tests failed: $_" -ForegroundColor Red
                    $e2eSuccess = $false
                }
            } else {
                Write-Host "⚠️  End-to-end test script not found: $e2eTestScript" -ForegroundColor Yellow
                $e2eSuccess = $false
            }
        }
        
        # Test summary
        Write-Host "`n=== DEPLOYMENT TEST SUMMARY ===" -ForegroundColor Magenta
        Write-Host "Infrastructure Tests: $(if ($infraSuccess) { '✓ PASSED' } else { '❌ FAILED' })" -ForegroundColor $(if ($infraSuccess) { 'Green' } else { 'Red' })
        Write-Host "Load Balancer Tests: $(if ($lbSuccess) { '✓ PASSED' } else { '❌ FAILED' })" -ForegroundColor $(if ($lbSuccess) { 'Green' } else { 'Red' })
        Write-Host "Database Tests: $(if ($dbSuccess) { '✓ PASSED' } else { '❌ FAILED' })" -ForegroundColor $(if ($dbSuccess) { 'Green' } else { 'Red' })
        if ($testSize -in @("standard", "comprehensive")) {
            Write-Host "End-to-End Tests: $(if ($e2eSuccess) { '✓ PASSED' } else { '❌ FAILED' })" -ForegroundColor $(if ($e2eSuccess) { 'Green' } else { 'Red' })
        }
        
        $allTestsPassed = $infraSuccess -and $lbSuccess -and $dbSuccess -and $e2eSuccess
        
        if ($allTestsPassed) {
            Write-Host "`n🎉 All deployment tests passed! Your multi-tier infrastructure is ready for use." -ForegroundColor Green
        } else {
            Write-Host "`n⚠️  Some tests failed or had issues. Please review the output above." -ForegroundColor Yellow
            Write-Host "The infrastructure is deployed, but you may want to investigate test failures." -ForegroundColor Yellow
            Write-Host "`nTo re-run tests manually:" -ForegroundColor Cyan
            Write-Host "  Infrastructure: $infraTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose"
            Write-Host "  Load Balancer: $lbTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose"
            Write-Host "  Database: $dbTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose"
            if ($testSize -in @("standard", "comprehensive")) {
                Write-Host "  End-to-End: $e2eTestScript -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -TestSize $testSize -Verbose"
            }
        }
        
        return $allTestsPassed
        
    } catch {
        Write-Host "❌ Error running deployment tests: $_" -ForegroundColor Red
        Write-Host "The infrastructure is deployed, but test validation failed." -ForegroundColor Yellow
        return $false
    }
}

# Legacy function for backward compatibility
function Invoke-Tests {
    Write-Host "Running basic website availability test..." -ForegroundColor Yellow
    
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
                Write-Host "✓ Website is accessible. Status code: $statusCode" -ForegroundColor Green
            } else {
                Write-Host "⚠️  Website returned non-200 status code: $statusCode" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "❌ Failed to access website: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "⚠️  WebsiteURL output not found in stack outputs." -ForegroundColor Yellow
    }
    
    Write-Host "Basic test completed. Use -TestSize standard or comprehensive for full testing."
}

# Main deployment logic
try {
    Write-Host "Starting deployment of reliable multi-tier infrastructure..."
    Write-Host "Environment: $Environment"
    Write-Host "Region: $Region"
    Write-Host "Stack Name Prefix: $StackNamePrefix"
    Write-Host "Component: $Component"
    Write-Host "Run Tests: $RunTests"
    Write-Host "Test Size: $TestSize"
    Write-Host "Include Failover Test: $IncludeFailoverTest"
    
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
        if ($TestSize -ne "minimal" -or $IncludeFailoverTest) {
            Write-Host "`n=== RUNNING DEPLOYMENT TESTS ===" -ForegroundColor Magenta
            Invoke-ComprehensiveTests -testSize $TestSize -includeFailoverTest $IncludeFailoverTest
        } else {
            Write-Host "`n=== RUNNING BASIC TESTS ===" -ForegroundColor Magenta
            Invoke-Tests
        }
    } else {
        Write-Host "`n=== TESTS SKIPPED ===" -ForegroundColor Yellow
        Write-Host "Tests were skipped. To run tests manually:"
        Write-Host "  Basic: ./tests/Test-Infrastructure.ps1 -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose"
        Write-Host "  Load Balancer: ./tests/Test-LoadBalancerReliability.ps1 -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose"
        Write-Host "  Database: ./tests/Test-DatabaseConnectivity.ps1 -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -Verbose"
        Write-Host "  End-to-End: ./tests/integration/Test-EndToEnd.ps1 -Environment $Environment -StackNamePrefix $StackNamePrefix -Region $Region -TestSize $TestSize -Verbose"
    }
    
    Write-Host "Deployment completed successfully." -ForegroundColor Green
} catch {
    Write-Host "Deployment failed: $_" -ForegroundColor Red
    exit 1
}
