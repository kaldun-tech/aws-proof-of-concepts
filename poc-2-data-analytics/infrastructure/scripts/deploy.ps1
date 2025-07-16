#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deployment script for the Data Analytics POC.

.DESCRIPTION
    This script deploys the CloudFormation templates for the Data Analytics POC.
    It supports deploying the entire stack or individual components.

.PARAMETER Environment
    The environment to deploy to (dev, test, prod).

.PARAMETER S3BucketName
    The name of the S3 bucket to store CloudFormation templates.

.PARAMETER Component
    The specific component to deploy (all, iam, s3, lambda, firehose, api-gateway).

.PARAMETER RunTests
    Whether to run tests after deployment.

.PARAMETER SetupQuickSight
    Whether to set up QuickSight resources.

.PARAMETER Profile
    The AWS CLI profile to use for authentication. Optional - uses default profile if not specified.

.EXAMPLE
    ./deploy.ps1 -Environment dev -S3BucketName your-bucket-name -Component all -RunTests $true

.EXAMPLE
    ./deploy.ps1 -Environment dev -S3BucketName your-bucket-name -Profile my-sso-profile
#>

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [string]$S3BucketName,

    [Parameter(Mandatory=$false)]
    [ValidateSet("all", "iam", "s3", "lambda", "firehose", "api-gateway", "athena", "quicksight")]
    [string]$Component = "all",

    [Parameter(Mandatory=$false)]
    [bool]$RunTests = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$SetupQuickSight = $false,

    [Parameter(Mandatory=$false)]
    [string]$Profile = ""
)

# Set the AWS region
$region = "us-east-1"
$stackNamePrefix = "poc2-data-analytics"
$templateDir = Join-Path $PSScriptRoot ".." "cloudformation"

# Set up AWS CLI profile parameter
if ($Profile) {
    $env:AWS_PROFILE = $Profile
    Write-Host "Using AWS profile: $Profile"
}

# Function to check if S3 bucket exists, create if it doesn't
function New-S3Bucket {
    param (
        [string]$bucketName
    )

    try {
        Write-Host "Checking if S3 bucket $bucketName exists..."
        aws s3api head-bucket --bucket $bucketName $profileParam 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Creating S3 bucket $bucketName..."
            aws s3 mb s3://$bucketName --region $region $profileParam
        }
        else {
            Write-Host "S3 bucket $bucketName already exists."
        }
    }
    catch {
        Write-Error "Error checking/creating S3 bucket: $_"
        exit 1
    }
}

# Function to package CloudFormation templates
function ConvertTo-CloudFormationPackage {
    param (
        [string]$templateFile,
        [string]$s3Bucket,
        [string]$outputFile
    )

    try {
        Write-Host "Packaging CloudFormation template $templateFile..."
        aws cloudformation package `
            --template-file $templateFile `
            --s3-bucket $s3Bucket `
            --output-template-file $outputFile `
            --region $region
    }
    catch {
        Write-Error "Error packaging CloudFormation template: $_"
        exit 1
    }
}

# Function to deploy CloudFormation stack
function New-CloudFormationStack {
    param (
        [string]$stackName,
        [string]$templateFile,
        [hashtable]$parameters,
        [bool]$capabilities = $false
    )

    try {
        Write-Host "Deploying CloudFormation stack $stackName..."
        
        $paramString = ""
        foreach ($key in $parameters.Keys) {
            $paramString += "$key=$($parameters[$key]) "
        }
        
        $cmd = "aws cloudformation deploy " +
               "--template-file $templateFile " +
               "--stack-name $stackName " +
               "--region $region "
        
        if ($paramString) {
            $cmd += "--parameter-overrides $paramString "
        }
        
        if ($capabilities) {
            $cmd += "--capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND"
        }
        
        Write-Host "Executing: $cmd"
        Invoke-Expression $cmd
    }
    catch {
        Write-Error "Error deploying CloudFormation stack: $_"
        exit 1
    }
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
            Write-Host "Stack $stackName deployment status: $status" -ForegroundColor Yellow
            if ($status -like "*FAILED" -or $status -like "*ROLLBACK*") {
                Write-Error "Stack deployment failed or is in rollback state"
                return $false
            }
            return $true
        }
    } catch {
        Write-Error "Error validating stack deployment: $_"
        return $false
    }
}

