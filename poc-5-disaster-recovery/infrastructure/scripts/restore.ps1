#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Restore script for disaster recovery backups.

.DESCRIPTION
    This script handles restoring files from AWS S3 Glacier Deep Archive.
    It can initiate restore jobs, check job status, and download restored files.

.PARAMETER Action
    Action to perform (list, initiate, status, download, test).

.PARAMETER BackupDate
    Date of the backup to restore (format: YYYY-MM-DD).

.PARAMETER RestoreType
    Type of restore (standard, expedited, bulk).

.PARAMETER JobId
    Restore job ID for status checking or downloading.

.PARAMETER DestinationPath
    Local path where restored files should be downloaded.

.PARAMETER FilterPattern
    Pattern to filter which files to restore (e.g., "*.pdf").

.PARAMETER Days
    Number of days to keep restored files available (1-7).

.EXAMPLE
    ./restore.ps1 -Action list
    
.EXAMPLE
    ./restore.ps1 -Action initiate -BackupDate 2024-01-15 -RestoreType standard
    
.EXAMPLE
    ./restore.ps1 -Action status -JobId abc123
    
.EXAMPLE
    ./restore.ps1 -Action download -JobId abc123 -DestinationPath C:\Restored
#>

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("list", "initiate", "status", "download", "test")]
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [string]$BackupDate = "",

    [Parameter(Mandatory=$false)]
    [ValidateSet("standard", "expedited", "bulk")]
    [string]$RestoreType = "standard",

    [Parameter(Mandatory=$false)]
    [string]$JobId = "",

    [Parameter(Mandatory=$false)]
    [string]$DestinationPath = "",

    [Parameter(Mandatory=$false)]
    [string]$FilterPattern = "*",

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 7)]
    [int]$Days = 1,

    [Parameter(Mandatory=$false)]
    [switch]$Verbose
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Global variables
$script:LogFile = ""
$script:RestoreSummary = @{
    StartTime = Get-Date
    EndTime = $null
    Action = $Action
    JobId = $JobId
    Status = "Running"
    FilesRestored = 0
    TotalSizeBytes = 0
    Errors = @()
}

# Function to initialize logging
function Initialize-Logging {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logDir = Join-Path $env:TEMP "aws-restore-logs"
    
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    $script:LogFile = Join-Path $logDir "restore-$timestamp.log"
    Write-LogMessage "Restore script started - Action: $Action" "INFO"
}

# Function to write log messages
function Write-LogMessage {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console
    switch ($Level) {
        "ERROR" { Write-Host $logEntry -ForegroundColor Red }
        "WARN" { Write-Host $logEntry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        default { if ($Verbose) { Write-Host $logEntry } }
    }
    
    # Write to log file
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logEntry
    }
}

# Function to get backup bucket name
function Get-BackupBucketName {
    try {
        $bucketName = $env:BACKUP_BUCKET_NAME
        if (!$bucketName) {
            # Try to get from CloudFormation stack output
            $bucketName = aws cloudformation describe-stacks --stack-name "disaster-recovery-main-dev" --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" --output text 2>$null
        }
        
        if (!$bucketName) {
            throw "Backup bucket name not found. Set BACKUP_BUCKET_NAME environment variable or ensure CloudFormation stack is deployed."
        }
        
        return $bucketName
    }
    catch {
        Write-LogMessage "Error getting backup bucket name: $_" "ERROR"
        throw
    }
}

