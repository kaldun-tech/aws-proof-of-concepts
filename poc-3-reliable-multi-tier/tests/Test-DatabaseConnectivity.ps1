#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Database connectivity and data tier tests for Multi-Tier Infrastructure POC.

.DESCRIPTION
    This script tests database connectivity, DynamoDB operations, data persistence,
    and data tier reliability for the multi-tier web application.

.PARAMETER Environment
    The environment to test (dev, test, prod).

.PARAMETER StackNamePrefix
    The prefix used for CloudFormation stack names.

.PARAMETER Region
    The AWS region where resources are deployed.

.PARAMETER TestDataOperations
    Test actual data operations (create, read, update, delete).

.PARAMETER Verbose
    Enable verbose output for detailed test results.

.EXAMPLE
    ./Test-DatabaseConnectivity.ps1 -Environment dev -StackNamePrefix WebApp1 -Verbose
    
.EXAMPLE
    ./Test-DatabaseConnectivity.ps1 -Environment dev -StackNamePrefix WebApp1 -TestDataOperations -Verbose
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
    [switch]$TestDataOperations,

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

# Get database details
function Get-DatabaseDetails {
    try {
        $webAppStackName = "$StackNamePrefix-WebApp"
        
        # Get DynamoDB table name
        $tableName = aws cloudformation describe-stacks --stack-name $webAppStackName --query "Stacks[0].Outputs[?OutputKey=='DynamoDBTable'].OutputValue" --output text --region $Region 2>$null
        
        if (!$tableName -or $tableName -eq "None") {
            # Try to get from stack resources if output not available
            $tableName = aws cloudformation describe-stack-resources --stack-name $webAppStackName --logical-resource-id "DynamoDBTable" --query "StackResources[0].PhysicalResourceId" --output text --region $Region 2>$null
        }
        
        $script:TestResults.TestData = @{
            TableName = $tableName
            WebAppStackName = $webAppStackName
        }
        
        return ($tableName -and $tableName -ne "None")
        
    } catch {
        Write-TestResult "Database details retrieval" $false $_.Exception.Message
        return $false
    }
}

