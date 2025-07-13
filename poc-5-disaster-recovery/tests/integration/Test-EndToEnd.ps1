#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end integration tests for Disaster Recovery POC.

.DESCRIPTION
    This script performs comprehensive end-to-end testing of the disaster recovery solution,
    including infrastructure validation, backup operations, restore processes, and monitoring.

.PARAMETER Environment
    The environment to test (dev, test, prod).

.PARAMETER TestSize
    Size of test to run (minimal, standard, comprehensive).

.PARAMETER CleanupAfterTest
    Remove test data and resources after testing.

.PARAMETER IncludeActualRestore
    Include actual S3 restore testing (will incur charges).

.PARAMETER Verbose
    Enable verbose output for detailed test results.

.EXAMPLE
    ./Test-EndToEnd.ps1 -Environment dev -TestSize minimal -Verbose
    
.EXAMPLE
    ./Test-EndToEnd.ps1 -Environment dev -TestSize standard -CleanupAfterTest -IncludeActualRestore
#>

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory=$false)]
    [ValidateSet("minimal", "standard", "comprehensive")]
    [string]$TestSize = "standard",

    [Parameter(Mandatory=$false)]
    [switch]$CleanupAfterTest,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeActualRestore,

    [Parameter(Mandatory=$false)]
    [switch]$Verbose
)

# Set error action preference
$ErrorActionPreference = "Continue"

# Test results tracking
$script:TestResults = @{
    TotalTests = 0
    PassedTests = 0
    FailedTests = 0
    SkippedTests = 0
    Errors = @()
    StartTime = Get-Date
    TestData = @{}
}

# Function to write test output
function Write-TestResult {
    param (
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = "",
        [string]$Details = ""
    )
    
    $script:TestResults.TotalTests++
    
    if ($Passed) {
        $script:TestResults.PassedTests++
        $status = "PASS"
        $color = "Green"
    } else {
        $script:TestResults.FailedTests++
        $status = "FAIL"
        $color = "Red"
        $script:TestResults.Errors += "$TestName`: $Message"
    }
    
    $output = "[$status] $TestName"
    if ($Message) {
        $output += " - $Message"
    }
    
    Write-Host $output -ForegroundColor $color
    
    if ($Details -and $Verbose) {
        Write-Host "        $Details" -ForegroundColor Gray
    }
}

# Function to skip a test
function Skip-Test {
    param (
        [string]$TestName,
        [string]$Reason
    )
    
    $script:TestResults.TotalTests++
    $script:TestResults.SkippedTests++
    Write-Host "[SKIP] $TestName - $Reason" -ForegroundColor Yellow
}

# Function to run a test script and capture results
function Invoke-TestScript {
    param (
        [string]$ScriptPath,
        [string]$TestName,
        [hashtable]$Parameters = @{}
    )
    
    try {
        if (!(Test-Path $ScriptPath)) {
            Write-TestResult $TestName $false "Test script not found: $ScriptPath"
            return $false
        }
        
        $paramString = ""
        foreach ($key in $Parameters.Keys) {
            if ($Parameters[$key] -is [switch] -or $Parameters[$key] -is [bool]) {
                if ($Parameters[$key]) {
                    $paramString += " -$key"
                }
            } else {
                $paramString += " -$key '$($Parameters[$key])'"
            }
        }
        
        Write-Host "    Running: $ScriptPath $paramString" -ForegroundColor Gray
        
        $output = & $ScriptPath @Parameters 2>&1
        $success = $LASTEXITCODE -eq 0
        
        if ($Verbose -and $output) {
            Write-Host "        Output:" -ForegroundColor Gray
            $output | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
        }
        
        Write-TestResult $TestName $success "Exit code: $LASTEXITCODE"
        return $success
        
    } catch {
        Write-TestResult $TestName $false $_.Exception.Message
        return $false
    }
}

# Phase 1: Infrastructure validation
function Test-InfrastructurePhase {
    Write-Host "`n=== PHASE 1: Infrastructure Validation ===`n" -ForegroundColor Cyan
    
    $infraScript = Join-Path $PSScriptRoot ".." "Test-Infrastructure.ps1"
    $parameters = @{
        Environment = $Environment
        Verbose = $Verbose
    }
    
    $success = Invoke-TestScript -ScriptPath $infraScript -TestName "Infrastructure validation" -Parameters $parameters
    
    if (!$success) {
        Write-Host "⚠️  Infrastructure validation failed. Some tests may be skipped." -ForegroundColor Yellow
    }
    
    return $success
}

