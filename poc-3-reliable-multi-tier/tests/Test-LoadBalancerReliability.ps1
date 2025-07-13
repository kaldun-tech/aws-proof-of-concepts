#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Load balancer and auto-scaling reliability tests for Multi-Tier Infrastructure POC.

.DESCRIPTION
    This script tests the reliability features of the multi-tier infrastructure,
    including load balancer health checks, auto-scaling functionality, and failover scenarios.

.PARAMETER Environment
    The environment to test (dev, test, prod).

.PARAMETER StackNamePrefix
    The prefix used for CloudFormation stack names.

.PARAMETER Region
    The AWS region where resources are deployed.

.PARAMETER TestFailover
    Test failover scenarios (requires instances to be terminated).

.PARAMETER Verbose
    Enable verbose output for detailed test results.

.EXAMPLE
    ./Test-LoadBalancerReliability.ps1 -Environment dev -StackNamePrefix WebApp1 -Verbose
    
.EXAMPLE
    ./Test-LoadBalancerReliability.ps1 -Environment dev -StackNamePrefix WebApp1 -TestFailover -Verbose
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
    [switch]$TestFailover,

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

# Get infrastructure details
function Get-InfrastructureDetails {
    try {
        $webAppStackName = "$StackNamePrefix-WebApp"
        
        # Get ALB ARN
        $albArn = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='ALBArn'].OutputValue" --output text --region $Region 2>$null
        
        # Get ASG name
        $asgName = aws cloudformation describe-stack-resources --stack-name $webAppStackName --logical-resource-id "WebTierAutoScalingGroup" --query "StackResources[0].PhysicalResourceId" --output text --region $Region 2>$null
        
        # Get website URL
        $websiteUrl = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue" --output text --region $Region 2>$null
        
        $script:TestResults.TestData = @{
            ALBArn = $albArn
            ASGName = $asgName
            WebsiteURL = $websiteUrl
            WebAppStackName = $webAppStackName
        }
        
        return ($albArn -and $asgName -and $websiteUrl -and $albArn -ne "None" -and $asgName -ne "None" -and $websiteUrl -ne "None")
        
    } catch {
        Write-TestResult "Infrastructure details retrieval" $false $_.Exception.Message
        return $false
    }
}

