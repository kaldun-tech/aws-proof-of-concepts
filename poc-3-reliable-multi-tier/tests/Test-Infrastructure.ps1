#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Infrastructure validation tests for Multi-Tier Reliable Infrastructure POC.

.DESCRIPTION
    This script validates that all CloudFormation stacks and AWS resources
    are properly deployed and configured for the multi-tier web application.

.PARAMETER Environment
    The environment to test (dev, test, prod).

.PARAMETER StackNamePrefix
    The prefix used for CloudFormation stack names.

.PARAMETER Region
    The AWS region where resources are deployed.

.PARAMETER Verbose
    Enable verbose output for detailed test results.

.EXAMPLE
    ./Test-Infrastructure.ps1 -Environment dev -StackNamePrefix WebApp1 -Verbose
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

# Test CloudFormation stack existence and status
function Test-CloudFormationStacks {
    Write-Host "`n=== CloudFormation Stack Tests ===`n" -ForegroundColor Cyan
    
    $vpcStackName = "$StackNamePrefix-VPC"
    $webAppStackName = "$StackNamePrefix-WebApp"
    
    try {
        $stacks = aws cloudformation describe-stacks --region $Region --output json | ConvertFrom-Json
        $deployedStacks = $stacks.Stacks | Where-Object { $_.StackName -like "$StackNamePrefix*" }
        
        # Test VPC stack exists
        $vpcStack = $deployedStacks | Where-Object { $_.StackName -eq $vpcStackName }
        if ($vpcStack) {
            $status = $vpcStack.StackStatus
            Write-TestResult "VPC CloudFormation stack exists" ($status -like "*COMPLETE*") "Status: $status"
        } else {
            Write-TestResult "VPC CloudFormation stack exists" $false "Stack $vpcStackName not found"
        }
        
        # Test WebApp stack exists
        $webAppStack = $deployedStacks | Where-Object { $_.StackName -eq $webAppStackName }
        if ($webAppStack) {
            $status = $webAppStack.StackStatus
            Write-TestResult "WebApp CloudFormation stack exists" ($status -like "*COMPLETE*") "Status: $status"
        } else {
            Write-TestResult "WebApp CloudFormation stack exists" $false "Stack $webAppStackName not found"
        }
        
        # Test stack outputs are available
        if ($webAppStack) {
            $hasOutputs = $webAppStack.Outputs -and $webAppStack.Outputs.Count -gt 0
            Write-TestResult "WebApp stack has outputs" $hasOutputs "Outputs: $($webAppStack.Outputs.Count)"
            
            if ($hasOutputs) {
                $websiteUrlOutput = $webAppStack.Outputs | Where-Object { $_.OutputKey -eq "WebsiteURL" }
                Write-TestResult "WebApp stack has WebsiteURL output" ($websiteUrlOutput -ne $null) "URL: $($websiteUrlOutput.OutputValue)"
            }
        }
        
    } catch {
        Write-TestResult "CloudFormation stacks accessible" $false $_.Exception.Message
    }
}