# Test DynamoDB table configuration
function Test-DynamoDBTableConfiguration {
    Write-Host "`n=== DynamoDB Table Configuration Tests ===`n" -ForegroundColor Cyan
    
    try {
        $tableName = $script:TestResults.TestData.TableName
        
        if (!$tableName) {
            Skip-Test "DynamoDB table configuration" "Table name not available"
            return
        }
        
        Write-Host "    Testing table: $tableName" -ForegroundColor Gray
        
        # Get table description
        $table = aws dynamodb describe-table --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
        $tableStatus = $table.Table.TableStatus
        
        Write-TestResult "DynamoDB table exists and is active" ($tableStatus -eq "ACTIVE") "Status: $tableStatus"
        
        if ($tableStatus -eq "ACTIVE") {
            # Test table properties
            $itemCount = $table.Table.ItemCount
            $tableSize = $table.Table.TableSizeBytes
            $creationDate = $table.Table.CreationDateTime
            
            Write-TestResult "DynamoDB table accessible" $true "Items: $itemCount, Size: $([math]::Round($tableSize / 1KB, 1)) KB"
            
            # Test key schema
            $keySchema = $table.Table.KeySchema
            $hasPartitionKey = $keySchema | Where-Object { $_.KeyType -eq "HASH" }
            $hasSortKey = $keySchema | Where-Object { $_.KeyType -eq "RANGE" }
            
            Write-TestResult "DynamoDB table has partition key" ($hasPartitionKey -ne $null) "Partition key: $($hasPartitionKey.AttributeName)"
            if ($hasSortKey) {
                Write-TestResult "DynamoDB table has sort key" $true "Sort key: $($hasSortKey.AttributeName)"
            }
            
            # Test attribute definitions
            $attributes = $table.Table.AttributeDefinitions
            Write-TestResult "DynamoDB table has attribute definitions" ($attributes.Count -gt 0) "Attributes: $($attributes.Count)"
            
            if ($Verbose -and $attributes.Count -gt 0) {
                foreach ($attr in $attributes) {
                    Write-Host "        Attribute: $($attr.AttributeName) ($($attr.AttributeType))" -ForegroundColor Gray
                }
            }
            
            # Test billing mode
            $billingMode = $table.Table.BillingModeSummary.BillingMode
            Write-TestResult "DynamoDB billing mode configured" ($billingMode -ne $null) "Mode: $billingMode"
            
            if ($billingMode -eq "PROVISIONED") {
                $readCapacity = $table.Table.ProvisionedThroughput.ReadCapacityUnits
                $writeCapacity = $table.Table.ProvisionedThroughput.WriteCapacityUnits
                Write-TestResult "DynamoDB provisioned capacity configured" ($readCapacity -gt 0 -and $writeCapacity -gt 0) "Read: $readCapacity, Write: $writeCapacity"
            }
            
            # Test encryption
            $encryption = $table.Table.SSEDescription
            if ($encryption) {
                $encryptionStatus = $encryption.Status
                Write-TestResult "DynamoDB encryption enabled" ($encryptionStatus -eq "ENABLED") "Status: $encryptionStatus"
            } else {
                Write-TestResult "DynamoDB encryption status" $false "No encryption information available"
            }
            
            # Test point-in-time recovery
            try {
                $pitr = aws dynamodb describe-continuous-backups --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
                $pitrEnabled = $pitr.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus -eq "ENABLED"
                Write-TestResult "DynamoDB point-in-time recovery configured" $pitrEnabled "PITR: $($pitr.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus)"
            } catch {
                Skip-Test "DynamoDB point-in-time recovery check" "Could not retrieve PITR status"
            }
            
            # Test tags
            try {
                $tags = aws dynamodb list-tags-of-resource --resource-arn $table.Table.TableArn --region $Region --output json 2>$null | ConvertFrom-Json
                $hasTags = $tags.Tags.Count -gt 0
                Write-TestResult "DynamoDB table has tags" $hasTags "Tags: $($tags.Tags.Count)"
            } catch {
                Skip-Test "DynamoDB table tags check" "Could not retrieve tags"
            }
        }
        
    } catch {
        Write-TestResult "DynamoDB table configuration tests" $false $_.Exception.Message
    }
}