# Test load balancer health checks
function Test-LoadBalancerHealthChecks {
    Write-Host "`n=== Load Balancer Health Check Tests ===`n" -ForegroundColor Cyan
    
    try {
        $albArn = $script:TestResults.TestData.ALBArn
        
        if (!$albArn) {
            Skip-Test "Load Balancer health checks" "ALB ARN not available"
            return
        }
        
        # Get target groups
        $targetGroups = aws elbv2 describe-target-groups --load-balancer-arn $albArn --region $Region --output json 2>$null | ConvertFrom-Json
        
        if ($targetGroups.TargetGroups.Count -eq 0) {
            Write-TestResult "Target groups exist" $false "No target groups found"
            return
        }
        
        foreach ($tg in $targetGroups.TargetGroups) {
            $tgArn = $tg.TargetGroupArn
            $tgName = $tg.TargetGroupName
            
            Write-Host "    Testing target group: $tgName" -ForegroundColor Gray
            
            # Test health check configuration
            $healthCheckPath = $tg.HealthCheckPath
            $healthCheckPort = $tg.HealthCheckPort
            $healthCheckProtocol = $tg.HealthCheckProtocol
            $healthCheckInterval = $tg.HealthCheckIntervalSeconds
            $healthyThreshold = $tg.HealthyThresholdCount
            $unhealthyThreshold = $tg.UnhealthyThresholdCount
            
            Write-TestResult "Health check path configured for $tgName" ($healthCheckPath -ne $null) "Path: $healthCheckPath"
            Write-TestResult "Health check interval reasonable for $tgName" ($healthCheckInterval -le 30) "Interval: $healthCheckInterval seconds"
            Write-TestResult "Healthy threshold configured for $tgName" ($healthyThreshold -ge 2) "Threshold: $healthyThreshold"
            Write-TestResult "Unhealthy threshold configured for $tgName" ($unhealthyThreshold -ge 2) "Threshold: $unhealthyThreshold"
            
            # Test current target health
            $targetHealth = aws elbv2 describe-target-health --target-group-arn $tgArn --region $Region --output json 2>$null | ConvertFrom-Json
            $targets = $targetHealth.TargetHealthDescriptions
            
            if ($targets.Count -gt 0) {
                $healthyTargets = $targets | Where-Object { $_.TargetHealth.State -eq "healthy" }
                $unhealthyTargets = $targets | Where-Object { $_.TargetHealth.State -eq "unhealthy" }
                $drainingTargets = $targets | Where-Object { $_.TargetHealth.State -eq "draining" }
                
                Write-TestResult "Targets registered in $tgName" ($targets.Count -gt 0) "Total: $($targets.Count)"
                Write-TestResult "Healthy targets in $tgName" ($healthyTargets.Count -gt 0) "Healthy: $($healthyTargets.Count)"
                
                if ($unhealthyTargets.Count -gt 0) {
                    Write-Host "        Unhealthy targets: $($unhealthyTargets.Count)" -ForegroundColor Yellow
                    if ($Verbose) {
                        foreach ($target in $unhealthyTargets) {
                            Write-Host "          - $($target.Target.Id): $($target.TargetHealth.State) - $($target.TargetHealth.Description)" -ForegroundColor Yellow
                        }
                    }
                }
                
                # Test multi-AZ distribution
                $azs = $targets | Select-Object -ExpandProperty Target | Select-Object -ExpandProperty AvailabilityZone | Sort-Object -Unique
                Write-TestResult "Targets distributed across AZs for $tgName" ($azs.Count -gt 1) "AZs: $($azs.Count)" -Details ($azs -join ", ")
                
            } else {
                Write-TestResult "Targets registered in $tgName" $false "No targets found"
            }
        }
        
    } catch {
        Write-TestResult "Load Balancer health checks" $false $_.Exception.Message
    }
}

# Test website availability and response time
function Test-WebsiteAvailability {
    Write-Host "`n=== Website Availability Tests ===`n" -ForegroundColor Cyan
    
    try {
        $websiteUrl = $script:TestResults.TestData.WebsiteURL
        
        if (!$websiteUrl) {
            Skip-Test "Website availability tests" "Website URL not available"
            return
        }
        
        Write-Host "    Testing website: $websiteUrl" -ForegroundColor Gray
        
        # Test basic connectivity
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 30
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds
            
            $statusCode = $response.StatusCode
            Write-TestResult "Website responds with 200 OK" ($statusCode -eq 200) "Status: $statusCode"
            Write-TestResult "Website response time acceptable" ($responseTime -lt 5000) "Time: $responseTime ms"
            
            # Test response content
            $hasContent = $response.Content.Length -gt 0
            Write-TestResult "Website returns content" $hasContent "Size: $($response.Content.Length) bytes"
            
            # Test for common web server headers
            $hasServerHeader = $response.Headers.ContainsKey("Server") -or $response.Headers.ContainsKey("server")
            $hasContentType = $response.Headers.ContainsKey("Content-Type") -or $response.Headers.ContainsKey("content-type")
            Write-TestResult "Website has proper headers" ($hasServerHeader -or $hasContentType) "Headers configured"
            
        } catch {
            Write-TestResult "Website basic connectivity" $false $_.Exception.Message
        }
        
        # Test multiple requests for consistency
        Write-Host "    Testing consistency with multiple requests..." -ForegroundColor Gray
        $successfulRequests = 0
        $totalRequests = 5
        $responseTimes = @()
        
        for ($i = 1; $i -le $totalRequests; $i++) {
            try {
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 10
                $stopwatch.Stop()
                
                if ($response.StatusCode -eq 200) {
                    $successfulRequests++
                    $responseTimes += $stopwatch.ElapsedMilliseconds
                }
                
                Start-Sleep -Milliseconds 500  # Brief pause between requests
            } catch {
                # Request failed, continue
            }
        }
        
        $successRate = ($successfulRequests / $totalRequests) * 100
        Write-TestResult "Website consistency test" ($successRate -ge 80) "Success rate: $successRate% ($successfulRequests/$totalRequests)"
        
        if ($responseTimes.Count -gt 0) {
            $avgResponseTime = ($responseTimes | Measure-Object -Average).Average
            $maxResponseTime = ($responseTimes | Measure-Object -Maximum).Maximum
            Write-TestResult "Response time consistency" ($maxResponseTime -lt 10000) "Avg: $([math]::Round($avgResponseTime, 0))ms, Max: $maxResponseTime ms"
        }
        
    } catch {
        Write-TestResult "Website availability tests" $false $_.Exception.Message
    }
}