# Test VPC configuration
function Test-VPCConfiguration {
    Write-Host "`n=== VPC Configuration Tests ===`n" -ForegroundColor Cyan
    
    try {
        # Get VPC ID from stack output
        $vpcStackName = "$StackNamePrefix-VPC"
        $vpcId = aws cloudformation describe-stacks --stack-name $vpcStackName --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" --output text --region $Region 2>$null
        
        if ($vpcId -and $vpcId -ne "None") {
            Write-TestResult "VPC ID retrieved from stack" $true "VPC: $vpcId"
            
            # Test VPC exists and is available
            try {
                $vpc = aws ec2 describe-vpcs --vpc-ids $vpcId --region $Region --output json 2>$null | ConvertFrom-Json
                $vpcState = $vpc.Vpcs[0].State
                Write-TestResult "VPC is available" ($vpcState -eq "available") "State: $vpcState"
                
                # Test VPC has proper CIDR
                $cidrBlock = $vpc.Vpcs[0].CidrBlock
                Write-TestResult "VPC has CIDR block" ($cidrBlock -ne $null) "CIDR: $cidrBlock"
                
            } catch {
                Write-TestResult "VPC is accessible" $false $_.Exception.Message
            }
            
            # Test subnets exist
            try {
                $subnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --region $Region --output json 2>$null | ConvertFrom-Json
                $subnetCount = $subnets.Subnets.Count
                Write-TestResult "VPC has subnets" ($subnetCount -gt 0) "Subnets: $subnetCount"
                
                if ($subnetCount -gt 0) {
                    # Test for multi-AZ deployment
                    $azs = $subnets.Subnets | Select-Object -ExpandProperty AvailabilityZone | Sort-Object -Unique
                    $multiAZ = $azs.Count -gt 1
                    Write-TestResult "Multi-AZ deployment" $multiAZ "AZs: $($azs.Count)" -Details ($azs -join ", ")
                    
                    # Test for public and private subnets
                    $publicSubnets = $subnets.Subnets | Where-Object { $_.MapPublicIpOnLaunch -eq $true }
                    $privateSubnets = $subnets.Subnets | Where-Object { $_.MapPublicIpOnLaunch -eq $false }
                    
                    Write-TestResult "Public subnets exist" ($publicSubnets.Count -gt 0) "Public: $($publicSubnets.Count)"
                    Write-TestResult "Private subnets exist" ($privateSubnets.Count -gt 0) "Private: $($privateSubnets.Count)"
                }
                
            } catch {
                Write-TestResult "VPC subnets accessible" $false $_.Exception.Message
            }
            
            # Test internet gateway
            try {
                $igws = aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId" --region $Region --output json 2>$null | ConvertFrom-Json
                $hasIGW = $igws.InternetGateways.Count -gt 0
                Write-TestResult "Internet Gateway attached" $hasIGW "IGWs: $($igws.InternetGateways.Count)"
            } catch {
                Write-TestResult "Internet Gateway check" $false $_.Exception.Message
            }
            
            # Test NAT gateways
            try {
                $natGateways = aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId" --region $Region --output json 2>$null | ConvertFrom-Json
                $hasNAT = $natGateways.NatGateways.Count -gt 0
                Write-TestResult "NAT Gateways exist" $hasNAT "NAT GWs: $($natGateways.NatGateways.Count)"
                
                if ($hasNAT) {
                    $availableNATs = $natGateways.NatGateways | Where-Object { $_.State -eq "available" }
                    Write-TestResult "NAT Gateways available" ($availableNATs.Count -eq $natGateways.NatGateways.Count) "Available: $($availableNATs.Count)"
                }
            } catch {
                Write-TestResult "NAT Gateway check" $false $_.Exception.Message
            }
            
        } else {
            Write-TestResult "VPC ID retrieved from stack" $false "Could not get VPC ID from stack"
        }
        
    } catch {
        Write-TestResult "VPC configuration tests" $false $_.Exception.Message
    }
}

# Test Load Balancer configuration
function Test-LoadBalancerConfiguration {
    Write-Host "`n=== Load Balancer Configuration Tests ===`n" -ForegroundColor Cyan
    
    try {
        # Get ALB ARN from stack output
        $webAppStackName = "$StackNamePrefix-WebApp"
        $albArn = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='ALBArn'].OutputValue" --output text --region $Region 2>$null
        
        if ($albArn -and $albArn -ne "None") {
            Write-TestResult "Load Balancer ARN retrieved" $true "ALB: $albArn"
            
            # Test ALB state
            try {
                $alb = aws elbv2 describe-load-balancers --load-balancer-arns $albArn --region $Region --output json 2>$null | ConvertFrom-Json
                $albState = $alb.LoadBalancers[0].State.Code
                Write-TestResult "Load Balancer is active" ($albState -eq "active") "State: $albState"
                
                # Test ALB scheme and type
                $scheme = $alb.LoadBalancers[0].Scheme
                $type = $alb.LoadBalancers[0].Type
                Write-TestResult "Load Balancer is internet-facing" ($scheme -eq "internet-facing") "Scheme: $scheme"
                Write-TestResult "Load Balancer is application type" ($type -eq "application") "Type: $type"
                
                # Test ALB subnets (multi-AZ)
                $subnetCount = $alb.LoadBalancers[0].AvailabilityZones.Count
                Write-TestResult "Load Balancer spans multiple AZs" ($subnetCount -gt 1) "AZs: $subnetCount"
                
            } catch {
                Write-TestResult "Load Balancer accessible" $false $_.Exception.Message
            }
            
            # Test target groups
            try {
                $targetGroups = aws elbv2 describe-target-groups --load-balancer-arn $albArn --region $Region --output json 2>$null | ConvertFrom-Json
                $hasTargetGroups = $targetGroups.TargetGroups.Count -gt 0
                Write-TestResult "Target groups configured" $hasTargetGroups "Groups: $($targetGroups.TargetGroups.Count)"
                
                if ($hasTargetGroups) {
                    foreach ($tg in $targetGroups.TargetGroups) {
                        $tgArn = $tg.TargetGroupArn
                        $tgName = $tg.TargetGroupName
                        
                        # Test target health
                        $targetHealth = aws elbv2 describe-target-health --target-group-arn $tgArn --region $Region --output json 2>$null | ConvertFrom-Json
                        $healthyTargets = $targetHealth.TargetHealthDescriptions | Where-Object { $_.TargetHealth.State -eq "healthy" }
                        $totalTargets = $targetHealth.TargetHealthDescriptions.Count
                        
                        Write-TestResult "Target group '$tgName' has healthy targets" ($healthyTargets.Count -gt 0) "Healthy: $($healthyTargets.Count)/$totalTargets"
                    }
                }
                
            } catch {
                Write-TestResult "Target groups check" $false $_.Exception.Message
            }
            
            # Test listeners
            try {
                $listeners = aws elbv2 describe-listeners --load-balancer-arn $albArn --region $Region --output json 2>$null | ConvertFrom-Json
                $hasListeners = $listeners.Listeners.Count -gt 0
                Write-TestResult "Load Balancer has listeners" $hasListeners "Listeners: $($listeners.Listeners.Count)"
                
                if ($hasListeners) {
                    $httpListener = $listeners.Listeners | Where-Object { $_.Port -eq 80 -and $_.Protocol -eq "HTTP" }
                    Write-TestResult "HTTP listener configured" ($httpListener -ne $null) "Port 80 HTTP"
                }
            } catch {
                Write-TestResult "Load Balancer listeners check" $false $_.Exception.Message
            }
            
        } else {
            Write-TestResult "Load Balancer ARN retrieved" $false "Could not get ALB ARN from stack"
        }
        
    } catch {
        Write-TestResult "Load Balancer configuration tests" $false $_.Exception.Message
    }
}

