#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end integration tests for Multi-Tier Reliable Infrastructure POC.

.DESCRIPTION
    This script performs comprehensive end-to-end testing of the multi-tier infrastructure,
    including infrastructure validation, load balancer reliability, database connectivity,
    and complete workflow testing.

.PARAMETER Environment
    The environment to test (dev, test, prod).

.PARAMETER StackNamePrefix
    The prefix used for CloudFormation stack names.

.PARAMETER Region
    The AWS region where resources are deployed.

.PARAMETER TestSize
    Size of test to run (minimal, standard, comprehensive).

.PARAMETER CleanupAfterTest
    Remove test data and resources after testing.

.PARAMETER IncludeFailoverTest
    Include actual failover testing (will terminate instances).

.PARAMETER Verbose
    Enable verbose output for detailed test results.

.EXAMPLE
    ./Test-EndToEnd.ps1 -Environment dev -StackNamePrefix WebApp1 -TestSize standard -Verbose
    
.EXAMPLE
    ./Test-EndToEnd.ps1 -Environment dev -StackNamePrefix WebApp1 -TestSize comprehensive -IncludeFailoverTest -CleanupAfterTest -Verbose
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
    [ValidateSet("minimal", "standard", "comprehensive")]
    [string]$TestSize = "standard",

    [Parameter(Mandatory=$false)]
    [switch]$CleanupAfterTest,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeFailoverTest,

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
    PhaseResults = @{}
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
        StackNamePrefix = $StackNamePrefix
        Region = $Region
        Verbose = $Verbose
    }
    
    $success = Invoke-TestScript -ScriptPath $infraScript -TestName "Infrastructure validation" -Parameters $parameters
    $script:TestResults.PhaseResults["Infrastructure"] = $success
    
    if (!$success) {
        Write-Host "⚠️  Infrastructure validation failed. Some tests may be skipped." -ForegroundColor Yellow
    }
    
    return $success
}

# Phase 2: Load balancer and reliability testing
function Test-LoadBalancerPhase {
    Write-Host "`n=== PHASE 2: Load Balancer & Reliability Testing ===`n" -ForegroundColor Cyan
    
    $lbScript = Join-Path $PSScriptRoot ".." "Test-LoadBalancerReliability.ps1"
    $parameters = @{
        Environment = $Environment
        StackNamePrefix = $StackNamePrefix
        Region = $Region
        TestFailover = $IncludeFailoverTest
        Verbose = $Verbose
    }
    
    $success = Invoke-TestScript -ScriptPath $lbScript -TestName "Load balancer and reliability" -Parameters $parameters
    $script:TestResults.PhaseResults["LoadBalancer"] = $success
    
    return $success
}

# Phase 3: Database connectivity testing
function Test-DatabasePhase {
    Write-Host "`n=== PHASE 3: Database Connectivity Testing ===`n" -ForegroundColor Cyan
    
    $dbScript = Join-Path $PSScriptRoot ".." "Test-DatabaseConnectivity.ps1"
    
    # Configure database test parameters based on test size
    $testDataOps = $TestSize -eq "comprehensive"
    
    $parameters = @{
        Environment = $Environment
        StackNamePrefix = $StackNamePrefix
        Region = $Region
        TestDataOperations = $testDataOps
        Verbose = $Verbose
    }
    
    $success = Invoke-TestScript -ScriptPath $dbScript -TestName "Database connectivity" -Parameters $parameters
    $script:TestResults.PhaseResults["Database"] = $success
    
    return $success
}