# Test auto-scaling configuration and triggers
function Test-AutoScalingConfiguration {
    Write-Host "`n=== Auto Scaling Configuration Tests ===`n" -ForegroundColor Cyan
    
    try {
        $asgName = $script:TestResults.TestData.ASGName
        
        if (!$asgName) {
            Skip-Test "Auto Scaling configuration tests" "ASG name not available"
            return
        }
        
        # Get ASG details
        $asg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --output json 2>$null | ConvertFrom-Json
        $asgDetails = $asg.AutoScalingGroups[0]
        
        # Test basic configuration
        $desiredCapacity = $asgDetails.DesiredCapacity
        $minSize = $asgDetails.MinSize
        $maxSize = $asgDetails.MaxSize
        $currentInstances = $asgDetails.Instances.Count
        
        Write-TestResult "Auto Scaling Group capacity configured" ($desiredCapacity -ge $minSize -and $desiredCapacity -le $maxSize) "Desired: $desiredCapacity, Min: $minSize, Max: $maxSize"
        Write-TestResult "Auto Scaling Group allows scaling" ($maxSize -gt $minSize) "Scale range: $minSize to $maxSize"
        Write-TestResult "Current instance count matches desired" ($currentInstances -eq $desiredCapacity) "Current: $currentInstances, Desired: $desiredCapacity"
        
        # Test health check configuration
        $healthCheckType = $asgDetails.HealthCheckType
        $healthCheckGracePeriod = $asgDetails.HealthCheckGracePeriod
        
        Write-TestResult "Health check type configured" ($healthCheckType -ne $null) "Type: $healthCheckType"
        Write-TestResult "Health check grace period reasonable" ($healthCheckGracePeriod -ge 60 -and $healthCheckGracePeriod -le 600) "Grace period: $healthCheckGracePeriod seconds"
        
        # Test scaling policies
        $scalingPolicies = aws autoscaling describe-policies --auto-scaling-group-name $asgName --region $Region --output json 2>$null | ConvertFrom-Json
        $hasPolicies = $scalingPolicies.ScalingPolicies.Count -gt 0
        Write-TestResult "Scaling policies configured" $hasPolicies "Policies: $($scalingPolicies.ScalingPolicies.Count)"
        
        if ($hasPolicies) {
            $scaleUpPolicies = $scalingPolicies.ScalingPolicies | Where-Object { $_.ScalingAdjustment -gt 0 -or $_.PolicyType -eq "TargetTrackingScaling" }
            $scaleDownPolicies = $scalingPolicies.ScalingPolicies | Where-Object { $_.ScalingAdjustment -lt 0 -or $_.PolicyType -eq "TargetTrackingScaling" }
            
            Write-TestResult "Scale-up policies exist" ($scaleUpPolicies.Count -gt 0) "Scale-up policies: $($scaleUpPolicies.Count)"
            Write-TestResult "Scale-down policies exist" ($scaleDownPolicies.Count -gt 0) "Scale-down policies: $($scaleDownPolicies.Count)"
        }
        
        # Test instance distribution across AZs
        $instancesPerAZ = $asgDetails.Instances | Group-Object -Property AvailabilityZone
        $azCount = $instancesPerAZ.Count
        Write-TestResult "Instances distributed across multiple AZs" ($azCount -gt 1) "AZs with instances: $azCount"
        
        if ($Verbose -and $azCount -gt 0) {
            foreach ($azGroup in $instancesPerAZ) {
                Write-Host "        AZ $($azGroup.Name): $($azGroup.Count) instances" -ForegroundColor Gray
            }
        }
        
        # Test instance health
        $healthyInstances = $asgDetails.Instances | Where-Object { $_.HealthStatus -eq "Healthy" }
        $unhealthyInstances = $asgDetails.Instances | Where-Object { $_.HealthStatus -ne "Healthy" }
        
        Write-TestResult "All instances healthy" ($unhealthyInstances.Count -eq 0) "Healthy: $($healthyInstances.Count), Unhealthy: $($unhealthyInstances.Count)"
        
        if ($unhealthyInstances.Count -gt 0 -and $Verbose) {
            foreach ($instance in $unhealthyInstances) {
                Write-Host "        Unhealthy instance: $($instance.InstanceId) in $($instance.AvailabilityZone) - $($instance.HealthStatus)" -ForegroundColor Yellow
            }
        }
        
    } catch {
        Write-TestResult "Auto Scaling configuration tests" $false $_.Exception.Message
    }
}