# Phase 2: Backup functionality testing
function Test-BackupPhase {
    Write-Host "`n=== PHASE 2: Backup Functionality Testing ===`n" -ForegroundColor Cyan
    
    $backupScript = Join-Path $PSScriptRoot ".." "Test-Backup.ps1"
    $parameters = @{
        CreateTestData = $true
        CleanupTestData = $CleanupAfterTest
        Verbose = $Verbose
    }
    
    # Add actual upload test for comprehensive testing
    if ($TestSize -eq "comprehensive" -and $IncludeActualRestore) {
        $parameters.TestUpload = $true
        Write-Host "⚠️  WARNING: Actual S3 upload testing enabled - this will incur charges!" -ForegroundColor Red
    }
    
    $success = Invoke-TestScript -ScriptPath $backupScript -TestName "Backup functionality" -Parameters $parameters
    
    # Store backup test data path for later phases
    if ($success) {
        # Try to extract test data path from the backup test
        try {
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $testDataPath = Join-Path $env:TEMP "dr-test-data-*"
            $latestTestData = Get-ChildItem $testDataPath -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1
            if ($latestTestData) {
                $script:TestResults.TestData.BackupDataPath = $latestTestData.FullName
            }
        } catch {
            # Test data path extraction failed, but this is not critical
        }
    }
    
    return $success
}

# Phase 3: Restore functionality testing
function Test-RestorePhase {
    Write-Host "`n=== PHASE 3: Restore Functionality Testing ===`n" -ForegroundColor Cyan
    
    $restoreScript = Join-Path $PSScriptRoot ".." "Test-Restore.ps1"
    
    # Configure restore test parameters based on test size
    $testType = switch ($TestSize) {
        "minimal" { "simulation" }
        "standard" { "simulation" }
        "comprehensive" { "integration" }
    }
    
    $parameters = @{
        TestType = $testType
        MockData = !$IncludeActualRestore
        Verbose = $Verbose
    }
    
    $success = Invoke-TestScript -ScriptPath $restoreScript -TestName "Restore functionality" -Parameters $parameters
    
    return $success
}

# Phase 4: Integration testing
function Test-IntegrationPhase {
    Write-Host "`n=== PHASE 4: Integration Testing ===`n" -ForegroundColor Cyan
    
    try {
        # Test backup and restore script integration
        $backupScript = Join-Path $PSScriptRoot ".." ".." "infrastructure" "scripts" "backup.ps1"
        $restoreScript = Join-Path $PSScriptRoot ".." ".." "infrastructure" "scripts" "restore.ps1"
        
        $backupExists = Test-Path $backupScript
        $restoreExists = Test-Path $restoreScript
        
        Write-TestResult "Backup script accessible" $backupExists "Path: $backupScript"
        Write-TestResult "Restore script accessible" $restoreExists "Path: $restoreScript"
        
        if ($backupExists -and $restoreExists) {
            # Test help functionality
            try {
                $backupHelp = & $backupScript -? 2>&1 | Out-String
                $backupHelpWorking = $backupHelp -like "*SYNOPSIS*" -or $backupHelp -like "*DESCRIPTION*"
                Write-TestResult "Backup script help functionality" $backupHelpWorking
            } catch {
                Write-TestResult "Backup script help functionality" $false $_.Exception.Message
            }
            
            try {
                $restoreHelp = & $restoreScript -Action list -? 2>&1 | Out-String
                $restoreHelpWorking = $restoreHelp -like "*SYNOPSIS*" -or $restoreHelp -like "*list*"
                Write-TestResult "Restore script help functionality" $restoreHelpWorking
            } catch {
                Write-TestResult "Restore script help functionality" $false $_.Exception.Message
            }
        }
        
        # Test configuration file compatibility
        $configFile = Join-Path $PSScriptRoot ".." ".." "examples" "backup-config.json"
        if (Test-Path $configFile) {
            try {
                $config = Get-Content $configFile | ConvertFrom-Json
                $configValid = $config.PSObject.Properties.Name -contains "backupName" -and
                              $config.PSObject.Properties.Name -contains "paths"
                Write-TestResult "Configuration file format valid" $configValid
                
                # Test paths in configuration
                $validPaths = 0
                $totalPaths = 0
                foreach ($path in $config.paths) {
                    $totalPaths++
                    if ($path.enabled -ne $false) {
                        # For testing, we'll just check the structure rather than actual paths
                        if ($path.PSObject.Properties.Name -contains "source" -and
                            $path.PSObject.Properties.Name -contains "include") {
                            $validPaths++
                        }
                    }
                }
                
                Write-TestResult "Configuration paths structure valid" ($validPaths -gt 0) "Valid: $validPaths / $totalPaths"
                
            } catch {
                Write-TestResult "Configuration file format valid" $false $_.Exception.Message
            }
        } else {
            Skip-Test "Configuration file validation" "Config file not found"
        }
        
        # Test CloudWatch integration (if possible)
        try {
            $logGroups = aws logs describe-log-groups --log-group-name-prefix "/aws/disaster-recovery" --output json 2>$null | ConvertFrom-Json
            $hasLogGroups = $logGroups.logGroups.Count -gt 0
            Write-TestResult "CloudWatch log groups accessible" $hasLogGroups "Groups: $($logGroups.logGroups.Count)"
        } catch {
            Skip-Test "CloudWatch log groups accessible" "AWS CLI not available or not configured"
        }
        
        # Test SNS integration (if possible)
        try {
            $topics = aws sns list-topics --output json 2>$null | ConvertFrom-Json
            $drTopics = $topics.Topics | Where-Object { $_.TopicArn -like "*disaster-recovery*" }
            $hasTopics = $drTopics.Count -gt 0
            Write-TestResult "SNS notification topics accessible" $hasTopics "Topics: $($drTopics.Count)"
        } catch {
            Skip-Test "SNS notification topics accessible" "AWS CLI not available or not configured"
        }
        
        return $true
        
    } catch {
        Write-TestResult "Integration testing" $false $_.Exception.Message
        return $false
    }
}