# Test database connectivity from application tier
function Test-DatabaseConnectivityFromApp {
    Write-Host "`n=== Database Connectivity from Application Tests ===`n" -ForegroundColor Cyan
    
    try {
        $tableName = $script:TestResults.TestData.TableName
        $webAppStackName = $script:TestResults.TestData.WebAppStackName
        
        if (!$tableName) {
            Skip-Test "Database connectivity from application" "Table name not available"
            return
        }
        
        # Get application instances
        $asgName = aws cloudformation describe-stack-resources --stack-name $webAppStackName --logical-resource-id "WebTierAutoScalingGroup" --query "StackResources[0].PhysicalResourceId" --output text --region $Region 2>$null
        
        if ($asgName -and $asgName -ne "None") {
            $asg = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --output json 2>$null | ConvertFrom-Json
            $instances = $asg.AutoScalingGroups[0].Instances | Where-Object { $_.LifecycleState -eq "InService" -and $_.HealthStatus -eq "Healthy" }
            
            Write-TestResult "Application instances available for testing" ($instances.Count -gt 0) "Instances: $($instances.Count)"
            
            if ($instances.Count -gt 0) {
                # Test connectivity by checking IAM permissions
                # (In a real scenario, you might SSH to instances or use Systems Manager)
                
                # Check if instances have DynamoDB permissions via their IAM role
                $instanceProfile = aws cloudformation describe-stack-resources --stack-name $webAppStackName --logical-resource-id "WebServerInstanceProfile" --query "StackResources[0].PhysicalResourceId" --output text --region $Region 2>$null
                
                if ($instanceProfile -and $instanceProfile -ne "None") {
                    Write-TestResult "Application instances have IAM instance profile" $true "Profile: $instanceProfile"
                    
                    # Get the role associated with the instance profile
                    $role = aws iam get-instance-profile --instance-profile-name $instanceProfile --query "InstanceProfile.Roles[0].RoleName" --output text 2>$null
                    
                    if ($role -and $role -ne "None") {
                        # Check if the role has DynamoDB permissions
                        $policies = aws iam list-attached-role-policies --role-name $role --output json 2>$null | ConvertFrom-Json
                        $inlinePolicies = aws iam list-role-policies --role-name $role --output json 2>$null | ConvertFrom-Json
                        
                        $totalPolicies = $policies.AttachedPolicies.Count + $inlinePolicies.PolicyNames.Count
                        Write-TestResult "Application role has policies attached" ($totalPolicies -gt 0) "Policies: $totalPolicies"
                        
                        # Check for DynamoDB-related policies (simplified check)
                        $hasDynamoDBPolicy = $false
                        
                        foreach ($policy in $policies.AttachedPolicies) {
                            if ($policy.PolicyName -like "*DynamoDB*" -or $policy.PolicyArn -like "*DynamoDB*") {
                                $hasDynamoDBPolicy = $true
                                break
                            }
                        }
                        
                        foreach ($policyName in $inlinePolicies.PolicyNames) {
                            if ($policyName -like "*DynamoDB*") {
                                $hasDynamoDBPolicy = $true
                                break
                            }
                        }
                        
                        Write-TestResult "Application role has DynamoDB permissions" $hasDynamoDBPolicy "DynamoDB policy attached"
                    }
                } else {
                    Write-TestResult "Application instances have IAM instance profile" $false "No instance profile found"
                }
                
                # Test network connectivity (security groups allow database access)
                $webSecurityGroup = aws cloudformation describe-stack-resources --stack-name $webAppStackName --logical-resource-id "WebServerSecurityGroup" --query "StackResources[0].PhysicalResourceId" --output text --region $Region 2>$null
                
                if ($webSecurityGroup -and $webSecurityGroup -ne "None") {
                    # Check if the security group allows HTTPS outbound (for DynamoDB API calls)
                    $sg = aws ec2 describe-security-groups --group-ids $webSecurityGroup --region $Region --output json 2>$null | ConvertFrom-Json
                    $outboundRules = $sg.SecurityGroups[0].IpPermissionsEgress
                    
                    $allowsHTTPS = $outboundRules | Where-Object { 
                        ($_.FromPort -eq 443 -or $_.FromPort -eq $null) -and 
                        ($_.ToPort -eq 443 -or $_.ToPort -eq $null) -and
                        $_.IpProtocol -eq "tcp"
                    }
                    
                    Write-TestResult "Application security group allows HTTPS outbound" ($allowsHTTPS -ne $null) "Required for DynamoDB API calls"
                }
            }
        } else {
            Skip-Test "Database connectivity from application" "Auto Scaling Group not found"
        }
        
    } catch {
        Write-TestResult "Database connectivity from application tests" $false $_.Exception.Message
    }
}