# Function to list available backups
function Get-AvailableBackups {
    try {
        $bucketName = Get-BackupBucketName
        Write-LogMessage "Listing available backups from bucket: $bucketName" "INFO"
        
        Write-Host "`n=== AVAILABLE BACKUPS ===" -ForegroundColor Cyan
        
        # List backup files
        $backups = aws s3api list-objects-v2 --bucket $bucketName --prefix "backups/" --query "Contents[?ends_with(Key, '.zip')]" --output json | ConvertFrom-Json
        
        if ($backups) {
            $groupedBackups = $backups | Group-Object { ($_.Key -split '/')[1] } | Sort-Object Name -Descending
            
            foreach ($dateGroup in $groupedBackups) {
                Write-Host "`nDate: $($dateGroup.Name)" -ForegroundColor Yellow
                
                foreach ($backup in $dateGroup.Group) {
                    $fileName = Split-Path $backup.Key -Leaf
                    $sizeGB = [math]::Round($backup.Size / 1GB, 3)
                    $lastModified = [DateTime]::Parse($backup.LastModified).ToString("yyyy-MM-dd HH:mm:ss")
                    
                    Write-Host "  File: $fileName" -ForegroundColor White
                    Write-Host "  Size: $sizeGB GB" -ForegroundColor Gray
                    Write-Host "  Modified: $lastModified UTC" -ForegroundColor Gray
                    Write-Host "  S3 Key: $($backup.Key)" -ForegroundColor Gray
                    Write-Host ""
                }
            }
        } else {
            Write-Host "No backups found." -ForegroundColor Yellow
        }
        
        # List metadata files
        Write-Host "`n=== BACKUP METADATA ===" -ForegroundColor Cyan
        $metadata = aws s3api list-objects-v2 --bucket $bucketName --prefix "metadata/" --query "Contents[?ends_with(Key, '.json')]" --output json | ConvertFrom-Json
        
        if ($metadata) {
            foreach ($meta in ($metadata | Sort-Object LastModified -Descending | Select-Object -First 10)) {
                $fileName = Split-Path $meta.Key -Leaf
                $lastModified = [DateTime]::Parse($meta.LastModified).ToString("yyyy-MM-dd HH:mm:ss")
                Write-Host "  $fileName - $lastModified UTC" -ForegroundColor Gray
            }
        }
        
    }
    catch {
        Write-LogMessage "Error listing backups: $_" "ERROR"
        throw
    }
}