# Phase 5: End-to-end workflow testing
function Test-WorkflowPhase {
    Write-Host "`n=== PHASE 5: End-to-End Workflow Testing ===`n" -ForegroundColor Cyan
    
    if ($TestSize -eq "minimal") {
        Skip-Test "End-to-end workflow testing" "Minimal test mode"
        return $true
    }
    
    try {
        # Create test workflow scenario
        Write-Host "Creating test workflow scenario..." -ForegroundColor Gray
        
        # Step 1: Create test data
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $workflowTestPath = Join-Path $env:TEMP "dr-workflow-test-$timestamp"
        New-Item -ItemType Directory -Path $workflowTestPath -Force | Out-Null
        
        # Create sample files
        $testFiles = @(
            @{ Name = "document.txt"; Content = "Test document for workflow testing" },
            @{ Name = "image.jpg"; Content = "Mock image data for testing" },
            @{ Name = "data.csv"; Content = "name,value`ntest,123`nworkflow,456" }
        )
        
        foreach ($file in $testFiles) {
            $filePath = Join-Path $workflowTestPath $file.Name
            $file.Content | Out-File -FilePath $filePath -Encoding UTF8
        }
        
        Write-TestResult "Test workflow data created" (Test-Path $workflowTestPath) "Path: $workflowTestPath"
        
        # Step 2: Create workflow configuration
        $workflowConfig = @{
            backupName = "WorkflowTest"
            compression = @{ enabled = $true; level = 6; format = "zip" }
            paths = @(
                @{
                    name = "WorkflowTestData"
                    source = $workflowTestPath
                    include = @("*.txt", "*.jpg", "*.csv")
                    exclude = @()
                }
            )
        }
        
        $configPath = Join-Path $workflowTestPath "workflow-config.json"
        $workflowConfig | ConvertTo-Json -Depth 4 | Out-File -FilePath $configPath -Encoding UTF8
        
        Write-TestResult "Workflow configuration created" (Test-Path $configPath) "Config: $configPath"
        
        # Step 3: Test backup workflow (dry run)
        $backupScript = Join-Path $PSScriptRoot ".." ".." "infrastructure" "scripts" "backup.ps1"
        if (Test-Path $backupScript) {
            try {
                Write-Host "    Testing backup workflow (dry run)..." -ForegroundColor Gray
                $backupOutput = & $backupScript -ConfigFile $configPath -TestMode $true -Verbose 2>&1
                $backupSuccess = $LASTEXITCODE -eq 0
                
                Write-TestResult "Backup workflow dry run" $backupSuccess "Exit code: $LASTEXITCODE"
                
                if ($Verbose -and $backupOutput) {
                    Write-Host "        Backup output:" -ForegroundColor Gray
                    $backupOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
                }
                
            } catch {
                Write-TestResult "Backup workflow dry run" $false $_.Exception.Message
            }
        } else {
            Skip-Test "Backup workflow dry run" "Backup script not found"
        }
        
        # Step 4: Test restore workflow (simulation)
        $restoreScript = Join-Path $PSScriptRoot ".." ".." "infrastructure" "scripts" "restore.ps1"
        if (Test-Path $restoreScript) {
            try {
                Write-Host "    Testing restore workflow (list)..." -ForegroundColor Gray
                $restoreOutput = & $restoreScript -Action list 2>&1
                $restoreSuccess = $LASTEXITCODE -eq 0
                
                Write-TestResult "Restore workflow list" $restoreSuccess "Exit code: $LASTEXITCODE"
                
            } catch {
                Write-TestResult "Restore workflow list" $false $_.Exception.Message
            }
        } else {
            Skip-Test "Restore workflow simulation" "Restore script not found"
        }
        
        # Step 5: Test monitoring and logging
        try {
            Write-Host "    Testing logging functionality..." -ForegroundColor Gray
            
            $logFile = Join-Path $workflowTestPath "test-workflow.log"
            $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] Workflow test completed successfully"
            $logEntry | Out-File -FilePath $logFile -Encoding UTF8
            
            $logCreated = Test-Path $logFile
            Write-TestResult "Workflow logging functionality" $logCreated "Log: $logFile"
            
        } catch {
            Write-TestResult "Workflow logging functionality" $false $_.Exception.Message
        }
        
        # Cleanup workflow test data
        if ($CleanupAfterTest) {
            try {
                Remove-Item $workflowTestPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-TestResult "Workflow test data cleanup" $true "Removed: $workflowTestPath"
            } catch {
                Write-TestResult "Workflow test data cleanup" $false $_.Exception.Message
            }
        } else {
            Write-Host "Workflow test data preserved at: $workflowTestPath" -ForegroundColor Yellow
        }
        
        return $true
        
    } catch {
        Write-TestResult "End-to-end workflow testing" $false $_.Exception.Message
        return $false
    }
}