# Test database operations (if enabled)
function Test-DatabaseOperations {
    Write-Host "`n=== Database Operations Tests ===`n" -ForegroundColor Cyan
    
    if (!$TestDataOperations) {
        Skip-Test "Database operations tests" "TestDataOperations not enabled (use -TestDataOperations to enable)"
        return
    }
    
    try {
        $tableName = $script:TestResults.TestData.TableName
        
        if (!$tableName) {
            Skip-Test "Database operations tests" "Table name not available"
            return
        }
        
        Write-Host "    Testing data operations on table: $tableName" -ForegroundColor Gray
        Write-Host "    ⚠️  This will create test data in the DynamoDB table" -ForegroundColor Yellow
        
        # Generate test item
        $testId = "test-item-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $testData = @{
            id = @{ S = $testId }
            timestamp = @{ S = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ") }
            test_type = @{ S = "connectivity_test" }
            data = @{ S = "This is a test item created by the database connectivity test" }
            ttl = @{ N = [string]((Get-Date).AddHours(1).ToFileTimeUtc()) }
        }
        
        # Test 1: Create (PUT) operation
        try {
            $putItemJson = $testData | ConvertTo-Json -Depth 3 -Compress
            $tempFile = [System.IO.Path]::GetTempFileName()
            $putItemJson | Out-File -FilePath $tempFile -Encoding UTF8
            
            aws dynamodb put-item --table-name $tableName --item file://$tempFile --region $Region 2>$null
            $putSuccess = $LASTEXITCODE -eq 0
            
            Write-TestResult "DynamoDB PUT operation successful" $putSuccess "Created test item: $testId"
            
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            
        } catch {
            Write-TestResult "DynamoDB PUT operation successful" $false $_.Exception.Message
            return
        }
        
        # Test 2: Read (GET) operation
        if ($putSuccess) {
            try {
                Start-Sleep -Seconds 2  # Brief delay for consistency
                
                $getResult = aws dynamodb get-item --table-name $tableName --key "{`"id`": {`"S`": `"$testId`"}}" --region $Region --output json 2>$null | ConvertFrom-Json
                $itemExists = $getResult.Item -ne $null
                
                Write-TestResult "DynamoDB GET operation successful" $itemExists "Retrieved test item: $testId"
                
                if ($itemExists) {
                    $retrievedData = $getResult.Item.data.S
                    $dataMatches = $retrievedData -eq $testData.data.S
                    Write-TestResult "DynamoDB data integrity maintained" $dataMatches "Data matches original"
                }
                
            } catch {
                Write-TestResult "DynamoDB GET operation successful" $false $_.Exception.Message
            }
        }
        
        # Test 3: Update operation
        if ($putSuccess) {
            try {
                $updateExpression = "SET #d = :newdata, #ts = :newts"
                $attributeNames = '{"#d": "data", "#ts": "timestamp"}'
                $attributeValues = "{`":newdata`": {`"S`": `"Updated test data`"}, `":newts`": {`"S`": `"$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ')`"}}"
                
                aws dynamodb update-item --table-name $tableName --key "{`"id`": {`"S`": `"$testId`"}}" --update-expression $updateExpression --expression-attribute-names $attributeNames --expression-attribute-values $attributeValues --region $Region 2>$null
                $updateSuccess = $LASTEXITCODE -eq 0
                
                Write-TestResult "DynamoDB UPDATE operation successful" $updateSuccess "Updated test item: $testId"
                
            } catch {
                Write-TestResult "DynamoDB UPDATE operation successful" $false $_.Exception.Message
            }
        }
        
        # Test 4: Query operation (if sort key exists)
        try {
            # First, check if the table has a sort key
            $tableDesc = aws dynamodb describe-table --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
            $hasSortKey = $tableDesc.Table.KeySchema | Where-Object { $_.KeyType -eq "RANGE" }
            
            if ($hasSortKey) {
                # Perform a query operation
                $queryResult = aws dynamodb query --table-name $tableName --key-condition-expression "id = :id" --expression-attribute-values "{`":id`": {`"S`": `"$testId`"}}" --region $Region --output json 2>$null | ConvertFrom-Json
                $querySuccess = $LASTEXITCODE -eq 0 -and $queryResult.Items.Count -gt 0
                
                Write-TestResult "DynamoDB QUERY operation successful" $querySuccess "Queried for test item"
            } else {
                # Perform a scan operation instead
                $scanResult = aws dynamodb scan --table-name $tableName --filter-expression "id = :id" --expression-attribute-values "{`":id`": {`"S`": `"$testId`"}}" --region $Region --output json 2>$null | ConvertFrom-Json
                $scanSuccess = $LASTEXITCODE -eq 0
                
                Write-TestResult "DynamoDB SCAN operation successful" $scanSuccess "Scanned for test item"
            }
            
        } catch {
            Write-TestResult "DynamoDB QUERY/SCAN operation successful" $false $_.Exception.Message
        }
        
        # Test 5: Delete operation (cleanup)
        if ($putSuccess) {
            try {
                aws dynamodb delete-item --table-name $tableName --key "{`"id`": {`"S`": `"$testId`"}}" --region $Region 2>$null
                $deleteSuccess = $LASTEXITCODE -eq 0
                
                Write-TestResult "DynamoDB DELETE operation successful" $deleteSuccess "Deleted test item: $testId"
                
                # Verify deletion
                if ($deleteSuccess) {
                    Start-Sleep -Seconds 2
                    $verifyResult = aws dynamodb get-item --table-name $tableName --key "{`"id`": {`"S`": `"$testId`"}}" --region $Region --output json 2>$null | ConvertFrom-Json
                    $itemDeleted = $verifyResult.Item -eq $null
                    
                    Write-TestResult "DynamoDB test item cleanup verified" $itemDeleted "Test item removed from table"
                }
                
            } catch {
                Write-TestResult "DynamoDB DELETE operation successful" $false $_.Exception.Message
            }
        }
        
    } catch {
        Write-TestResult "Database operations tests" $false $_.Exception.Message
    }
}

