#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Helper script for setting up QuickSight with the Data Analytics POC.
.DESCRIPTION
    This script helps with the setup and configuration of Amazon QuickSight
    for visualizing the clickstream data collected by the Data Analytics POC.
    It generates SQL queries that can be used in QuickSight and provides
    guidance on creating visualizations.
.PARAMETER Environment
    The environment (dev, test, prod) to use.
.PARAMETER Region
    The AWS region where resources are deployed.
.PARAMETER StackNamePrefix
    The prefix used for CloudFormation stack names.
.EXAMPLE
    ./setup-quicksight.ps1 -Environment dev
    Generates SQL queries and setup instructions for the dev environment.
#>

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory=$false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory=$false)]
    [string]$StackNamePrefix = "poc2-data-analytics"
)

# Function to check if a stack exists
function Test-StackExists {
    param (
        [string]$stackName
    )
    
    try {
        $null = aws cloudformation describe-stacks --stack-name $stackName --region $Region 2>$null
        return $true
    } catch {
        return $false
    }
}

# Function to get stack outputs
function Get-StackOutputs {
    param (
        [string]$stackName
    )
    
    $outputs = @{}
    
    if (Test-StackExists -stackName $stackName) {
        $outputsJson = aws cloudformation describe-stacks --stack-name $stackName --query "Stacks[0].Outputs" --output json --region $Region
        $outputsArray = $outputsJson | ConvertFrom-Json
        
        foreach ($output in $outputsArray) {
            $outputs[$output.OutputKey] = $output.OutputValue
        }
    }
    
    return $outputs
}