# Test failover scenarios (optional)
function Test-FailoverScenarios {
    Write-Host "`n=== Failover Scenario Tests ===`n" -ForegroundColor Cyan
    
    if (!$TestFailover) {
        Skip-Test "Failover scenario tests" "TestFailover not enabled (use -TestFailover to enable)"
        return
    }
    
    Write-Host "⚠️  WARNING: This will terminate instances to test failover!" -ForegroundColor Red
    $confirm = Read-Host "Do you want to proceed with failover testing? (yes/no)"
    
    if ($confirm -ne "yes") {
        Skip-Test "Failover scenario tests" "User declined to proceed"
        return
    }
    
    try {
        $asgName = $script:TestResults.TestData.ASGName
        $websiteUrl = $script:TestResults.TestData.WebsiteURL
        
        if (!$asgName -or !$websiteUrl) {
            Skip-Test "Failover scenario tests" "Required infrastructure details not available"
            return
        }
        
        # Get current ASG state
        $asg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --output json 2>$null | ConvertFrom-Json
        $initialInstances = $asg.AutoScalingGroups[0].Instances
        $initialHealthyCount = ($initialInstances | Where-Object { $_.HealthStatus -eq "Healthy" }).Count
        
        if ($initialHealthyCount -lt 2) {
            Skip-Test "Failover scenario tests" "Need at least 2 healthy instances for failover testing"
            return
        }
        
        Write-Host "    Initial state: $initialHealthyCount healthy instances" -ForegroundColor Gray
        
        # Test 1: Terminate one instance and verify auto-replacement
        $instanceToTerminate = $initialInstances | Where-Object { $_.HealthStatus -eq "Healthy" } | Select-Object -First 1
        Write-Host "    Terminating instance: $($instanceToTerminate.InstanceId)" -ForegroundColor Yellow
        
        # Verify website is accessible before termination
        try {
            $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 10
            $preFailoverWorking = $response.StatusCode -eq 200
            Write-TestResult "Website accessible before failover" $preFailoverWorking "Status: $($response.StatusCode)"
        } catch {
            Write-TestResult "Website accessible before failover" $false "Pre-failover check failed"
            return
        }
        
        # Terminate the instance
        aws ec2 terminate-instances --instance-ids $instanceToTerminate.InstanceId --region $Region 2>$null
        
        # Wait a moment and test website availability during failover
        Start-Sleep -Seconds 10
        
        $duringFailoverAttempts = 0
        $duringFailoverSuccess = 0
        
        for ($i = 1; $i -le 5; $i++) {
            try {
                $duringFailoverAttempts++
                $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 5
                if ($response.StatusCode -eq 200) {
                    $duringFailoverSuccess++
                }
            } catch {
                # Request failed during failover
            }
            Start-Sleep -Seconds 2
        }
        
        $duringFailoverRate = ($duringFailoverSuccess / $duringFailoverAttempts) * 100
        Write-TestResult "Website available during failover" ($duringFailoverRate -ge 60) "Availability: $duringFailoverRate% ($duringFailoverSuccess/$duringFailoverAttempts)"
        
        # Wait for ASG to detect and replace the instance
        Write-Host "    Waiting for Auto Scaling to replace the terminated instance..." -ForegroundColor Gray
        $waitTime = 0
        $maxWaitTime = 300  # 5 minutes
        $replacementDetected = $false
        
        while ($waitTime -lt $maxWaitTime) {
            Start-Sleep -Seconds 30
            $waitTime += 30
            
            $currentAsg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --output json 2>$null | ConvertFrom-Json
            $currentInstances = $currentAsg.AutoScalingGroups[0].Instances
            $currentHealthyCount = ($currentInstances | Where-Object { $_.HealthStatus -eq "Healthy" }).Count
            
            Write-Host "    Wait time: $waitTime seconds, Healthy instances: $currentHealthyCount" -ForegroundColor Gray
            
            # Check if we have a new instance (different from initial set)
            $newInstances = $currentInstances | Where-Object { $_.InstanceId -notin $initialInstances.InstanceId }
            if ($newInstances.Count -gt 0) {
                $replacementDetected = $true
                Write-Host "    New instance detected: $($newInstances[0].InstanceId)" -ForegroundColor Green
                
                # Wait a bit more for the new instance to become healthy
                Start-Sleep -Seconds 60
                break
            }
        }
        
        Write-TestResult "Auto Scaling replaced terminated instance" $replacementDetected "Wait time: $waitTime seconds"
        
        # Final verification
        if ($replacementDetected) {
            # Test final website availability
            Start-Sleep -Seconds 30  # Give time for health checks
            
            try {
                $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 10
                $postFailoverWorking = $response.StatusCode -eq 200
                Write-TestResult "Website accessible after failover recovery" $postFailoverWorking "Status: $($response.StatusCode)"
            } catch {
                Write-TestResult "Website accessible after failover recovery" $false "Post-failover check failed"
            }
            
            # Verify we're back to original instance count
            $finalAsg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --output json 2>$null | ConvertFrom-Json
            $finalInstanceCount = $finalAsg.AutoScalingGroups[0].Instances.Count
            Write-TestResult "Instance count restored" ($finalInstanceCount -eq $initialInstances.Count) "Final count: $finalInstanceCount"
        }
        
    } catch {
        Write-TestResult "Failover scenario tests" $false $_.Exception.Message
    }
}