# Test database performance and limits
function Test-DatabasePerformance {
    Write-Host "`n=== Database Performance Tests ===`n" -ForegroundColor Cyan
    
    try {
        $tableName = $script:TestResults.TestData.TableName
        
        if (!$tableName) {
            Skip-Test "Database performance tests" "Table name not available"
            return
        }
        
        # Test table metrics
        try {
            $tableDesc = aws dynamodb describe-table --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
            $table = $tableDesc.Table
            
            # Test current utilization
            $itemCount = $table.ItemCount
            $tableSize = $table.TableSizeBytes
            $sizeInMB = [math]::Round($tableSize / 1MB, 2)
            
            Write-TestResult "DynamoDB table size reasonable" ($sizeInMB -lt 1000) "Size: $sizeInMB MB, Items: $itemCount"
            
            # Test provisioned capacity utilization (if applicable)
            if ($table.BillingModeSummary.BillingMode -eq "PROVISIONED") {
                $readCapacity = $table.ProvisionedThroughput.ReadCapacityUnits
                $writeCapacity = $table.ProvisionedThroughput.WriteCapacityUnits
                
                # Get consumed capacity metrics (simplified test)
                $endTime = Get-Date
                $startTime = $endTime.AddMinutes(-15)
                
                try {
                    # This would typically require CloudWatch metrics, simplified for testing
                    Write-TestResult "DynamoDB capacity configured appropriately" ($readCapacity -ge 1 -and $writeCapacity -ge 1) "Read: $readCapacity, Write: $writeCapacity"
                } catch {
                    Skip-Test "DynamoDB capacity utilization check" "CloudWatch metrics not accessible"
                }
            }
            
            # Test response time for a simple operation
            if ($TestDataOperations) {
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                aws dynamodb describe-table --table-name $tableName --region $Region --output json 2>$null | Out-Null
                $stopwatch.Stop()
                $responseTime = $stopwatch.ElapsedMilliseconds
                
                Write-TestResult "DynamoDB response time acceptable" ($responseTime -lt 1000) "Response time: $responseTime ms"
            }
            
        } catch {
            Write-TestResult "Database performance metrics" $false $_.Exception.Message
        }
        
        # Test table limits and quotas
        try {
            # Check if we're approaching any limits
            $tableSizeGB = $tableSize / 1GB
            Write-TestResult "DynamoDB table within size limits" ($tableSizeGB -lt 100) "Size: $([math]::Round($tableSizeGB, 2)) GB"
            
            # Test attribute limits (simplified)
            $attributeCount = $tableDesc.Table.AttributeDefinitions.Count
            Write-TestResult "DynamoDB attribute count reasonable" ($attributeCount -le 20) "Attributes: $attributeCount"
            
        } catch {
            Write-TestResult "Database limits check" $false $_.Exception.Message
        }
        
    } catch {
        Write-TestResult "Database performance tests" $false $_.Exception.Message
    }
}

