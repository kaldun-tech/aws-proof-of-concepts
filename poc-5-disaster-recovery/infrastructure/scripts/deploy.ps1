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

.PARAMETER RunTests
    Run validation tests after deployment (default: true).

.PARAMETER TestSize
    The scope of validation tests to run after deployment.
    - minimal: Validates that the CloudFormation stacks were created successfully.
    - standard: Includes 'minimal' tests and also runs local tests on the backup script's logic.
    - comprehensive: Includes all 'standard' tests and performs a full end-to-end test, which involves backing up and restoring a small sample dataset to verify the entire workflow.

.PARAMETER Profile
    The AWS CLI profile to use for authentication. Optional - uses default profile if not specified.

.EXAMPLE
    ./deploy.ps1 -Environment dev -BackupBucketName my-backup-bucket-unique-name -UserEmail user@example.com
    
.EXAMPLE
    ./deploy.ps1 -Environment dev -BackupBucketName my-backup-bucket-unique-name -UserEmail user@example.com -RunTests $true -TestSize comprehensive

.EXAMPLE
    ./deploy.ps1 -Environment dev -BackupBucketName my-backup-bucket-unique-name -UserEmail user@example.com -Profile my-sso-profile
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
    [string]$Component = "all",

    [Parameter(Mandatory=$false)]
    [bool]$RunTests = $true,

    [Parameter(Mandatory=$false)]
    [ValidateSet("minimal", "standard", "comprehensive")]
    [string]$TestSize = "standard",

    [Parameter(Mandatory=$false)]
    [string]$Profile = ""
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

# Set the AWS region
$region = $Region
$stackNamePrefix = "disaster-recovery"
$templateDir = Join-Path $PSScriptRoot ".." "cloudformation"

# Legacy function wrappers for backward compatibility (using new modules)
function Test-S3BucketLegacy {
    param ([string]$bucketName)
    return Test-S3Bucket -BucketName $bucketName -Region $region
}

function New-S3BucketLegacy {
    param ([string]$bucketName)
    $result = New-S3Bucket -BucketName $bucketName -Region $region
    if (-not $result) {
        exit 1
    }
}

function ConvertTo-CloudFormationPackageLegacy {
    param (
        [string]$templateFile,
        [string]$s3Bucket,
        [string]$outputFile
    )
    $result = ConvertTo-CloudFormationPackage -TemplateFile $templateFile -S3Bucket $s3Bucket -OutputFile $outputFile -Region $region
    if (-not $result) {
        exit 1
    }
}