# ASCII art banner
function Show-Banner {
    Write-Host ""
    Write-Host "  _____       _        _____           _       _     _   " -ForegroundColor Cyan
    Write-Host " |  __ \     | |      / ____|         (_)     | |   | |  " -ForegroundColor Cyan
    Write-Host " | |  | | ___| |_ __ | (___   ___ _ __ _ _ __ | |_  | |  " -ForegroundColor Cyan
    Write-Host " | |  | |/ _ \ __/ _  \___ \ / __| '__| | '_ \| __| | |  " -ForegroundColor Cyan
    Write-Host " | |__| |  __/ || (_| |___) | (__| |  | | |_) | |_  |_|  " -ForegroundColor Cyan
    Write-Host " |_____/ \___|\__\__,_|____/ \___|_|  |_| .__/ \__| (_)  " -ForegroundColor Cyan
    Write-Host "                                        | |              " -ForegroundColor Cyan
    Write-Host "                                        |_|              " -ForegroundColor Cyan
    Write-Host " QuickSight Setup Helper for Data Analytics POC           " -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

# Main script execution starts here
Show-Banner

# Check if required stacks exist
$athenaStackName = "$StackNamePrefix-athena"
$s3StackName = "$StackNamePrefix-s3"

if (-not (Test-StackExists -stackName $athenaStackName)) {
    Write-Host "Error: Athena stack '$athenaStackName' not found. Please deploy the Athena stack first." -ForegroundColor Red
    exit 1
}

if (-not (Test-StackExists -stackName $s3StackName)) {
    Write-Host "Error: S3 stack '$s3StackName' not found. Please deploy the S3 stack first." -ForegroundColor Red
    exit 1
}

# Get stack outputs
$athenaOutputs = Get-StackOutputs -stackName $athenaStackName
$s3Outputs = Get-StackOutputs -stackName $s3StackName

$workGroupName = $athenaOutputs["AthenaWorkGroupName"]
$bucketName = $s3Outputs["BucketName"]

Write-Host "Found resources for environment: $Environment" -ForegroundColor Green
Write-Host "  - Athena WorkGroup: $workGroupName" -ForegroundColor Green
Write-Host "  - S3 Bucket: $bucketName" -ForegroundColor Green
Write-Host ""

# Generate SQL queries for QuickSight
$sqlQueriesDir = Join-Path $PSScriptRoot ".." "sql-queries"
if (-not (Test-Path $sqlQueriesDir)) {
    New-Item -ItemType Directory -Path $sqlQueriesDir | Out-Null
}

# Define query file paths
$allDataQueryFile = Join-Path $sqlQueriesDir "all-data.sql"
$popularItemsQueryFile = Join-Path $sqlQueriesDir "popular-items.sql"
$sourceMenuQueryFile = Join-Path $sqlQueriesDir "source-menu-analysis.sql"
$timeSeriesQueryFile = Join-Path $sqlQueriesDir "time-series-analysis.sql"

Write-Host "Using existing SQL queries from: $sqlQueriesDir" -ForegroundColor Cyan
Write-Host "  - All Data Query: $allDataQueryFile" -ForegroundColor Cyan
Write-Host "  - Popular Items Query: $popularItemsQueryFile" -ForegroundColor Cyan
Write-Host "  - Source Menu Analysis Query: $sourceMenuQueryFile" -ForegroundColor Cyan
Write-Host "  - Time Series Analysis Query: $timeSeriesQueryFile" -ForegroundColor Cyan
Write-Host ""

# Generate QuickSight setup instructions
Write-Host "QuickSight Setup Instructions" -ForegroundColor Yellow
Write-Host "------------------------" -ForegroundColor DarkGray
Write-Host "1. Sign in to the QuickSight console: https://quicksight.aws.amazon.com/" -ForegroundColor White
Write-Host "2. Configure permissions for the S3 bucket: $bucketName" -ForegroundColor White
Write-Host "3. Configure permissions for the Athena workgroup: $workGroupName" -ForegroundColor White
Write-Host "4. Create a new dataset using Athena with the following settings:" -ForegroundColor White
Write-Host "   - Data source name: poc-clickstream-$Environment" -ForegroundColor White
Write-Host "   - Athena workgroup: $workGroupName" -ForegroundColor White
Write-Host "   - Table: my_ingested_data" -ForegroundColor White
Write-Host "5. Create visualizations using the SQL queries generated in: $sqlQueriesDir" -ForegroundColor White
Write-Host ""

# Generate a sample dashboard configuration
$dashboardConfigFile = Join-Path $sqlQueriesDir "dashboard-config.json"
$dashboardConfig = @{
    "dashboardName" = "Clickstream Analytics Dashboard - $Environment"
    "visualizations" = @(
        @{
            "name" = "Menu Item Popularity"
            "type" = "BAR_CHART"
            "dimensions" = @("element_clicked")
            "measures" = @("COUNT(*)")
            "sortBy" = @{
                "field" = "COUNT(*)"
                "direction" = "DESC"
            }
        },
        @{
            "name" = "Time Spent Analysis"
            "type" = "BOX_PLOT"
            "dimensions" = @("element_clicked")
            "measures" = @("time_spent")
        },
        @{
            "name" = "Source Menu Analysis"
            "type" = "PIE_CHART"
            "dimensions" = @("source_menu")
            "measures" = @("COUNT(*)")
        },
        @{
            "name" = "Time Series Analysis"
            "type" = "LINE_CHART"
            "dimensions" = @("datehour")
            "measures" = @("COUNT(*)")
            "sortBy" = @{
                "field" = "datehour"
                "direction" = "ASC"
            }
        }
    )
    "filters" = @(
        @{
            "name" = "Date Range Filter"
            "column" = "datehour"
            "type" = "DATETIME_RANGE"
        },
        @{
            "name" = "Source Menu Filter"
            "column" = "source_menu"
            "type" = "MULTISELECT"
        },
        @{
            "name" = "Time Spent Filter"
            "column" = "time_spent"
            "type" = "RANGE"
        }
    )
}

$dashboardConfigJson = $dashboardConfig | ConvertTo-Json -Depth 5
Set-Content -Path $dashboardConfigFile -Value $dashboardConfigJson

Write-Host "Generated sample dashboard configuration: $dashboardConfigFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "For detailed instructions on creating QuickSight visualizations, refer to the README.md" -ForegroundColor Yellow
Write-Host ""