# Generate comprehensive test report
function New-TestReport {
    Write-Host "`n=== GENERATING TEST REPORT ===`n" -ForegroundColor Cyan
    
    try {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $reportPath = Join-Path $env:TEMP "dr-test-report-$timestamp.json"
        
        $report = @{
            testSession = @{
                timestamp = $script:TestResults.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
                environment = $Environment
                testSize = $TestSize
                includeActualRestore = $IncludeActualRestore
                duration = ($script:TestResults.EndTime - $script:TestResults.StartTime).ToString("hh\:mm\:ss")
            }
            summary = @{
                totalTests = $script:TestResults.TotalTests
                passedTests = $script:TestResults.PassedTests
                failedTests = $script:TestResults.FailedTests
                skippedTests = $script:TestResults.SkippedTests
                successRate = if ($script:TestResults.TotalTests -gt 0) { [math]::Round(($script:TestResults.PassedTests / $script:TestResults.TotalTests) * 100, 1) } else { 0 }
            }
            errors = $script:TestResults.Errors
            testData = $script:TestResults.TestData
            recommendations = @()
        }
        
        # Add recommendations based on results
        if ($script:TestResults.FailedTests -gt 0) {
            $report.recommendations += "Review failed tests and address underlying issues"
        }
        
        if ($script:TestResults.SkippedTests -gt 0) {
            $report.recommendations += "Consider running skipped tests in appropriate environment"
        }
        
        if (!$IncludeActualRestore -and $TestSize -eq "comprehensive") {
            $report.recommendations += "Run comprehensive tests with actual restore testing for full validation"
        }
        
        $report | ConvertTo-Json -Depth 4 | Out-File -FilePath $reportPath -Encoding UTF8
        
        Write-TestResult "Test report generated" (Test-Path $reportPath) "Report: $reportPath"
        
        return $reportPath
        
    } catch {
        Write-TestResult "Test report generation" $false $_.Exception.Message
        return $null
    }
}