# Test Auto Scaling Group configuration
function Test-AutoScalingConfiguration {
    Write-Host "`n=== Auto Scaling Configuration Tests ===`n" -ForegroundColor Cyan
    
    try {
        # Get ASG name from stack resources
        $webAppStackName = "$StackNamePrefix-WebApp"
        $asgName = aws cloudformation describe-stack-resources --stack-name $webAppStackName --logical-resource-id "WebTierAutoScalingGroup" --query "StackResources[0].PhysicalResourceId" --output text --region $Region 2>$null
        
        if ($asgName -and $asgName -ne "None") {
            Write-TestResult "Auto Scaling Group name retrieved" $true "ASG: $asgName"
            
            # Test ASG configuration
            try {
                $asg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --output json 2>$null | ConvertFrom-Json
                $asgDetails = $asg.AutoScalingGroups[0]
                
                $desiredCapacity = $asgDetails.DesiredCapacity
                $minSize = $asgDetails.MinSize
                $maxSize = $asgDetails.MaxSize
                $currentInstances = $asgDetails.Instances.Count
                
                Write-TestResult "Auto Scaling Group is configured" ($asgDetails -ne $null) "Desired: $desiredCapacity, Min: $minSize, Max: $maxSize"
                Write-TestResult "Auto Scaling Group has instances" ($currentInstances -gt 0) "Instances: $currentInstances"
                
                # Test instance health
                $healthyInstances = $asgDetails.Instances | Where-Object { $_.HealthStatus -eq "Healthy" -and $_.LifecycleState -eq "InService" }
                Write-TestResult "Auto Scaling Group has healthy instances" ($healthyInstances.Count -gt 0) "Healthy: $($healthyInstances.Count)/$currentInstances"
                
                # Test multi-AZ deployment
                $azs = $asgDetails.AvailabilityZones
                Write-TestResult "Auto Scaling Group spans multiple AZs" ($azs.Count -gt 1) "AZs: $($azs.Count)" -Details ($azs -join ", ")
                
                # Test subnets
                $subnetCount = $asgDetails.VPCZoneIdentifier.Split(",").Count
                Write-TestResult "Auto Scaling Group uses multiple subnets" ($subnetCount -gt 1) "Subnets: $subnetCount"
                
            } catch {
                Write-TestResult "Auto Scaling Group details accessible" $false $_.Exception.Message
            }
            
            # Test launch template/configuration
            try {
                if ($asgDetails.LaunchTemplate) {
                    $ltId = $asgDetails.LaunchTemplate.LaunchTemplateId
                    $ltVersion = $asgDetails.LaunchTemplate.Version
                    Write-TestResult "Launch Template configured" $true "ID: $ltId, Version: $ltVersion"
                    
                    # Test launch template details
                    $lt = aws ec2 describe-launch-template-versions --launch-template-id $ltId --versions $ltVersion --region $Region --output json 2>$null | ConvertFrom-Json
                    $ltData = $lt.LaunchTemplateVersions[0].LaunchTemplateData
                    
                    Write-TestResult "Launch Template has instance type" ($ltData.InstanceType -ne $null) "Type: $($ltData.InstanceType)"
                    Write-TestResult "Launch Template has AMI" ($ltData.ImageId -ne $null) "AMI: $($ltData.ImageId)"
                    Write-TestResult "Launch Template has security groups" ($ltData.SecurityGroupIds.Count -gt 0) "SGs: $($ltData.SecurityGroupIds.Count)"
                    
                } elseif ($asgDetails.LaunchConfigurationName) {
                    $lcName = $asgDetails.LaunchConfigurationName
                    Write-TestResult "Launch Configuration configured" $true "LC: $lcName"
                }
                
            } catch {
                Write-TestResult "Launch Template/Configuration check" $false $_.Exception.Message
            }
            
        } else {
            Write-TestResult "Auto Scaling Group name retrieved" $false "Could not get ASG name from stack"
        }
        
    } catch {
        Write-TestResult "Auto Scaling configuration tests" $false $_.Exception.Message
    }
}