# Function to initiate restore job
function Start-RestoreJob {
    param (
        [string]$backupDate,
        [string]$restoreType
    )
    
    try {
        $bucketName = Get-BackupBucketName
        
        # Find backup files for the specified date
        $datePrefix = $backupDate -replace '-', '/'
        $prefix = "backups/$datePrefix/"
        
        Write-LogMessage "Searching for backups with prefix: $prefix" "INFO"
        
        $objects = aws s3api list-objects-v2 --bucket $bucketName --prefix $prefix --query "Contents[?ends_with(Key, '.zip')]" --output json | ConvertFrom-Json
        
        if (!$objects -or $objects.Count -eq 0) {
            throw "No backup files found for date: $backupDate"
        }
        
        Write-Host "`n=== INITIATING RESTORE JOB ===" -ForegroundColor Cyan
        Write-Host "Backup Date: $backupDate"
        Write-Host "Restore Type: $restoreType"
        Write-Host "Found $($objects.Count) backup file(s)"
        Write-Host ""
        
        # Display restore cost and time estimates
        $totalSizeGB = ($objects | Measure-Object -Property Size -Sum).Sum / 1GB
        
        Write-Host "=== RESTORE ESTIMATES ===" -ForegroundColor Yellow
        Write-Host "Total Data Size: $([math]::Round($totalSizeGB, 2)) GB"
        
        switch ($restoreType) {
            "standard" {
                Write-Host "Retrieval Time: 12 hours"
                Write-Host "Estimated Cost: `$$([math]::Round($totalSizeGB * 0.02, 2)) USD"
            }
            "expedited" {
                Write-Host "Retrieval Time: 1-5 minutes"
                Write-Host "Estimated Cost: `$$([math]::Round($totalSizeGB * 0.10, 2)) USD"
            }
            "bulk" {
                Write-Host "Retrieval Time: 5-12 hours"
                Write-Host "Estimated Cost: `$$([math]::Round($totalSizeGB * 0.0025, 2)) USD"
            }
        }
        Write-Host ""
        
        # Confirm before proceeding
        $confirm = Read-Host "Do you want to proceed with the restore? (yes/no)"
        if ($confirm -ne "yes") {
            Write-LogMessage "Restore cancelled by user" "INFO"
            return
        }
        
        # Initiate restore for each object
        $restoreJobs = @()
        
        foreach ($object in $objects) {
            Write-LogMessage "Initiating restore for: $($object.Key)" "INFO"
            
            $restoreRequest = @{
                Days = $Days
                GlacierJobParameters = @{
                    Tier = $restoreType.ToUpper()
                }
            } | ConvertTo-Json -Depth 3
            
            $tempFile = [System.IO.Path]::GetTempFileName()
            $restoreRequest | Out-File -FilePath $tempFile -Encoding UTF8
            
            try {
                aws s3api restore-object --bucket $bucketName --key $object.Key --restore-request file://$tempFile
                
                if ($LASTEXITCODE -eq 0) {
                    Write-LogMessage "Restore initiated successfully for: $($object.Key)" "SUCCESS"
                    $restoreJobs += @{
                        Key = $object.Key
                        Status = "InProgress"
                        Size = $object.Size
                    }
                } else {
                    throw "Failed to initiate restore for: $($object.Key)"
                }
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
        
        # Generate job summary
        $jobSummary = @{
            JobId = (New-Guid).ToString()
            InitiatedTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            BackupDate = $backupDate
            RestoreType = $restoreType
            TotalFiles = $restoreJobs.Count
            TotalSizeBytes = ($restoreJobs | Measure-Object -Property Size -Sum).Sum
            Files = $restoreJobs
        }
        
        # Save job summary
        $jobFile = Join-Path $env:TEMP "restore-job-$($jobSummary.JobId).json"
        $jobSummary | ConvertTo-Json -Depth 3 | Out-File -FilePath $jobFile -Encoding UTF8
        
        Write-Host "`n=== RESTORE JOB INITIATED ===" -ForegroundColor Green
        Write-Host "Job ID: $($jobSummary.JobId)"
        Write-Host "Job File: $jobFile"
        Write-Host "Files to Restore: $($jobSummary.TotalFiles)"
        Write-Host "Total Size: $([math]::Round($jobSummary.TotalSizeBytes / 1GB, 2)) GB"
        Write-Host ""
        Write-Host "To check status: ./restore.ps1 -Action status -JobId $($jobSummary.JobId)"
        Write-Host "To download when ready: ./restore.ps1 -Action download -JobId $($jobSummary.JobId) -DestinationPath C:\Restored"
        
        return $jobSummary.JobId
    }
    catch {
        Write-LogMessage "Error initiating restore job: $_" "ERROR"
        throw
    }
}

# Function to check restore job status
function Get-RestoreJobStatus {
    param (
        [string]$jobId
    )
    
    try {
        $jobFile = Join-Path $env:TEMP "restore-job-$jobId.json"
        
        if (!(Test-Path $jobFile)) {
            throw "Job file not found: $jobFile"
        }
        
        $job = Get-Content $jobFile | ConvertFrom-Json
        $bucketName = Get-BackupBucketName
        
        Write-Host "`n=== RESTORE JOB STATUS ===" -ForegroundColor Cyan
        Write-Host "Job ID: $jobId"
        Write-Host "Initiated: $($job.InitiatedTime)"
        Write-Host "Backup Date: $($job.BackupDate)"
        Write-Host "Restore Type: $($job.RestoreType)"
        Write-Host ""
        
        $completedFiles = 0
        $inProgressFiles = 0
        
        foreach ($file in $job.Files) {
            try {
                $response = aws s3api head-object --bucket $bucketName --key $file.Key --output json 2>$null
                
                if ($LASTEXITCODE -eq 0) {
                    $objectInfo = $response | ConvertFrom-Json
                    
                    if ($objectInfo.Restore) {
                        if ($objectInfo.Restore -like "*ongoing-request=`"false`"*") {
                            Write-Host "✓ $($file.Key) - Ready for download" -ForegroundColor Green
                            $completedFiles++
                        } else {
                            Write-Host "⏳ $($file.Key) - In progress" -ForegroundColor Yellow
                            $inProgressFiles++
                        }
                    } else {
                        Write-Host "❌ $($file.Key) - Not restored" -ForegroundColor Red
                    }
                } else {
                    Write-Host "❓ $($file.Key) - Status unknown" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host "❌ $($file.Key) - Error checking status" -ForegroundColor Red
            }
        }
        
        Write-Host ""
        Write-Host "Summary:"
        Write-Host "  Completed: $completedFiles" -ForegroundColor Green
        Write-Host "  In Progress: $inProgressFiles" -ForegroundColor Yellow
        Write-Host "  Total: $($job.Files.Count)"
        
        if ($completedFiles -eq $job.Files.Count) {
            Write-Host "`nAll files are ready for download!" -ForegroundColor Green
            Write-Host "Run: ./restore.ps1 -Action download -JobId $jobId -DestinationPath C:\Restored"
        } elseif ($completedFiles -gt 0) {
            Write-Host "`nSome files are ready for download. You can download them now or wait for all files to complete." -ForegroundColor Yellow
        } else {
            Write-Host "`nNo files are ready yet. Please check again later." -ForegroundColor Yellow
        }
        
    }
    catch {
        Write-LogMessage "Error checking restore job status: $_" "ERROR"
        throw
    }
}

# Function to download restored files
function Get-RestoredFiles {
    param (
        [string]$jobId,
        [string]$destinationPath
    )
    
    try {
        $jobFile = Join-Path $env:TEMP "restore-job-$jobId.json"
        
        if (!(Test-Path $jobFile)) {
            throw "Job file not found: $jobFile"
        }
        
        $job = Get-Content $jobFile | ConvertFrom-Json
        $bucketName = Get-BackupBucketName
        
        # Create destination directory
        if (!(Test-Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        }
        
        Write-Host "`n=== DOWNLOADING RESTORED FILES ===" -ForegroundColor Cyan
        Write-Host "Job ID: $jobId"
        Write-Host "Destination: $destinationPath"
        Write-Host ""
        
        $downloadedFiles = 0
        $totalSize = 0
        
        foreach ($file in $job.Files) {
            try {
                # Check if file is ready for download
                $response = aws s3api head-object --bucket $bucketName --key $file.Key --output json 2>$null
                
                if ($LASTEXITCODE -eq 0) {
                    $objectInfo = $response | ConvertFrom-Json
                    
                    if ($objectInfo.Restore -and $objectInfo.Restore -like "*ongoing-request=`"false`"*") {
                        $fileName = Split-Path $file.Key -Leaf
                        $localPath = Join-Path $destinationPath $fileName
                        
                        Write-Host "Downloading: $fileName" -ForegroundColor Green
                        
                        aws s3 cp "s3://$bucketName/$($file.Key)" $localPath --no-progress
                        
                        if ($LASTEXITCODE -eq 0) {
                            $downloadedFiles++
                            $totalSize += $file.Size
                            Write-Host "  ✓ Downloaded successfully" -ForegroundColor Green
                        } else {
                            Write-Host "  ❌ Download failed" -ForegroundColor Red
                        }
                    } else {
                        Write-Host "Skipping: $($file.Key) - Not ready for download" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "Error: Cannot access $($file.Key)" -ForegroundColor Red
                }
            }
            catch {
                Write-LogMessage "Error downloading file $($file.Key): $_" "ERROR"
                Write-Host "  ❌ Error: $_" -ForegroundColor Red
            }
        }
        
        Write-Host ""
        Write-Host "=== DOWNLOAD SUMMARY ===" -ForegroundColor Cyan
        Write-Host "Files Downloaded: $downloadedFiles / $($job.Files.Count)"
        Write-Host "Total Size: $([math]::Round($totalSize / 1MB, 2)) MB"
        Write-Host "Destination: $destinationPath"
        
        if ($downloadedFiles -gt 0) {
            Write-Host "`nNext steps:" -ForegroundColor Green
            Write-Host "1. Extract the downloaded archive(s)"
            Write-Host "2. Verify file integrity"
            Write-Host "3. Files will be automatically removed from S3 in $($Days) day(s)"
        }
        
        $script:RestoreSummary.FilesRestored = $downloadedFiles
        $script:RestoreSummary.TotalSizeBytes = $totalSize
        $script:RestoreSummary.Status = "Completed"
        
    }
    catch {
        Write-LogMessage "Error downloading restored files: $_" "ERROR"
        $script:RestoreSummary.Status = "Failed"
        throw
    }
}

# Function to run restore test
function Test-RestoreProcess {
    Write-Host "`n=== TESTING RESTORE PROCESS ===" -ForegroundColor Cyan
    Write-Host "This will initiate a test restore using expedited retrieval."
    Write-Host "It will use the most recent backup and restore a small file for testing."
    Write-Host ""
    
    try {
        $bucketName = Get-BackupBucketName
        
        # Find most recent backup
        $backups = aws s3api list-objects-v2 --bucket $bucketName --prefix "backups/" --query "Contents[?ends_with(Key, '.zip')] | sort_by(@, &LastModified) | [-1]" --output json | ConvertFrom-Json
        
        if (!$backups) {
            throw "No backup files found for testing"
        }
        
        $backupKey = $backups.Key
        $backupDate = ($backupKey -split '/')[1] -replace '/', '-'
        
        Write-Host "Using backup: $backupKey"
        Write-Host "Backup date: $backupDate"
        Write-Host ""
        
        # Initiate expedited restore
        Write-Host "Initiating expedited restore (this will incur charges)..."
        $jobId = Start-RestoreJob -backupDate $backupDate -restoreType "expedited"
        
        if ($jobId) {
            Write-Host "Test restore initiated successfully!" -ForegroundColor Green
            Write-Host "Job ID: $jobId"
            Write-Host ""
            Write-Host "The restore should complete within 1-5 minutes."
            Write-Host "Check status with: ./restore.ps1 -Action status -JobId $jobId"
        }
        
    }
    catch {
        Write-LogMessage "Error running restore test: $_" "ERROR"
        throw
    }
}

# Function to send log to CloudWatch
function Send-LogToCloudWatch {
    param (
        [object]$summary
    )
    
    try {
        $logGroupName = "/aws/disaster-recovery/restore-operations-dev"
        $logStreamName = "restore-$(Get-Date -Format 'yyyyMMdd')"
        
        # Create log stream if it doesn't exist
        aws logs create-log-stream --log-group-name $logGroupName --log-stream-name $logStreamName 2>$null
        
        # Prepare log message
        $logMessage = @{
            operation = "restore"
            action = $summary.Action
            status = $summary.Status
            start_time = $summary.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
            end_time = $summary.EndTime.ToString("yyyy-MM-dd HH:mm:ss")
            job_id = $summary.JobId
            files_restored = $summary.FilesRestored
            total_size_mb = [math]::Round($summary.TotalSizeBytes / 1MB, 2)
            errors = $summary.Errors
        }
        
        $logEntry = @{
            timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            message = ($logMessage | ConvertTo-Json -Compress)
        }
        
        $logEntryJson = $logEntry | ConvertTo-Json
        $tempFile = [System.IO.Path]::GetTempFileName()
        $logEntryJson | Out-File -FilePath $tempFile -Encoding UTF8
        
        aws logs put-log-events --log-group-name $logGroupName --log-stream-name $logStreamName --log-events file://$tempFile 2>$null
        Remove-Item $tempFile -Force
        
        Write-LogMessage "Sent restore summary to CloudWatch Logs" "INFO"
    }
    catch {
        Write-LogMessage "Error sending logs to CloudWatch: $_" "WARN"
    }
}

# Main execution logic
try {
    Initialize-Logging
    
    switch ($Action) {
        "list" {
            Get-AvailableBackups
        }
        
        "initiate" {
            if (!$BackupDate) {
                throw "BackupDate parameter is required for initiate action"
            }
            $script:RestoreSummary.JobId = Start-RestoreJob -backupDate $BackupDate -restoreType $RestoreType
        }
        
        "status" {
            if (!$JobId) {
                throw "JobId parameter is required for status action"
            }
            Get-RestoreJobStatus -jobId $JobId
        }
        
        "download" {
            if (!$JobId -or !$DestinationPath) {
                throw "JobId and DestinationPath parameters are required for download action"
            }
            Get-RestoredFiles -jobId $JobId -destinationPath $DestinationPath
        }
        
        "test" {
            Test-RestoreProcess
        }
    }
    
    $script:RestoreSummary.EndTime = Get-Date
    if ($script:RestoreSummary.Status -eq "Running") {
        $script:RestoreSummary.Status = "Completed"
    }
    
    Send-LogToCloudWatch -summary $script:RestoreSummary
    
} catch {
    $script:RestoreSummary.EndTime = Get-Date
    $script:RestoreSummary.Status = "Failed"
    $script:RestoreSummary.Errors += $_.Exception.Message
    
    Write-LogMessage "Restore operation failed: $_" "ERROR"
    Send-LogToCloudWatch -summary $script:RestoreSummary
    
    exit 1
}