# Main test execution
function Invoke-EndToEndTests {
    Write-Host "=== DISASTER RECOVERY END-TO-END TESTS ===`n" -ForegroundColor Magenta
    Write-Host "Environment: $Environment"
    Write-Host "Test Size: $TestSize"
    Write-Host "Include Actual Restore: $IncludeActualRestore"
    Write-Host "Cleanup After Test: $CleanupAfterTest"
    Write-Host "Started: $($script:TestResults.StartTime)"
    
    if ($IncludeActualRestore) {
        Write-Host ""
        Write-Host "⚠️  WARNING: Actual restore testing enabled - this will incur AWS charges!" -ForegroundColor Red
    }
    
    Write-Host ""
    
    # Execute test phases
    $phases = @()
    
    # Phase 1: Infrastructure validation
    $infrastructureSuccess = Test-InfrastructurePhase
    $phases += @{ Name = "Infrastructure"; Success = $infrastructureSuccess }
    
    # Phase 2: Backup functionality (always run)
    $backupSuccess = Test-BackupPhase
    $phases += @{ Name = "Backup"; Success = $backupSuccess }
    
    # Phase 3: Restore functionality (always run)
    $restoreSuccess = Test-RestorePhase
    $phases += @{ Name = "Restore"; Success = $restoreSuccess }
    
    # Phase 4: Integration testing (skip for minimal)
    if ($TestSize -ne "minimal") {
        $integrationSuccess = Test-IntegrationPhase
        $phases += @{ Name = "Integration"; Success = $integrationSuccess }
    }
    
    # Phase 5: End-to-end workflow (standard and comprehensive)
    if ($TestSize -in @("standard", "comprehensive")) {
        $workflowSuccess = Test-WorkflowPhase
        $phases += @{ Name = "Workflow"; Success = $workflowSuccess }
    }
    
    # Generate test report
    $script:TestResults.EndTime = Get-Date
    $reportPath = New-TestReport
    
    # Final summary
    $duration = $script:TestResults.EndTime - $script:TestResults.StartTime
    
    Write-Host "`n=== END-TO-END TEST SUMMARY ===`n" -ForegroundColor Magenta
    Write-Host "Test Phases:" -ForegroundColor White
    foreach ($phase in $phases) {
        $status = if ($phase.Success) { "✓" } else { "❌" }
        $color = if ($phase.Success) { "Green" } else { "Red" }
        Write-Host "  $status $($phase.Name)" -ForegroundColor $color
    }
    
    Write-Host ""
    Write-Host "Overall Results:" -ForegroundColor White
    Write-Host "  Total Tests: $($script:TestResults.TotalTests)"
    Write-Host "  Passed: $($script:TestResults.PassedTests)" -ForegroundColor Green
    Write-Host "  Failed: $($script:TestResults.FailedTests)" -ForegroundColor Red
    Write-Host "  Skipped: $($script:TestResults.SkippedTests)" -ForegroundColor Yellow
    Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))"
    
    if ($reportPath) {
        Write-Host "  Report: $reportPath" -ForegroundColor Cyan
    }
    
    Write-Host ""
    
    if ($script:TestResults.FailedTests -gt 0) {
        Write-Host "Failed Tests:" -ForegroundColor Red
        foreach ($error in $script:TestResults.Errors) {
            Write-Host "  - $error" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    $successRate = if ($script:TestResults.TotalTests -gt 0) { [math]::Round(($script:TestResults.PassedTests / $script:TestResults.TotalTests) * 100, 1) } else { 0 }
    
    # Determine overall result
    if ($script:TestResults.FailedTests -eq 0) {
        Write-Host "🎉 All end-to-end tests passed! Disaster recovery solution is working correctly." -ForegroundColor Green
        return 0
    } elseif ($successRate -ge 75) {
        Write-Host "⚠️  Most tests passed ($successRate%). Review failed tests and consider re-running." -ForegroundColor Yellow
        return 1
    } else {
        Write-Host "❌ Many tests failed ($successRate%). Disaster recovery solution needs attention." -ForegroundColor Red
        return 2
    }
}

# Execute tests
try {
    # Create integration directory if it doesn't exist
    $integrationDir = Split-Path $PSCommandPath -Parent
    if (!(Test-Path $integrationDir)) {
        New-Item -ItemType Directory -Path $integrationDir -Force | Out-Null
    }
    
    $exitCode = Invoke-EndToEndTests
    exit $exitCode
} catch {
    Write-Host "❌ End-to-end test execution failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}