# Test DynamoDB configuration
function Test-DynamoDBConfiguration {
    Write-Host "`n=== DynamoDB Configuration Tests ===`n" -ForegroundColor Cyan
    
    try {
        # Get DynamoDB table name from stack output
        $webAppStackName = "$StackNamePrefix-WebApp"
        $tableName = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='DynamoDBTable'].OutputValue" --output text --region $Region 2>$null
        
        if ($tableName -and $tableName -ne "None") {
            Write-TestResult "DynamoDB table name retrieved" $true "Table: $tableName"
            
            # Test table exists and is active
            try {
                $table = aws dynamodb describe-table --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
                $tableStatus = $table.Table.TableStatus
                Write-TestResult "DynamoDB table is active" ($tableStatus -eq "ACTIVE") "Status: $tableStatus"
                
                # Test table configuration
                $itemCount = $table.Table.ItemCount
                $tableSize = $table.Table.TableSizeBytes
                Write-TestResult "DynamoDB table accessible" $true "Items: $itemCount, Size: $([math]::Round($tableSize / 1KB, 1)) KB"
                
                # Test billing mode
                $billingMode = $table.Table.BillingModeSummary.BillingMode
                Write-TestResult "DynamoDB billing mode configured" ($billingMode -ne $null) "Mode: $billingMode"
                
                # Test key schema
                $keySchema = $table.Table.KeySchema
                $hasKeys = $keySchema.Count -gt 0
                Write-TestResult "DynamoDB key schema configured" $hasKeys "Keys: $($keySchema.Count)"
                
            } catch {
                Write-TestResult "DynamoDB table accessible" $false $_.Exception.Message
            }
            
        } else {
            Write-TestResult "DynamoDB table name retrieved" $false "Could not get table name from stack"
        }
        
    } catch {
        Write-TestResult "DynamoDB configuration tests" $false $_.Exception.Message
    }
}

# Test Security Groups configuration
function Test-SecurityGroupsConfiguration {
    Write-Host "`n=== Security Groups Configuration Tests ===`n" -ForegroundColor Cyan
    
    try {
        # Get VPC ID
        $vpcStackName = "$StackNamePrefix-VPC"
        $vpcId = aws cloudformation describe-stacks --stack-name $vpcStackName --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" --output text --region $Region 2>$null
        
        if ($vpcId -and $vpcId -ne "None") {
            # Get security groups for this VPC
            $securityGroups = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpcId" --region $Region --output json 2>$null | ConvertFrom-Json
            $customSGs = $securityGroups.SecurityGroups | Where-Object { $_.GroupName -ne "default" }
            
            Write-TestResult "Custom security groups exist" ($customSGs.Count -gt 0) "Groups: $($customSGs.Count)"
            
            if ($customSGs.Count -gt 0) {
                # Test for ALB security group
                $albSG = $customSGs | Where-Object { $_.GroupName -like "*ALB*" -or $_.GroupName -like "*LoadBalancer*" }
                Write-TestResult "ALB security group exists" ($albSG -ne $null) "ALB SG found"
                
                if ($albSG) {
                    # Test ALB SG allows HTTP
                    $httpRule = $albSG.IpPermissions | Where-Object { $_.FromPort -eq 80 -and $_.ToPort -eq 80 }
                    Write-TestResult "ALB security group allows HTTP" ($httpRule -ne $null) "Port 80 open"
                }
                
                # Test for Web/App security group
                $webSG = $customSGs | Where-Object { $_.GroupName -like "*Web*" -or $_.GroupName -like "*App*" }
                Write-TestResult "Web/App security group exists" ($webSG -ne $null) "Web SG found"
                
                if ($webSG) {
                    # Test Web SG allows traffic from ALB
                    $albSourceRule = $webSG.IpPermissions | Where-Object { 
                        $_.UserIdGroupPairs | Where-Object { $_.GroupId -eq $albSG.GroupId }
                    }
                    Write-TestResult "Web security group allows ALB traffic" ($albSourceRule -ne $null) "ALB to Web configured"
                }
            }
            
        } else {
            Skip-Test "Security Groups configuration" "Could not get VPC ID"
        }
        
    } catch {
        Write-TestResult "Security Groups configuration tests" $false $_.Exception.Message
    }
}