# Ensure S3 bucket exists
New-S3Bucket -bucketName $S3BucketName

# Deploy IAM stack
if ($Component -eq "all" -or $Component -eq "iam") {
    $stackName = "$stackNamePrefix-iam"
    $templateFile = Join-Path $templateDir "iam.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters -capabilities $true
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "IAM stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy S3 stack
if ($Component -eq "all" -or $Component -eq "s3") {
    # Get outputs from previous stacks if needed
    $firehoseRoleArn = ""
    if (($Component -eq "all") -and (Test-StackDeployment -stackName "$stackNamePrefix-iam")) {
        $firehoseRoleArn = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-iam" --query "Stacks[0].Outputs[?OutputKey=='FirehoseRoleARN'].OutputValue" --output text --region $region
    }

    $stackName = "$stackNamePrefix-s3"
    $templateFile = Join-Path $templateDir "s3.yaml"
    $parameters = @{
        "FirehoseRoleArn" = $firehoseRoleArn
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "S3 stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy Lambda stack
if ($Component -eq "all" -or $Component -eq "lambda") {
    $stackName = "$stackNamePrefix-lambda"
    $templateFile = Join-Path $templateDir "lambda.yaml"
    $parameters = @{
        "Environment" = $Environment
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters -capabilities $true
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "Lambda stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy Firehose stack
if ($Component -eq "all" -or $Component -eq "firehose") {
    # Get outputs from previous stacks
    $s3BucketName = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-s3" --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text --region $region
    $lambdaFunctionArn = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-lambda" --query "Stacks[0].Outputs[?OutputKey=='TransformDataFunctionArn'].OutputValue" --output text --region $region

    $stackName = "$stackNamePrefix-firehose"
    $templateFile = Join-Path $templateDir "firehose.yaml"
    $parameters = @{
        "Environment" = $Environment
        "S3BucketName" = $s3BucketName
        "LambdaFunctionArn" = $lambdaFunctionArn
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "Firehose stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy API Gateway stack
if ($Component -eq "all" -or $Component -eq "api-gateway") {
    # Get outputs from previous stacks
    $firehoseDeliveryStreamName = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-firehose" --query "Stacks[0].Outputs[?OutputKey=='FirehoseDeliveryStreamName'].OutputValue" --output text --region $region
    $apiGatewayFirehoseRoleARN = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-iam" --query "Stacks[0].Outputs[?OutputKey=='APIGatewayFirehoseRoleARN'].OutputValue" --output text --region $region

    $stackName = "$stackNamePrefix-api-gateway"
    $templateFile = Join-Path $templateDir "api-gateway.yaml"
    $parameters = @{
        "Environment" = $Environment
        "FirehoseDeliveryStreamName" = $firehoseDeliveryStreamName
        "APIGatewayFirehoseRoleARN" = $apiGatewayFirehoseRoleARN
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "API Gateway stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
}

# Deploy Athena stack
if ($Component -eq "all" -or $Component -eq "athena") {
    # Get outputs from previous stacks
    $s3BucketName = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-s3" --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text --region $region

    $stackName = "$stackNamePrefix-athena"
    $templateFile = Join-Path $templateDir "athena.yaml"
    $parameters = @{
        "Environment" = $Environment
        "S3BucketName" = $s3BucketName
        # Optional: Specify a custom location for Athena query results
        # "AthenaQueryResultsLocation" = "s3://your-query-results-bucket/folder/"
    }
    New-CloudFormationStack -stackName $stackName -templateFile $templateFile -parameters $parameters
    if (-not (Test-StackDeployment -stackName $stackName)) {
        Write-Error "Athena stack deployment failed or has issues. Stopping deployment."
        exit 1
    }
    
    # Execute the Athena create table query after deployment
    $createTableQueryId = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-athena" --query "Stacks[0].Outputs[?OutputKey=='CreateTableQueryId'].OutputValue" --output text --region $region
    if ($createTableQueryId) {
        Write-Host "Executing Athena create table query..." -ForegroundColor Cyan
        $workGroupName = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-athena" --query "Stacks[0].Outputs[?OutputKey=='AthenaWorkGroupName'].OutputValue" --output text --region $region
        
        # Start query execution
        $queryExecutionId = aws athena start-query-execution --query-string "$(aws athena get-named-query --named-query-id $createTableQueryId --query "NamedQuery.QueryString" --output text --region $region)" --work-group $workGroupName --region $region --query "QueryExecutionId" --output text
        
        # Wait for query execution to complete
        Write-Host "Waiting for Athena table creation to complete..." -ForegroundColor Yellow
        $queryStatus = ""
        $maxAttempts = 10
        $attempts = 0
        
        do {
            Start-Sleep -Seconds 3
            $queryStatus = aws athena get-query-execution --query-execution-id $queryExecutionId --query "QueryExecution.Status.State" --output text --region $region
            $attempts++
            Write-Host "Query status: $queryStatus (Attempt $attempts of $maxAttempts)" -ForegroundColor Yellow
        } while ($queryStatus -eq "RUNNING" -and $attempts -lt $maxAttempts)
        
        if ($queryStatus -eq "SUCCEEDED") {
            Write-Host "Athena table created successfully!" -ForegroundColor Green
        } else {
            Write-Host "Athena table creation status: $queryStatus" -ForegroundColor Yellow
            if ($queryStatus -eq "FAILED") {
                $errorMessage = aws athena get-query-execution --query-execution-id $queryExecutionId --query "QueryExecution.Status.StateChangeReason" --output text --region $region
                Write-Host "Error creating Athena table: $errorMessage" -ForegroundColor Red
            }
        }
    }
}

# Function to test the deployed infrastructure
function Test-DeployedInfrastructure {
    param (
        [string]$stackNamePrefix,
        [string]$region
    )
    
    Write-Host "Testing deployed infrastructure..." -ForegroundColor Cyan
    
    # Create a hashtable to store test results
    $testResults = @{}
    
    try {
        # Test 1: Verify API Gateway endpoint is accessible
        $apiUrl = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-api-gateway" --query "Stacks[0].Outputs[?OutputKey=='ClickstreamIngestAPIEndpoint'].OutputValue" --output text --region $region
        if ($apiUrl) {
            Write-Host "API Gateway endpoint: $apiUrl" -ForegroundColor Green
            $testResults["APIGateway"] = @{ "Endpoint" = $apiUrl; "Status" = "Configured for POST" }
            
            # Test API Gateway with sample payloads
            Write-Host "Testing API Gateway with sample payloads..." -ForegroundColor Cyan
            
            $testPayloads = @(
                @{
                    "element_clicked" = "entree_1"
                    "time_spent" = 67
                    "source_menu" = "restaurant_name"
                    "created_at" = "2022-09-11 23:00:00"
                },
                @{
                    "element_clicked" = "entree_1"
                    "time_spent" = 12
                    "source_menu" = "restaurant_name"
                    "created_at" = "2022-09-11 23:00:00"
                },
                @{
                    "element_clicked" = "entree_4"
                    "time_spent" = 32
                    "source_menu" = "restaurant_name"
                    "createdAt" = "2022-09-11 23:00:00"
                },
                @{
                    "element_clicked" = "drink_1"
                    "time_spent" = 15
                    "source_menu" = "restaurant_name"
                    "created_at" = "2022-09-11 23:00:00"
                },
                @{
                    "element_clicked" = "drink_3"
                    "time_spent" = 14
                    "source_menu" = "restaurant_name"
                    "created_at" = "2022-09-11 23:00:00"
                }
            )
            
            # Ensure the API URL ends with /poc for our endpoint
            if (-not $apiUrl.EndsWith("/poc")) {
                $apiUrl = $apiUrl.TrimEnd("/") + "/poc"
            }
            
            $testResults["APITests"] = @{}
            $allTestsSuccessful = $true
            
            # Test each payload
            foreach ($payload in $testPayloads) {
                $payloadJson = $payload | ConvertTo-Json -Compress
                $elementClicked = $payload.element_clicked
                
                try {
                    Write-Host "Sending test payload for $elementClicked..." -ForegroundColor Yellow
                    # Store response but don't use it directly - we just care about success/failure
                    Invoke-RestMethod -Method Post -Uri $apiUrl -Body $payloadJson -ContentType "application/json" -ErrorAction Stop | Out-Null
                    Write-Host "✓ Test for $elementClicked succeeded with status code 200" -ForegroundColor Green
                    $testResults["APITests"][$elementClicked] = @{ "Status" = "Success"; "StatusCode" = 200 }
                } catch {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Host "✗ Test for $elementClicked failed with status code $statusCode" -ForegroundColor Red
                    $testResults["APITests"][$elementClicked] = @{ "Status" = "Failed"; "StatusCode" = $statusCode; "Error" = $_.Exception.Message }
                    $allTestsSuccessful = $false
                }
                
                # Add a small delay between requests
                Start-Sleep -Milliseconds 500
            }
            
            if ($allTestsSuccessful) {
                Write-Host "All API tests completed successfully!" -ForegroundColor Green
            } else {
                Write-Host "Some API tests failed. Check the results for details." -ForegroundColor Yellow
            }
        } else {
            Write-Host "API Gateway endpoint not found" -ForegroundColor Yellow
            $testResults["APIGateway"] = @{ "Found" = $false }
        }
        
        # Test 2: Verify S3 bucket exists
        $bucketName = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-s3" --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text --region $region
        if ($bucketName) {
            # Check if bucket exists
            aws s3api head-bucket --bucket $bucketName --region $region
            Write-Host "S3 Bucket '$bucketName' exists and is accessible" -ForegroundColor Green
            $testResults["S3Bucket"] = @{ "BucketName" = $bucketName; "Status" = "Accessible" }
            
            # Wait a bit for data to potentially arrive in S3
            Write-Host "Waiting 10 seconds for data to arrive in S3..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            
            # Check if any data has been delivered to S3
            Write-Host "Checking for data in S3 bucket..." -ForegroundColor Cyan
            $s3Objects = aws s3 ls "s3://$bucketName/" --recursive --region $region
            if ($s3Objects) {
                Write-Host "Data found in S3 bucket:" -ForegroundColor Green
                Write-Host $s3Objects -ForegroundColor Green
                $testResults["S3Data"] = @{ "Status" = "DataFound"; "Objects" = $s3Objects }
            } else {
                Write-Host "No data found in S3 bucket yet. This is expected if Firehose is still buffering data." -ForegroundColor Yellow
                $testResults["S3Data"] = @{ "Status" = "NoDataYet" }
            }
        } else {
            Write-Host "S3 bucket not found" -ForegroundColor Yellow
            $testResults["S3Bucket"] = @{ "Found" = $false }
        }
        
        # Test 3: Verify Lambda function exists
        $lambdaFunction = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-lambda" --query "Stacks[0].Outputs[?OutputKey=='TransformDataFunctionName'].OutputValue" --output text --region $region
        if ($lambdaFunction) {
            # Verify function exists
            $runtime = aws lambda get-function --function-name $lambdaFunction --query "Configuration.Runtime" --output text --region $region
            $state = aws lambda get-function --function-name $lambdaFunction --query "Configuration.State" --output text --region $region
            $handler = aws lambda get-function --function-name $lambdaFunction --query "Configuration.Handler" --output text --region $region
            Write-Host "Lambda function '$lambdaFunction' is $state (Runtime: $runtime, Handler: $handler)" -ForegroundColor Green
            $testResults["Lambda"] = @{ "FunctionName" = $lambdaFunction; "Runtime" = $runtime; "State" = $state; "Handler" = $handler }
            
            # Check recent Lambda invocations
            Write-Host "Checking recent Lambda invocations..." -ForegroundColor Cyan
            $logGroupName = "/aws/lambda/$lambdaFunction"
            $recentLogs = aws logs describe-log-streams --log-group-name $logGroupName --order-by LastEventTime --descending --limit 5 --region $region
            if ($recentLogs) {
                Write-Host "Lambda function has recent log streams" -ForegroundColor Green
                $testResults["LambdaLogs"] = @{ "Status" = "LogsFound" }
            } else {
                Write-Host "No recent Lambda logs found. This is expected if no data has been processed yet." -ForegroundColor Yellow
                $testResults["LambdaLogs"] = @{ "Status" = "NoLogsYet" }
            }
        } else {
            Write-Host "Lambda function not found" -ForegroundColor Yellow
            $testResults["Lambda"] = @{ "Found" = $false }
        }
        
        # Test 4: Verify Firehose delivery stream exists
        $deliveryStream = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-firehose" --query "Stacks[0].Outputs[?OutputKey=='FirehoseDeliveryStreamName'].OutputValue" --output text --region $region
        if ($deliveryStream) {
            # Check if delivery stream exists
            $status = aws firehose describe-delivery-stream --delivery-stream-name $deliveryStream --query "DeliveryStreamDescription.DeliveryStreamStatus" --output text --region $region
            Write-Host "Kinesis Firehose delivery stream '$deliveryStream' status: $status" -ForegroundColor Green
            $testResults["Firehose"] = @{ "DeliveryStreamName" = $deliveryStream; "Status" = $status }
        } else {
            Write-Host "Firehose delivery stream not found" -ForegroundColor Yellow
            $testResults["Firehose"] = @{ "Found" = $false }
        }
        
        # Test 5: Verify Athena table and run a test query
        $athenaWorkGroup = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-athena" --query "Stacks[0].Outputs[?OutputKey=='AthenaWorkGroupName'].OutputValue" --output text --region $region 2>$null
        if ($athenaWorkGroup) {
            Write-Host "Athena WorkGroup '$athenaWorkGroup' exists" -ForegroundColor Green
            $testResults["Athena"] = @{ "WorkGroupName" = $athenaWorkGroup; "Status" = "Exists" }
            
            # Get the select data query ID
            $selectQueryId = aws cloudformation describe-stacks --stack-name "$stackNamePrefix-athena" --query "Stacks[0].Outputs[?OutputKey=='SelectDataQueryId'].OutputValue" --output text --region $region
            
            if ($selectQueryId) {
                Write-Host "Running Athena test query to select data from the table..." -ForegroundColor Cyan
                
                # Get the query string from the named query
                $queryString = aws athena get-named-query --named-query-id $selectQueryId --query "NamedQuery.QueryString" --output text --region $region
                
                # Execute the query
                $queryExecutionId = aws athena start-query-execution --query-string $queryString --work-group $athenaWorkGroup --region $region --query "QueryExecutionId" --output text
                
                # Wait for query to complete
                Write-Host "Waiting for Athena query to complete..." -ForegroundColor Yellow
                $queryStatus = ""
                $maxAttempts = 5
                $attempts = 0
                
                do {
                    Start-Sleep -Seconds 2
                    $queryStatus = aws athena get-query-execution --query-execution-id $queryExecutionId --query "QueryExecution.Status.State" --output text --region $region
                    $attempts++
                    Write-Host "Query status: $queryStatus (Attempt $attempts of $maxAttempts)" -ForegroundColor Yellow
                } while ($queryStatus -eq "RUNNING" -and $attempts -lt $maxAttempts)
                
                if ($queryStatus -eq "SUCCEEDED") {
                    # Get query results
                    $queryResults = aws athena get-query-results --query-execution-id $queryExecutionId --region $region
                    Write-Host "Athena query executed successfully!" -ForegroundColor Green
                    $testResults["AthenaQuery"] = @{ "Status" = "Success"; "QueryExecutionId" = $queryExecutionId }
                    
                    # Check if there are any results
                    $resultCount = ($queryResults | ConvertFrom-Json).ResultSet.Rows.Count - 1 # Subtract 1 for header row
                    if ($resultCount -gt 0) {
                        Write-Host "Found $resultCount records in the Athena table" -ForegroundColor Green
                        $testResults["AthenaQuery"]["RecordCount"] = $resultCount
                    } else {
                        Write-Host "No records found in the Athena table yet. This is expected if data has not been processed or if Firehose is still buffering." -ForegroundColor Yellow
                        $testResults["AthenaQuery"]["RecordCount"] = 0
                    }
                } else {
                    Write-Host "Athena query status: $queryStatus" -ForegroundColor Yellow
                    if ($queryStatus -eq "FAILED") {
                        $errorMessage = aws athena get-query-execution --query-execution-id $queryExecutionId --query "QueryExecution.Status.StateChangeReason" --output text --region $region
                        Write-Host "Error executing Athena query: $errorMessage" -ForegroundColor Red
                        $testResults["AthenaQuery"] = @{ "Status" = "Failed"; "Error" = $errorMessage }
                    } else {
                        $testResults["AthenaQuery"] = @{ "Status" = $queryStatus }
                    }
                }
            }
        } else {
            Write-Host "Athena WorkGroup not found. Skipping Athena tests." -ForegroundColor Yellow
            $testResults["Athena"] = @{ "Found" = $false }
        }
        
        Write-Host "Infrastructure testing completed" -ForegroundColor Cyan
        
        # Return the collected test results
        return $testResults
    } catch {
        Write-Error "Error testing infrastructure: $_"
        return $null
    }
}

# Function to setup QuickSight SQL queries and helper files
function Setup-QuickSight {
    param (
        [string]$environment,
        [string]$region,
        [string]$stackNamePrefix
    )
    
    Write-Host "Setting up QuickSight resources..." -ForegroundColor Cyan
    
    # Create SQL queries directory if it doesn't exist
    $sqlQueriesDir = Join-Path $PSScriptRoot ".." "sql-queries"
    if (-not (Test-Path $sqlQueriesDir)) {
        New-Item -ItemType Directory -Path $sqlQueriesDir -Force | Out-Null
        Write-Host "Created SQL queries directory: $sqlQueriesDir" -ForegroundColor Green
    }
    
    # Get Athena and S3 resource names
    $athenaWorkGroup = $null
    $bucketName = $null
    
    try {
        # Check if Athena stack exists
        $athenaStackName = "$stackNamePrefix-athena"
        if (aws cloudformation describe-stacks --stack-name $athenaStackName --region $region 2>$null) {
            $athenaWorkGroup = aws cloudformation describe-stacks --stack-name $athenaStackName --query "Stacks[0].Outputs[?OutputKey=='WorkGroupName'].OutputValue" --output text --region $region
            Write-Host "Found Athena WorkGroup: $athenaWorkGroup" -ForegroundColor Green
        } else {
            Write-Host "Athena stack not found. Please deploy the Athena component first." -ForegroundColor Yellow
            return
        }
        
        # Check if S3 stack exists
        $s3StackName = "$stackNamePrefix-s3"
        if (aws cloudformation describe-stacks --stack-name $s3StackName --region $region 2>$null) {
            $bucketName = aws cloudformation describe-stacks --stack-name $s3StackName --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text --region $region
            Write-Host "Found S3 bucket: $bucketName" -ForegroundColor Green
        } else {
            Write-Host "S3 stack not found. Please deploy the S3 component first." -ForegroundColor Yellow
            return
        }
        
        # Generate SQL query files
        Write-Host "Generating SQL query files for QuickSight..." -ForegroundColor Cyan
        
        # 1. All data query
        $allDataQuery = @"
-- Basic query to get all clickstream data
SELECT 
    element_clicked,
    time_spent,
    source_menu,
    created_at,
    datehour
FROM 
    my_ingested_data
ORDER BY 
    created_at DESC
LIMIT 100;
"@
        Set-Content -Path (Join-Path $sqlQueriesDir "all-data.sql") -Value $allDataQuery
        
        # 2. Popular items query
        $popularItemsQuery = @"
-- Query for popular menu items
SELECT 
    element_clicked,
    COUNT(*) as view_count,
    AVG(time_spent) as avg_time_spent,
    MIN(time_spent) as min_time_spent,
    MAX(time_spent) as max_time_spent
FROM 
    my_ingested_data
GROUP BY 
    element_clicked
ORDER BY 
    view_count DESC;
"@
        Set-Content -Path (Join-Path $sqlQueriesDir "popular-items.sql") -Value $popularItemsQuery
        
        # 3. Source menu analysis query
        $sourceMenuQuery = @"
-- Query for source menu analysis
SELECT 
    source_menu,
    COUNT(*) as view_count,
    AVG(time_spent) as avg_time_spent
FROM 
    my_ingested_data
GROUP BY 
    source_menu
ORDER BY 
    view_count DESC;
"@
        Set-Content -Path (Join-Path $sqlQueriesDir "source-menu-analysis.sql") -Value $sourceMenuQuery
        
        # 4. Time series analysis query
        $timeSeriesQuery = @"
-- Query for time series analysis by hour
SELECT 
    datehour,
    COUNT(*) as view_count
FROM 
    my_ingested_data
GROUP BY 
    datehour
ORDER BY 
    datehour ASC;
"@
        Set-Content -Path (Join-Path $sqlQueriesDir "time-series-analysis.sql") -Value $timeSeriesQuery
        
        # 5. Dashboard configuration JSON
        $dashboardConfig = @"
{
  "dashboardName": "Clickstream Analytics Dashboard",
  "visualizations": [
    {
      "name": "Menu Item Popularity",
      "type": "BAR_CHART",
      "dimensions": [
        "element_clicked"
      ],
      "measures": [
        "COUNT(*)"
      ],
      "sortBy": {
        "field": "COUNT(*)",
        "direction": "DESC"
      }
    },
    {
      "name": "Time Spent Analysis",
      "type": "BOX_PLOT",
      "dimensions": [
        "element_clicked"
      ],
      "measures": [
        "time_spent"
      ]
    },
    {
      "name": "Source Menu Analysis",
      "type": "PIE_CHART",
      "dimensions": [
        "source_menu"
      ],
      "measures": [
        "COUNT(*)"
      ]
    },
    {
      "name": "Time Series Analysis",
      "type": "LINE_CHART",
      "dimensions": [
        "datehour"
      ],
      "measures": [
        "COUNT(*)"
      ],
      "sortBy": {
        "field": "datehour",
        "direction": "ASC"
      }
    }
  ],
  "filters": [
    {
      "name": "Date Range Filter",
      "column": "datehour",
      "type": "DATETIME_RANGE"
    },
    {
      "name": "Source Menu Filter",
      "column": "source_menu",
      "type": "MULTISELECT"
    },
    {
      "name": "Time Spent Filter",
      "column": "time_spent",
      "type": "RANGE"
    }
  ],
  "refreshSchedule": {
    "frequency": "HOURLY"
  }
}
"@
        Set-Content -Path (Join-Path $sqlQueriesDir "dashboard-config.json") -Value $dashboardConfig
        
        Write-Host "SQL query files created successfully in $sqlQueriesDir" -ForegroundColor Green
        
        # Display QuickSight setup instructions
        Write-Host "
QuickSight Setup Instructions:" -ForegroundColor Cyan
        Write-Host "1. Sign in to the QuickSight console: https://quicksight.aws.amazon.com/" -ForegroundColor White
        Write-Host "2. If you don't have a QuickSight account, sign up for one." -ForegroundColor White
        Write-Host "3. Configure QuickSight permissions:" -ForegroundColor White
        Write-Host "   - Go to QuickSight > Manage QuickSight > Security & permissions" -ForegroundColor White
        Write-Host "   - Under 'QuickSight access to AWS services', click 'Add or remove'" -ForegroundColor White
        Write-Host "   - Enable Amazon S3 and select the bucket: $bucketName" -ForegroundColor White
        Write-Host "   - Enable Amazon Athena" -ForegroundColor White
        Write-Host "4. Create a new Athena data source:" -ForegroundColor White
        Write-Host "   - Go to QuickSight > Datasets > New dataset > Athena" -ForegroundColor White
        Write-Host "   - Select the Athena workgroup: $athenaWorkGroup" -ForegroundColor White
        Write-Host "   - Select the 'my_ingested_data' table" -ForegroundColor White
        Write-Host "   - Choose 'Import to SPICE for quicker analytics'" -ForegroundColor White
        Write-Host "5. Create visualizations using the SQL queries in $sqlQueriesDir" -ForegroundColor White
        Write-Host "   - Use dashboard-config.json as a reference for creating visualizations" -ForegroundColor White
        
    } catch {
        Write-Error "Error setting up QuickSight: $_"
    }
}

Write-Host "Deployment completed successfully!"

# Run infrastructure tests if component is "all" or if explicitly requested, and RunTests is true
if (($Component -eq "all" -or $Component -eq "api-gateway") -and $RunTests) {
    Write-Host "
Running infrastructure tests..."
    $testResults = Test-DeployedInfrastructure -stackNamePrefix $stackNamePrefix -region $region
}

# Setup QuickSight if requested or if component is quicksight
if ($SetupQuickSight -or $Component -eq "quicksight") {
    Setup-QuickSight -environment $Environment -region $region -stackNamePrefix $stackNamePrefix
}