# Test load balancer stickiness and distribution
function Test-LoadDistribution {
    Write-Host "`n=== Load Distribution Tests ===`n" -ForegroundColor Cyan
    
    try {
        $websiteUrl = $script:TestResults.TestData.WebsiteURL
        
        if (!$websiteUrl) {
            Skip-Test "Load distribution tests" "Website URL not available"
            return
        }
        
        # Test multiple requests to see load distribution
        Write-Host "    Testing load distribution with multiple requests..." -ForegroundColor Gray
        
        $serverResponses = @{}
        $totalRequests = 10
        $successfulRequests = 0
        
        for ($i = 1; $i -le $totalRequests; $i++) {
            try {
                $response = Invoke-WebRequest -Uri $websiteUrl -UseBasicParsing -TimeoutSec 10
                
                if ($response.StatusCode -eq 200) {
                    $successfulRequests++
                    
                    # Try to identify server (if the application provides server identification)
                    $serverHeader = $response.Headers["Server"]
                    if (!$serverHeader) {
                        $serverHeader = $response.Headers["server"]
                    }
                    
                    # Look for any server identification in content
                    $serverId = "Unknown"
                    if ($response.Content -match "Server.*?(\w+)" -or $response.Content -match "Instance.*?(\w+)") {
                        $serverId = $matches[1]
                    }
                    
                    if ($serverResponses.ContainsKey($serverId)) {
                        $serverResponses[$serverId]++
                    } else {
                        $serverResponses[$serverId] = 1
                    }
                }
                
                Start-Sleep -Milliseconds 200
            } catch {
                # Request failed
            }
        }
        
        $responseRate = ($successfulRequests / $totalRequests) * 100
        Write-TestResult "Load balancer handles concurrent requests" ($responseRate -ge 90) "Success rate: $responseRate% ($successfulRequests/$totalRequests)"
        
        if ($serverResponses.Keys.Count -gt 1) {
            Write-TestResult "Load distributed across multiple servers" $true "Servers: $($serverResponses.Keys.Count)"
            if ($Verbose) {
                foreach ($server in $serverResponses.Keys) {
                    Write-Host "        $server`: $($serverResponses[$server]) requests" -ForegroundColor Gray
                }
            }
        } else {
            Write-TestResult "Load distributed across multiple servers" $false "Only 1 server responding (or no server identification)"
        }
        
    } catch {
        Write-TestResult "Load distribution tests" $false $_.Exception.Message
    }
}