# Phase 4: Application workflow testing
function Test-ApplicationWorkflowPhase {
    Write-Host "`n=== PHASE 4: Application Workflow Testing ===`n" -ForegroundColor Cyan
    
    if ($TestSize -eq "minimal") {
        Skip-Test "Application workflow testing" "Minimal test mode"
        return $true
    }
    
    try {
        # Get infrastructure details
        $webAppStackName = "$StackNamePrefix-WebApp"
        $websiteUrl = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue" --output text --region $Region 2>$null
        
        if (!$websiteUrl -or $websiteUrl -eq "None") {
            Write-TestResult "Application workflow setup" $false "Website URL not available"
            return $false
        }
        
        Write-TestResult "Application workflow setup" $true "Website URL: $websiteUrl"
        
        # Test 1: Basic application functionality
        Write-Host "    Testing basic application functionality..." -ForegroundColor Gray
        
        try {
            $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 30
            $appWorking = $response.StatusCode -eq 200
            Write-TestResult "Application responds to requests" $appWorking "Status: $($response.StatusCode)"
            
            if ($appWorking) {
                # Test application content
                $hasContent = $response.Content.Length -gt 0
                Write-TestResult "Application returns content" $hasContent "Size: $($response.Content.Length) bytes"
                
                # Test for application-specific functionality (look for common web app patterns)
                $hasWebAppStructure = $response.Content -like "*html*" -or $response.Content -like "*body*" -or $response.Content -like "*title*"
                Write-TestResult "Application has web structure" $hasWebAppStructure "Contains HTML elements"
                
                # Test for health check endpoint (if available)
                try {
                    $healthUrl = $websiteUrl.TrimEnd('/') + "/health"
                    $healthResponse = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
                    if ($healthResponse.StatusCode -eq 200) {
                        Write-TestResult "Application health endpoint available" $true "Health check responds"
                    } else {
                        Skip-Test "Application health endpoint" "No health endpoint found"
                    }
                } catch {
                    Skip-Test "Application health endpoint" "Health endpoint not accessible"
                }
            }
            
        } catch {
            Write-TestResult "Application responds to requests" $false $_.Exception.Message
            return $false
        }
        
        # Test 2: Application under load
        if ($TestSize -eq "comprehensive") {
            Write-Host "    Testing application under load..." -ForegroundColor Gray
            
            $loadTestResults = @{
                TotalRequests = 20
                SuccessfulRequests = 0
                FailedRequests = 0
                ResponseTimes = @()
            }
            
            for ($i = 1; $i -le $loadTestResults.TotalRequests; $i++) {
                try {
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 15
                    $stopwatch.Stop()
                    
                    if ($response.StatusCode -eq 200) {
                        $loadTestResults.SuccessfulRequests++
                        $loadTestResults.ResponseTimes += $stopwatch.ElapsedMilliseconds
                    } else {
                        $loadTestResults.FailedRequests++
                    }
                } catch {
                    $loadTestResults.FailedRequests++
                }
                
                Start-Sleep -Milliseconds 100  # Brief pause between requests
            }
            
            $successRate = ($loadTestResults.SuccessfulRequests / $loadTestResults.TotalRequests) * 100
            Write-TestResult "Application handles load testing" ($successRate -ge 80) "Success rate: $successRate% ($($loadTestResults.SuccessfulRequests)/$($loadTestResults.TotalRequests))"
            
            if ($loadTestResults.ResponseTimes.Count -gt 0) {
                $avgResponseTime = ($loadTestResults.ResponseTimes | Measure-Object -Average).Average
                $maxResponseTime = ($loadTestResults.ResponseTimes | Measure-Object -Maximum).Maximum
                Write-TestResult "Application response time under load" ($avgResponseTime -lt 5000) "Avg: $([math]::Round($avgResponseTime, 0))ms, Max: $maxResponseTime ms"
            }
        }
        
        # Test 3: Cross-tier communication
        Write-Host "    Testing cross-tier communication..." -ForegroundColor Gray
        
        # Test if the application can communicate with the database
        # This is a simplified test - in practice, you might have specific endpoints to test database connectivity
        
        # Check if the application returns dynamic content (suggesting database interaction)
        $requests = @()
        for ($i = 1; $i -le 3; $i++) {
            try {
                $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 10
                if ($response.StatusCode -eq 200) {
                    $requests += $response.Content
                }
                Start-Sleep -Seconds 1
            } catch {
                # Request failed
            }
        }
        
        if ($requests.Count -ge 2) {
            # Look for dynamic content (timestamps, session IDs, etc.)
            $hasTimestamp = $requests | Where-Object { $_ -match '\d{4}-\d{2}-\d{2}|\d{2}:\d{2}:\d{2}' }
            $hasDynamicContent = $requests | Where-Object { $_ -match 'session|time|date|id' }
            
            $isDynamic = $hasTimestamp.Count -gt 0 -or $hasDynamicContent.Count -gt 0
            Write-TestResult "Application serves dynamic content" $isDynamic "Suggests database connectivity"
        } else {
            Skip-Test "Cross-tier communication test" "Insufficient responses to analyze"
        }
        
        return $true
        
    } catch {
        Write-TestResult "Application workflow testing" $false $_.Exception.Message
        return $false
    }
}