# Function to deploy CloudFormation stack with enhanced error handling
function New-CloudFormationStack {
    param (
        [string]$stackName,
        [string]$templateFile,
        [hashtable]$parameters,
        [bool]$capabilities = $false,
        [int]$maxRetries = 3,
        [int]$retryDelaySeconds = 30
    )

    $retryCount = 0
    $lastError = $null
    
    while ($retryCount -lt $maxRetries) {
        try {
            Write-Host "Deploying CloudFormation stack $stackName (attempt $($retryCount + 1)/$maxRetries)..."
            
            # Validate template file exists
            if (-not (Test-Path $templateFile)) {
                throw "Template file not found: $templateFile"
            }
            
            # Validate parameters
            foreach ($key in $parameters.Keys) {
                if ($null -eq $parameters[$key] -or $parameters[$key] -eq "") {
                    Write-Warning "Parameter '$key' is null or empty"
                }
            }
            
            $paramString = ""
            foreach ($key in $parameters.Keys) {
                $paramString += "$key=$($parameters[$key]) "
            }
            
            $cmd = "aws cloudformation deploy " +
                   "--template-file `"$templateFile`" " +
                   "--stack-name $stackName " +
                   "--region $region " +
                   "--no-fail-on-empty-changeset "
            
            if ($paramString.Trim()) {
                $cmd += "--parameter-overrides $($paramString.Trim()) "
            }
            
            if ($capabilities) {
                $cmd += "--capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND "
            }
            
            Write-Host "Executing: $cmd"
            $output = Invoke-Expression $cmd 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Stack $stackName deployed successfully." -ForegroundColor Green
                return $true
            } else {
                $lastError = "CloudFormation deploy failed with exit code $LASTEXITCODE. Output: $output"
                throw $lastError
            }
        }
        catch {
            $lastError = $_.Exception.Message
            $retryCount++
            
            if ($retryCount -lt $maxRetries) {
                Write-Warning "Deployment attempt $retryCount failed: $lastError"
                Write-Host "Waiting $retryDelaySeconds seconds before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds $retryDelaySeconds
                
                # Check if the stack is in a failed state that requires manual intervention
                try {
                    $stackStatus = aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].StackStatus" --output text --region $region 2>$null
                    if ($stackStatus -like "*ROLLBACK_FAILED*" -or $stackStatus -like "*DELETE_FAILED*") {
                        Write-Error "Stack $stackName is in state $stackStatus which requires manual intervention. Cannot retry automatically."
                        throw "Stack in non-recoverable state: $stackStatus"
                    }
                } catch {
                    # Stack might not exist yet, which is fine for new deployments
                }
            } else {
                Write-Error "All deployment attempts failed. Last error: $lastError"
                
                # Try to get detailed CloudFormation events for troubleshooting
                try {
                    Write-Host "Recent CloudFormation events for troubleshooting:" -ForegroundColor Yellow
                    $events = aws cloudformation describe-stack-events --stack-name $stackName --query "StackEvents[0:10].{Time:Timestamp,Status:ResourceStatus,Reason:ResourceStatusReason,Resource:LogicalResourceId}" --output table --region $region 2>$null
                    if ($events) {
                        Write-Host $events
                    }
                } catch {
                    Write-Host "Could not retrieve CloudFormation events"
                }
                
                throw $lastError
            }
        }
    }
    
    return $false
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

# Function to run deployment tests
function Invoke-DeploymentTests {
    param (
        [string]$environment,
        [string]$testSize
    )
    
    try {
        Write-Host "Starting deployment validation tests..." -ForegroundColor Cyan
        
        # Get script directory relative to current location
        $scriptDir = $PSScriptRoot
        $testsDir = Join-Path (Split-Path $scriptDir -Parent) ".." "tests"
        
        # Test 1: Infrastructure validation
        $infraTestScript = Join-Path $testsDir "Test-Infrastructure.ps1"
        if (Test-Path $infraTestScript) {
            Write-Host "`nRunning infrastructure validation tests..." -ForegroundColor Yellow
            try {
                & $infraTestScript -Environment $environment -Region $region -Verbose
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
        
        # Test 2: Backup functionality (basic test)
        $backupTestScript = Join-Path $testsDir "Test-Backup.ps1"
        if (Test-Path $backupTestScript) {
            Write-Host "`nRunning backup functionality tests..." -ForegroundColor Yellow
            try {
                & $backupTestScript -CreateTestData -CleanupTestData -Verbose
                $backupSuccess = $LASTEXITCODE -eq 0
                if ($backupSuccess) {
                    Write-Host "✓ Backup tests passed" -ForegroundColor Green
                } else {
                    Write-Host "⚠️  Backup tests had issues (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "❌ Backup tests failed: $_" -ForegroundColor Red
                $backupSuccess = $false
            }
        } else {
            Write-Host "⚠️  Backup test script not found: $backupTestScript" -ForegroundColor Yellow
            $backupSuccess = $false
        }
        
        # Test 3: End-to-end tests (if comprehensive)
        $e2eSuccess = $true
        if ($testSize -eq "comprehensive") {
            $e2eTestScript = Join-Path $testsDir "integration" "Test-EndToEnd.ps1"
            if (Test-Path $e2eTestScript) {
                Write-Host "`nRunning end-to-end integration tests..." -ForegroundColor Yellow
                try {
                    & $e2eTestScript -Environment $environment -TestSize $testSize -CleanupAfterTest -Verbose
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
        Write-Host "`n=== TEST SUMMARY ===" -ForegroundColor Magenta
        Write-Host "Infrastructure Tests: $(if ($infraSuccess) { '✓ PASSED' } else { '❌ FAILED' })" -ForegroundColor $(if ($infraSuccess) { 'Green' } else { 'Red' })
        Write-Host "Backup Tests: $(if ($backupSuccess) { '✓ PASSED' } else { '❌ FAILED' })" -ForegroundColor $(if ($backupSuccess) { 'Green' } else { 'Red' })
        if ($testSize -eq "comprehensive") {
            Write-Host "End-to-End Tests: $(if ($e2eSuccess) { '✓ PASSED' } else { '❌ FAILED' })" -ForegroundColor $(if ($e2eSuccess) { 'Green' } else { 'Red' })
        }
        
        $allTestsPassed = $infraSuccess -and $backupSuccess -and $e2eSuccess
        
        if ($allTestsPassed) {
            Write-Host "`n🎉 All deployment tests passed! Your disaster recovery solution is ready to use." -ForegroundColor Green
        } else {
            Write-Host "`n⚠️  Some tests failed or had issues. Please review the output above." -ForegroundColor Yellow
            Write-Host "The infrastructure is deployed, but you may want to investigate test failures." -ForegroundColor Yellow
            Write-Host "`nTo re-run tests manually:" -ForegroundColor Cyan
            Write-Host "  Infrastructure: $infraTestScript -Environment $environment -Region $region -Verbose"
            Write-Host "  Backup: $backupTestScript -CreateTestData -CleanupTestData -Verbose"
            if ($testSize -eq "comprehensive") {
                Write-Host "  End-to-End: $e2eTestScript -Environment $environment -TestSize $testSize -Verbose"
            }
        }
        
        return $allTestsPassed
        
    } catch {
        Write-Host "❌ Error running deployment tests: $_" -ForegroundColor Red
        Write-Host "The infrastructure is deployed, but test validation failed." -ForegroundColor Yellow
        return $false
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
    Write-Host "Run Tests: $RunTests"
    Write-Host "Test Size: $TestSize"
    Write-Host ""

    # S3 bucket for CloudFormation templates
    $cfTemplatesBucket = "$BackupBucketName-cf-templates"
    
    if (!(Test-S3BucketLegacy -bucketName $cfTemplatesBucket)) {
        New-S3BucketLegacy -bucketName $cfTemplatesBucket
    }

    # Package main template
    $mainTemplateFile = Join-Path $templateDir "main.yaml"
    $packagedMainTemplate = Join-Path $templateDir "main-packaged.yaml"
    
    ConvertTo-CloudFormationPackageLegacy -templateFile $mainTemplateFile -s3Bucket $cfTemplatesBucket -outputFile $packagedMainTemplate

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
            Write-Host "IMPORTANT: AWS credentials have been created for backup operations."
            Write-Host "For security reasons, credentials are not displayed in console output."
            Write-Host "To retrieve credentials securely, use:"
            Write-Host "  aws cloudformation describe-stacks --stack-name $stackName --query 'Stacks[0].Outputs'"
            Write-Host ""
            Write-Host "=== NEXT STEPS ===" -ForegroundColor Cyan
            Write-Host "1. Configure AWS CLI profile:"
            Write-Host "   aws configure --profile disaster-recovery"
            Write-Host "2. Copy backup configuration:"
            Write-Host "   cp examples/backup-config.json backup-config.json"
            Write-Host "3. Edit backup-config.json with your file paths"
            Write-Host "4. Run initial backup:"
            Write-Host "   ./infrastructure/scripts/backup.ps1 -ConfigFile backup-config.json"
            
            # Run tests if requested
            if ($RunTests) {
                Write-Host "`n=== RUNNING DEPLOYMENT TESTS ===" -ForegroundColor Magenta
                Invoke-DeploymentTests -environment $Environment -testSize $TestSize
            } else {
                Write-Host "`n=== TESTS SKIPPED ===" -ForegroundColor Yellow
                Write-Host "Tests were skipped. To run tests manually:"
                Write-Host "   ./tests/Test-Infrastructure.ps1 -Environment $Environment -Verbose"
                Write-Host "   ./tests/Test-Backup.ps1 -CreateTestData -Verbose"
                Write-Host "   ./tests/integration/Test-EndToEnd.ps1 -Environment $Environment -TestSize $TestSize -Verbose"
            }
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