# Test VPC Flow Logs
function Test-VPCFlowLogs {
    Write-Host "`n=== VPC Flow Logs Tests ===`n" -ForegroundColor Cyan
    
    try {
        # Get VPC ID
        $vpcStackName = "$StackNamePrefix-VPC"
        $vpcId = aws cloudformation describe-stacks --stack-name $vpcStackName --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" --output text --region $Region 2>$null
        
        if ($vpcId -and $vpcId -ne "None") {
            # Check for VPC Flow Logs
            $flowLogs = aws ec2 describe-flow-logs --filter "Name=resource-id,Values=$vpcId" --region $Region --output json 2>$null | ConvertFrom-Json
            $hasFlowLogs = $flowLogs.FlowLogs.Count -gt 0
            Write-TestResult "VPC Flow Logs configured" $hasFlowLogs "Logs: $($flowLogs.FlowLogs.Count)"
            
            if ($hasFlowLogs) {
                $activeFlowLogs = $flowLogs.FlowLogs | Where-Object { $_.FlowLogStatus -eq "ACTIVE" }
                Write-TestResult "VPC Flow Logs are active" ($activeFlowLogs.Count -gt 0) "Active: $($activeFlowLogs.Count)"
                
                # Test log destination
                $cloudWatchLogs = $flowLogs.FlowLogs | Where-Object { $_.LogDestinationType -eq "cloud-watch-logs" }
                $s3Logs = $flowLogs.FlowLogs | Where-Object { $_.LogDestinationType -eq "s3" }
                
                Write-TestResult "Flow Logs destination configured" (($cloudWatchLogs.Count + $s3Logs.Count) -gt 0) "CloudWatch: $($cloudWatchLogs.Count), S3: $($s3Logs.Count)"
            }
            
        } else {
            Skip-Test "VPC Flow Logs" "Could not get VPC ID"
        }
        
    } catch {
        Write-TestResult "VPC Flow Logs tests" $false $_.Exception.Message
    }
}

# Main test execution
function Invoke-InfrastructureTests {
    Write-Host "=== Multi-Tier Infrastructure Tests ===`n" -ForegroundColor Magenta
    Write-Host "Environment: $Environment"
    Write-Host "Stack Prefix: $StackNamePrefix"
    Write-Host "Region: $Region"
    Write-Host "Started: $($script:TestResults.StartTime)"
    Write-Host ""
    
    # Run all test suites
    Test-CloudFormationStacks
    Test-VPCConfiguration
    Test-LoadBalancerConfiguration
    Test-AutoScalingConfiguration
    Test-DynamoDBConfiguration
    Test-SecurityGroupsConfiguration
    Test-VPCFlowLogs
    
    # Summary
    $script:TestResults.EndTime = Get-Date
    $duration = $script:TestResults.EndTime - $script:TestResults.StartTime
    
    Write-Host "`n=== Test Summary ===`n" -ForegroundColor Magenta
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
        Write-Host "🎉 All tests passed! Multi-tier infrastructure is properly configured." -ForegroundColor Green
        return 0
    } elseif ($successRate -ge 80) {
        Write-Host "⚠️  Most tests passed ($successRate%). Check failed tests above." -ForegroundColor Yellow
        return 1
    } else {
        Write-Host "❌ Many tests failed ($successRate%). Infrastructure may have issues." -ForegroundColor Red
        return 2
    }
}

# Execute tests
try {
    $exitCode = Invoke-InfrastructureTests
    exit $exitCode
} catch {
    Write-Host "❌ Test execution failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}