# Phase 5: End-to-end reliability testing
function Test-ReliabilityPhase {
    Write-Host "`n=== PHASE 5: End-to-End Reliability Testing ===`n" -ForegroundColor Cyan
    
    if ($TestSize -eq "minimal") {
        Skip-Test "End-to-end reliability testing" "Minimal test mode"
        return $true
    }
    
    try {
        # Test multi-AZ resilience
        Write-Host "    Testing multi-AZ resilience..." -ForegroundColor Gray
        
        # Get VPC and subnet information
        $vpcStackName = "$StackNamePrefix-VPC"
        $vpcId = aws cloudformation describe-stacks --stack-name $vpcStackName --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" --output text --region $Region 2>$null
        
        if ($vpcId -and $vpcId -ne "None") {
            $subnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --region $Region --output json 2>$null | ConvertFrom-Json
            $azs = $subnets.Subnets | Select-Object -ExpandProperty AvailabilityZone | Sort-Object -Unique
            
            Write-TestResult "Infrastructure spans multiple AZs" ($azs.Count -gt 1) "AZs: $($azs.Count)" -Details ($azs -join ", ")
            
            # Test load balancer distribution across AZs
            $webAppStackName = "$StackNamePrefix-WebApp"
            $albArn = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='ALBArn'].OutputValue" --output text --region $Region 2>$null
            
            if ($albArn -and $albArn -ne "None") {
                $alb = aws elbv2 describe-load-balancers --load-balancer-arns $albArn --region $Region --output json 2>$null | ConvertFrom-Json
                $albAZs = $alb.LoadBalancers[0].AvailabilityZones
                
                Write-TestResult "Load balancer distributed across AZs" ($albAZs.Count -gt 1) "ALB AZs: $($albAZs.Count)"
            }
        }
        
        # Test auto-scaling readiness
        Write-Host "    Testing auto-scaling readiness..." -ForegroundColor Gray
        
        $asgName = aws cloudformation describe-stack-resources --stack-name $webAppStackName --logical-resource-id "WebTierAutoScalingGroup" --query "StackResources[0].PhysicalResourceId" --output text --region $Region 2>$null
        
        if ($asgName -and $asgName -ne "None") {
            $asg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --output json 2>$null | ConvertFrom-Json
            $asgDetails = $asg.AutoScalingGroups[0]
            
            $canScale = $asgDetails.MaxSize -gt $asgDetails.MinSize
            Write-TestResult "Auto Scaling Group can scale" $canScale "Range: $($asgDetails.MinSize) to $($asgDetails.MaxSize)"
            
            # Test health check configuration
            $healthCheckType = $asgDetails.HealthCheckType
            $healthCheckGracePeriod = $asgDetails.HealthCheckGracePeriod
            
            Write-TestResult "Health checks properly configured" ($healthCheckType -eq "ELB" -and $healthCheckGracePeriod -ge 60) "Type: $healthCheckType, Grace: $healthCheckGracePeriod"
        }
        
        # Test monitoring and alerting readiness
        Write-Host "    Testing monitoring readiness..." -ForegroundColor Gray
        
        # Check for CloudWatch alarms
        $alarms = aws cloudwatch describe-alarms --region $Region --output json 2>$null | ConvertFrom-Json
        $appAlarms = $alarms.MetricAlarms | Where-Object { $_.AlarmName -like "*$StackNamePrefix*" }
        
        Write-TestResult "CloudWatch alarms configured" ($appAlarms.Count -gt 0) "Alarms: $($appAlarms.Count)"
        
        if ($appAlarms.Count -gt 0) {
            $okAlarms = $appAlarms | Where-Object { $_.StateValue -eq "OK" }
            $alarmAlarms = $appAlarms | Where-Object { $_.StateValue -eq "ALARM" }
            
            Write-TestResult "CloudWatch alarms in good state" ($alarmAlarms.Count -eq 0) "OK: $($okAlarms.Count), ALARM: $($alarmAlarms.Count)"
        }
        
        # Test backup and recovery readiness
        Write-Host "    Testing backup readiness..." -ForegroundColor Gray
        
        $tableName = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='DynamoDBTable'].OutputValue" --output text --region $Region 2>$null
        
        if ($tableName -and $tableName -ne "None") {
            try {
                $pitr = aws dynamodb describe-continuous-backups --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
                $pitrEnabled = $pitr.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus -eq "ENABLED"
                
                Write-TestResult "Database backup configured" $pitrEnabled "Point-in-time recovery enabled"
            } catch {
                Skip-Test "Database backup check" "Could not verify backup configuration"
            }
        }
        
        return $true
        
    } catch {
        Write-TestResult "End-to-end reliability testing" $false $_.Exception.Message
        return $false
    }
}