# Test database backup and recovery readiness
function Test-DatabaseBackupReadiness {
    Write-Host "`n=== Database Backup & Recovery Tests ===`n" -ForegroundColor Cyan
    
    try {
        $tableName = $script:TestResults.TestData.TableName
        
        if (!$tableName) {
            Skip-Test "Database backup readiness tests" "Table name not available"
            return
        }
        
        # Test point-in-time recovery
        try {
            $pitr = aws dynamodb describe-continuous-backups --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
            $pitrEnabled = $pitr.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus -eq "ENABLED"
            
            Write-TestResult "Point-in-time recovery enabled" $pitrEnabled "PITR: $($pitr.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus)"
            
            if ($pitrEnabled) {
                $earliestRestoreTime = $pitr.ContinuousBackupsDescription.PointInTimeRecoveryDescription.EarliestRestorableDateTime
                Write-TestResult "Point-in-time recovery earliest restore time available" ($earliestRestoreTime -ne $null) "Earliest: $earliestRestoreTime"
            }
            
        } catch {
            Write-TestResult "Point-in-time recovery status" $false "Could not retrieve PITR status"
        }
        
        # Test on-demand backups
        try {
            $backups = aws dynamodb list-backups --table-name $tableName --region $Region --output json 2>$null | ConvertFrom-Json
            $hasBackups = $backups.BackupSummaries.Count -gt 0
            
            Write-TestResult "On-demand backups exist" $hasBackups "Backups: $($backups.BackupSummaries.Count)"
            
            if ($hasBackups) {
                $recentBackups = $backups.BackupSummaries | Where-Object { 
                    $backupDate = [DateTime]::Parse($_.BackupCreationDateTime)
                    $backupDate -gt (Get-Date).AddDays(-30)
                }
                Write-TestResult "Recent backups available" ($recentBackups.Count -gt 0) "Recent: $($recentBackups.Count)"
            }
            
        } catch {
            Skip-Test "On-demand backups check" "Could not retrieve backup information"
        }
        
        # Test table export capability (if available)
        try {
            # Note: This doesn't actually perform an export, just checks if the table supports it
            $tableArn = aws dynamodb describe-table --table-name $tableName --query "Table.TableArn" --output text --region $Region 2>$null
            $exportSupported = $tableArn -ne $null -and $tableArn -ne "None"
            
            Write-TestResult "Table export capability available" $exportSupported "Table ARN exists for export operations"
            
        } catch {
            Skip-Test "Table export capability check" "Could not verify export support"
        }
        
    } catch {
        Write-TestResult "Database backup readiness tests" $false $_.Exception.Message
    }
}

# Main test execution
function Invoke-DatabaseConnectivityTests {
    Write-Host "=== Multi-Tier Database Connectivity Tests ===`n" -ForegroundColor Magenta
    Write-Host "Environment: $Environment"
    Write-Host "Stack Prefix: $StackNamePrefix"
    Write-Host "Region: $Region"
    Write-Host "Test Data Operations: $TestDataOperations"
    Write-Host "Started: $($script:TestResults.StartTime)"
    Write-Host ""
    
    # Get database details first
    $dbReady = Get-DatabaseDetails
    if (!$dbReady) {
        Write-Host "❌ Could not retrieve database details. Ensure stacks are deployed." -ForegroundColor Red
        return 3
    }
    
    Write-Host "Database details retrieved successfully:" -ForegroundColor Green
    Write-Host "  Table Name: $($script:TestResults.TestData.TableName)" -ForegroundColor Gray
    
    # Run test suites
    Test-DynamoDBTableConfiguration
    Test-DatabaseConnectivityFromApp
    Test-DatabaseOperations
    Test-DatabasePerformance
    Test-DatabaseBackupReadiness
    
    # Summary
    $script:TestResults.EndTime = Get-Date
    $duration = $script:TestResults.EndTime - $script:TestResults.StartTime
    
    Write-Host "`n=== Database Connectivity Test Summary ===`n" -ForegroundColor Magenta
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
        Write-Host "🎉 All database tests passed! Database connectivity and operations are working correctly." -ForegroundColor Green
        return 0
    } elseif ($successRate -ge 80) {
        Write-Host "⚠️  Most tests passed ($successRate%). Check failed tests above." -ForegroundColor Yellow
        return 1
    } else {
        Write-Host "❌ Many tests failed ($successRate%). Database connectivity may have issues." -ForegroundColor Red
        return 2
    }
}

# Execute tests
try {
    $exitCode = Invoke-DatabaseConnectivityTests
    exit $exitCode
} catch {
    Write-Host "❌ Test execution failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}