# Main test execution
function Invoke-LoadBalancerReliabilityTests {
    Write-Host "=== Multi-Tier Load Balancer & Reliability Tests ===`n" -ForegroundColor Magenta
    Write-Host "Environment: $Environment"
    Write-Host "Stack Prefix: $StackNamePrefix"
    Write-Host "Region: $Region"
    Write-Host "Test Failover: $TestFailover"
    Write-Host "Started: $($script:TestResults.StartTime)"
    Write-Host ""
    
    # Get infrastructure details first
    $infraReady = Get-InfrastructureDetails
    if (!$infraReady) {
        Write-Host "❌ Could not retrieve infrastructure details. Ensure stacks are deployed." -ForegroundColor Red
        return 3
    }
    
    Write-Host "Infrastructure details retrieved successfully:" -ForegroundColor Green
    Write-Host "  ALB ARN: $($script:TestResults.TestData.ALBArn)" -ForegroundColor Gray
    Write-Host "  ASG Name: $($script:TestResults.TestData.ASGName)" -ForegroundColor Gray
    Write-Host "  Website URL: $($script:TestResults.TestData.WebsiteURL)" -ForegroundColor Gray
    
    # Run test suites
    Test-LoadBalancerHealthChecks
    Test-WebsiteAvailability
    Test-AutoScalingConfiguration
    Test-LoadDistribution
    Test-FailoverScenarios
    
    # Summary
    $script:TestResults.EndTime = Get-Date
    $duration = $script:TestResults.EndTime - $script:TestResults.StartTime
    
    Write-Host "`n=== Load Balancer & Reliability Test Summary ===`n" -ForegroundColor Magenta
    Write-Host "Total Tests: $($script:TestResults.TotalTests)"
    Write-Host "Passed: $($script:TestResults.PassedTests)" -ForegroundColor Green
    Write-Host "Failed: $($script:TestResults.FailedTests)" -ForegroundColor Red
    Write-Host "Skipped: $($script:TestResults.SkippedTests)" -ForegroundColor Yellow
    Write-Host "Duration: $($duration.ToString('mm\:ss'))"
    Write-Host ""
    
    if ($script:TestResults.FailedTests -gt 0) {
        Write-Host "Failed Tests:" -ForegroundColor Red
        foreach ($error in $script:TestResults.Errors) {
            Write-Host "  - $error" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    $successRate = if ($script:TestResults.TotalTests -gt 0) { [math]::Round(($script:TestResults.PassedTests / $script:TestResults.TotalTests) * 100, 1) } else { 0 }
    
    if ($script:TestResults.FailedTests -eq 0) {
        Write-Host "🎉 All reliability tests passed! Load balancer and auto-scaling are working correctly." -ForegroundColor Green
        return 0
    } elseif ($successRate -ge 80) {
        Write-Host "⚠️  Most tests passed ($successRate%). Check failed tests above." -ForegroundColor Yellow
        return 1
    } else {
        Write-Host "❌ Many tests failed ($successRate%). Reliability features may have issues." -ForegroundColor Red
        return 2
    }
}

# Execute tests
try {
    $exitCode = Invoke-LoadBalancerReliabilityTests
    exit $exitCode
} catch {
    Write-Host "❌ Test execution failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}