# Generate comprehensive test report
function New-TestReport {
    Write-Host "`n=== GENERATING TEST REPORT ===`n" -ForegroundColor Cyan
    
    try {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $reportPath = Join-Path $env:TEMP "multitier-test-report-$timestamp.json"
        
        $report = @{
            testSession = @{
                timestamp = $script:TestResults.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
                environment = $Environment
                stackPrefix = $StackNamePrefix
                region = $Region
                testSize = $TestSize
                includeFailoverTest = $IncludeFailoverTest
                duration = ($script:TestResults.EndTime - $script:TestResults.StartTime).ToString("hh\:mm\:ss")
            }
            summary = @{
                totalTests = $script:TestResults.TotalTests
                passedTests = $script:TestResults.PassedTests
                failedTests = $script:TestResults.FailedTests
                skippedTests = $script:TestResults.SkippedTests
                successRate = if ($script:TestResults.TotalTests -gt 0) { [math]::Round(($script:TestResults.PassedTests / $script:TestResults.TotalTests) * 100, 1) } else { 0 }
            }
            phaseResults = $script:TestResults.PhaseResults
            errors = $script:TestResults.Errors
            testData = $script:TestResults.TestData
            recommendations = @()
        }
        
        # Add phase-specific recommendations
        foreach ($phase in $script:TestResults.PhaseResults.Keys) {
            if (!$script:TestResults.PhaseResults[$phase]) {
                $report.recommendations += "Review and fix issues in $phase phase"
            }
        }
        
        # Add general recommendations
        if ($script:TestResults.FailedTests -gt 0) {
            $report.recommendations += "Address failed tests before production deployment"
        }
        
        if ($script:TestResults.SkippedTests -gt 0) {
            $report.recommendations += "Consider running skipped tests in appropriate environment"
        }
        
        if (!$IncludeFailoverTest -and $TestSize -eq "comprehensive") {
            $report.recommendations += "Run comprehensive tests with failover testing for full validation"
        }
        
        if ($TestSize -ne "comprehensive") {
            $report.recommendations += "Run comprehensive tests before production deployment"
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
    Write-Host "=== MULTI-TIER INFRASTRUCTURE END-TO-END TESTS ===`n" -ForegroundColor Magenta
    Write-Host "Environment: $Environment"
    Write-Host "Stack Prefix: $StackNamePrefix"
    Write-Host "Region: $Region"
    Write-Host "Test Size: $TestSize"
    Write-Host "Include Failover Test: $IncludeFailoverTest"
    Write-Host "Cleanup After Test: $CleanupAfterTest"
    Write-Host "Started: $($script:TestResults.StartTime)"
    
    if ($IncludeFailoverTest) {
        Write-Host ""
        Write-Host "⚠️  WARNING: Failover testing enabled - this will terminate instances!" -ForegroundColor Red
    }
    
    Write-Host ""
    
    # Execute test phases
    $phases = @()
    
    # Phase 1: Infrastructure validation (always run)
    $infrastructureSuccess = Test-InfrastructurePhase
    $phases += @{ Name = "Infrastructure"; Success = $infrastructureSuccess }
    
    # Phase 2: Load balancer and reliability testing (always run)
    $loadBalancerSuccess = Test-LoadBalancerPhase
    $phases += @{ Name = "Load Balancer"; Success = $loadBalancerSuccess }
    
    # Phase 3: Database connectivity testing (always run)
    $databaseSuccess = Test-DatabasePhase
    $phases += @{ Name = "Database"; Success = $databaseSuccess }
    
    # Phase 4: Application workflow testing (skip for minimal)
    if ($TestSize -ne "minimal") {
        $workflowSuccess = Test-ApplicationWorkflowPhase
        $phases += @{ Name = "Application Workflow"; Success = $workflowSuccess }
    }
    
    # Phase 5: End-to-end reliability testing (standard and comprehensive)
    if ($TestSize -in @("standard", "comprehensive")) {
        $reliabilitySuccess = Test-ReliabilityPhase
        $phases += @{ Name = "Reliability"; Success = $reliabilitySuccess }
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
    $allPhasesSuccessful = $phases | Where-Object { !$_.Success } | Measure-Object | Select-Object -ExpandProperty Count
    
    # Determine overall result
    if ($script:TestResults.FailedTests -eq 0 -and $allPhasesSuccessful -eq 0) {
        Write-Host "🎉 All end-to-end tests passed! Multi-tier infrastructure is production-ready." -ForegroundColor Green
        return 0
    } elseif ($successRate -ge 75 -and $allPhasesSuccessful -le 1) {
        Write-Host "⚠️  Most tests passed ($successRate%). Review failed tests and consider re-running." -ForegroundColor Yellow
        return 1
    } else {
        Write-Host "❌ Many tests failed ($successRate%) or multiple phases failed. Infrastructure needs attention." -ForegroundColor Red
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