#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Backup script for personal file disaster recovery.

.DESCRIPTION
    This script backs up personal files to AWS S3 Glacier Deep Archive for long-term storage.
    It compresses files, uploads them to S3, and logs all operations for monitoring.

.PARAMETER ConfigFile
    Path to the backup configuration JSON file.

.PARAMETER TestMode
    Run in test mode without actually uploading files.

.PARAMETER Action
    Action to perform (backup, verify, list).

.PARAMETER BackupDate
    Specific backup date to verify (format: YYYY-MM-DD).

.PARAMETER Verbose
    Enable verbose logging.

.EXAMPLE
    ./backup.ps1 -ConfigFile backup-config.json
    
.EXAMPLE
    ./backup.ps1 -ConfigFile backup-config.json -TestMode $true
    
.EXAMPLE
    ./backup.ps1 -Action verify -BackupDate 2024-01-15
#>

param (
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "backup-config.json",

    [Parameter(Mandatory=$false)]
    [bool]$TestMode = $false,

    [Parameter(Mandatory=$false)]
    [ValidateSet("backup", "verify", "list")]
    [string]$Action = "backup",

    [Parameter(Mandatory=$false)]
    [string]$BackupDate = "",

    [Parameter(Mandatory=$false)]
    [switch]$Verbose,

    [Parameter(Mandatory=$false)]
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = $null
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to determine environment and stack name
function Get-EnvironmentStackName {
    # Priority: Parameter > Environment Variable > Default
    $env = $Environment
    if (-not $env) {
        $env = $env:DR_ENVIRONMENT
    }
    if (-not $env) {
        $env = "dev"
        Write-LogMessage "No environment specified, defaulting to 'dev'. Use -Environment parameter or set DR_ENVIRONMENT variable." "WARNING"
    }
    
    $stackName = "disaster-recovery-main-$env"
    Write-LogMessage "Using environment: $env, stack: $stackName" "INFO"
    return @{
        Environment = $env
        StackName = $stackName
    }
}

# Global variables
$script:LogFile = ""
$script:BackupSummary = @{
    StartTime = Get-Date
    EndTime = $null
    TotalFiles = 0
    TotalSizeBytes = 0
    CompressedSizeBytes = 0
    SuccessfulUploads = 0
    FailedUploads = 0
    Errors = @()
}

# Function to initialize logging
function Initialize-Logging {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logDir = Join-Path $env:TEMP "aws-backup-logs"
    
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    $script:LogFile = Join-Path $logDir "backup-$timestamp.log"
    Write-LogMessage "Backup script started" "INFO"
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

# Function to validate input parameters
function Test-InputParameters {
    param (
        [string]$configPath,
        [string]$action,
        [string]$backupDate
    )
    
    # Validate config file
    if (-not $configPath) {
        throw "ConfigFile parameter is required"
    }
    
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }
    
    # Validate config file is readable and has proper extension
    $fileInfo = Get-Item $configPath
    if ($fileInfo.Extension -notin @('.json', '.conf')) {
        Write-LogMessage "Warning: Config file extension '$($fileInfo.Extension)' is not .json or .conf" "WARN"
    }
    
    # Validate backup date format if provided
    if ($backupDate) {
        try {
            $null = [DateTime]::ParseExact($backupDate, "yyyy-MM-dd", $null)
        }
        catch {
            throw "BackupDate must be in YYYY-MM-DD format. Provided: $backupDate"
        }
    }
    
    # Validate action parameter
    if ($action -notin @('backup', 'verify', 'list')) {
        throw "Action must be one of: backup, verify, list. Provided: $action"
    }
    
    Write-LogMessage "Input parameter validation passed" "INFO"
}

# Function to validate backup configuration structure
function Test-BackupConfiguration {
    param (
        [PSCustomObject]$config
    )
    
    # Required top-level properties
    $requiredProperties = @('backupName', 'compression', 'paths')
    foreach ($prop in $requiredProperties) {
        if (-not $config.PSObject.Properties.Name.Contains($prop)) {
            throw "Missing required configuration property: $prop"
        }
    }
    
    # Validate backup name
    if (-not $config.backupName -or $config.backupName.Length -lt 1) {
        throw "backupName must be a non-empty string"
    }
    
    if ($config.backupName -match '[<>:"/\\|?*]') {
        throw "backupName contains invalid characters. Avoid: < > : \" / \\ | ? *"
    }
    
    # Validate compression settings
    if ($config.compression) {
        if ($config.compression.PSObject.Properties.Name.Contains('enabled') -and $config.compression.enabled -is [string]) {
            # Convert string to boolean if needed
            $config.compression.enabled = [bool]::Parse($config.compression.enabled)
        }
        
        if ($config.compression.enabled) {
            if (-not $config.compression.PSObject.Properties.Name.Contains('format')) {
                throw "Compression format is required when compression is enabled"
            }
            
            if ($config.compression.format -notin @('zip', '7z', 'tar.gz')) {
                throw "Compression format must be one of: zip, 7z, tar.gz. Found: $($config.compression.format)"
            }
            
            if ($config.compression.PSObject.Properties.Name.Contains('level')) {
                $level = $config.compression.level
                if ($level -lt 0 -or $level -gt 9) {
                    throw "Compression level must be between 0 and 9. Found: $level"
                }
            }
        }
    }
    
    # Validate paths configuration
    if (-not $config.paths -or $config.paths.Count -eq 0) {
        throw "At least one backup path must be configured"
    }
    
    foreach ($pathConfig in $config.paths) {
        # Required path properties
        $requiredPathProps = @('name', 'source', 'include')
        foreach ($prop in $requiredPathProps) {
            if (-not $pathConfig.PSObject.Properties.Name.Contains($prop)) {
                throw "Missing required path property '$prop' in path configuration"
            }
        }
        
        # Validate path name
        if (-not $pathConfig.name -or $pathConfig.name.Length -lt 1) {
            throw "Path name must be a non-empty string"
        }
        
        # Validate source path exists
        if (-not (Test-Path $pathConfig.source)) {
            Write-LogMessage "Warning: Source path does not exist: $($pathConfig.source)" "WARN"
        }
        
        # Validate include patterns
        if (-not $pathConfig.include -or $pathConfig.include.Count -eq 0) {
            throw "At least one include pattern must be specified for path '$($pathConfig.name)'"
        }
        
        # Validate pattern syntax
        foreach ($pattern in $pathConfig.include) {
            if (-not $pattern -or $pattern.Length -eq 0) {
                throw "Include patterns cannot be empty for path '$($pathConfig.name)'"
            }
        }
    }
    
    Write-LogMessage "Configuration structure validation passed" "INFO"
}

# Function to load backup configuration
function Get-BackupConfiguration {
    param (
        [string]$configPath
    )
    
    try {
        Test-InputParameters -configPath $configPath -action $Action -backupDate $BackupDate
        
        $configContent = Get-Content $configPath -Raw
        if (-not $configContent.Trim()) {
            throw "Configuration file is empty: $configPath"
        }
        
        $config = $configContent | ConvertFrom-Json
        Test-BackupConfiguration -config $config
        
        Write-LogMessage "Loaded and validated configuration from $configPath" "INFO"
        return $config
    }
    catch {
        Write-LogMessage "Error loading configuration: $_" "ERROR"
        throw
    }
}

# Function to expand environment variables in paths
function Expand-PathVariables {
    param (
        [string]$path
    )
    
    return [Environment]::ExpandEnvironmentVariables($path)
}

# Function to get files to backup based on configuration
function Get-FilesToBackup {
    param (
        [object]$config
    )
    
    $filesToBackup = @()
    
    foreach ($pathConfig in $config.paths) {
        $sourcePath = Expand-PathVariables -path $pathConfig.source
        
        if (!(Test-Path $sourcePath)) {
            Write-LogMessage "Source path does not exist: $sourcePath" "WARN"
            continue
        }
        
        Write-LogMessage "Processing source path: $sourcePath" "INFO"
        
        # Get files based on include patterns
        foreach ($includePattern in $pathConfig.include) {
            try {
                $files = Get-ChildItem -Path $sourcePath -Filter $includePattern -Recurse -File -ErrorAction SilentlyContinue
                
                foreach ($file in $files) {
                    $relativePath = $file.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
                    $exclude = $false
                    
                    # Check exclude patterns
                    foreach ($excludePattern in $pathConfig.exclude) {
                        if ($relativePath -like $excludePattern) {
                            $exclude = $true
                            break
                        }
                    }
                    
                    if (!$exclude) {
                        $filesToBackup += @{
                            FullPath = $file.FullName
                            RelativePath = $relativePath
                            Size = $file.Length
                            LastModified = $file.LastWriteTime
                            SourcePath = $sourcePath
                        }
                    }
                }
            }
            catch {
                Write-LogMessage "Error processing pattern $includePattern in $sourcePath`: $_" "ERROR"
            }
        }
    }
    
    return $filesToBackup
}

# Function to create compressed backup archive
function New-BackupArchive {
    param (
        [array]$files,
        [object]$config
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $archiveName = "$($config.backupName)-$timestamp"
    $tempDir = Join-Path $env:TEMP "backup-staging"
    $archiveDir = Join-Path $tempDir $archiveName
    
    try {
        # Create staging directory
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
        
        Write-LogMessage "Created staging directory: $archiveDir" "INFO"
        
        # Copy files to staging directory maintaining structure
        $copiedFiles = 0
        foreach ($file in $files) {
            try {
                $destPath = Join-Path $archiveDir $file.RelativePath
                $destDir = Split-Path $destPath -Parent
                
                if (!(Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                
                Copy-Item -Path $file.FullPath -Destination $destPath -Force
                $copiedFiles++
                
                if ($copiedFiles % 100 -eq 0) {
                    Write-LogMessage "Copied $copiedFiles files..." "INFO"
                }
            }
            catch {
                Write-LogMessage "Error copying file $($file.FullPath): $_" "ERROR"
                $script:BackupSummary.Errors += "Copy error: $($file.FullPath) - $_"
            }
        }
        
        Write-LogMessage "Copied $copiedFiles files to staging directory" "SUCCESS"
        
        # Create compressed archive
        $archivePath = Join-Path $tempDir "$archiveName.zip"
        
        if ($config.compression.enabled) {
            Write-LogMessage "Creating compressed archive: $archivePath" "INFO"
            
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($archiveDir, $archivePath, $config.compression.level, $false)
            
            $archiveInfo = Get-Item $archivePath
            $script:BackupSummary.CompressedSizeBytes = $archiveInfo.Length
            
            Write-LogMessage "Created compressed archive: $archivePath (Size: $([math]::Round($archiveInfo.Length / 1MB, 2)) MB)" "SUCCESS"
        }
        
        return @{
            ArchivePath = $archivePath
            ArchiveName = $archiveName
            StagingDir = $tempDir
        }
    }
    catch {
        Write-LogMessage "Error creating backup archive: $_" "ERROR"
        throw
    }
}

# Function to upload archive to S3
function Send-ArchiveToS3 {
    param (
        [string]$archivePath,
        [string]$archiveName,
        [object]$config
    )
    
    try {
        $timestamp = Get-Date -Format "yyyy/MM/dd"
        $s3Key = "backups/$timestamp/$archiveName.zip"
        
        # Get backup bucket name from AWS CLI configuration or environment
        $bucketName = $env:BACKUP_BUCKET_NAME
        if (!$bucketName) {
            # Try to get from CloudFormation stack output
            $stackInfo = Get-EnvironmentStackName
            $bucketName = aws cloudformation describe-stacks --stack-name "$($stackInfo.StackName)" --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" --output text 2>$null
        }
        
        if (!$bucketName) {
            throw "Backup bucket name not found. Set BACKUP_BUCKET_NAME environment variable or ensure CloudFormation stack is deployed."
        }
        
        Write-LogMessage "Uploading archive to S3: s3://$bucketName/$s3Key" "INFO"
        
        if (!$TestMode) {
            # Upload with Deep Archive storage class
            aws s3 cp $archivePath "s3://$bucketName/$s3Key" --storage-class DEEP_ARCHIVE --no-progress
            
            if ($LASTEXITCODE -eq 0) {
                Write-LogMessage "Successfully uploaded archive to S3" "SUCCESS"
                $script:BackupSummary.SuccessfulUploads++
                
                # Create metadata file
                $metadata = @{
                    BackupName = $config.backupName
                    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    TotalFiles = $script:BackupSummary.TotalFiles
                    TotalSizeBytes = $script:BackupSummary.TotalSizeBytes
                    CompressedSizeBytes = $script:BackupSummary.CompressedSizeBytes
                    S3Key = $s3Key
                    StorageClass = "DEEP_ARCHIVE"
                }
                
                $metadataJson = $metadata | ConvertTo-Json -Depth 3
                $metadataPath = [System.IO.Path]::GetTempFileName()
                $metadataJson | Out-File -FilePath $metadataPath -Encoding UTF8
                
                $metadataS3Key = "metadata/$timestamp/$archiveName-metadata.json"
                aws s3 cp $metadataPath "s3://$bucketName/$metadataS3Key" --no-progress
                Remove-Item $metadataPath -Force
                
                Write-LogMessage "Uploaded backup metadata to S3" "INFO"
            } else {
                throw "S3 upload failed with exit code $LASTEXITCODE"
            }
        } else {
            Write-LogMessage "TEST MODE: Would upload to s3://$bucketName/$s3Key" "INFO"
        }
        
        return $s3Key
    }
    catch {
        Write-LogMessage "Error uploading to S3: $_" "ERROR"
        $script:BackupSummary.FailedUploads++
        throw
    }
}

# Function to cleanup temporary files
function Remove-TempFiles {
    param (
        [string]$stagingDir
    )
    
    try {
        if (Test-Path $stagingDir) {
            Remove-Item $stagingDir -Recurse -Force
            Write-LogMessage "Cleaned up temporary files" "INFO"
        }
    }
    catch {
        Write-LogMessage "Error cleaning up temporary files: $_" "WARN"
    }
}

# Function to send log to CloudWatch
function Send-LogToCloudWatch {
    param (
        [object]$summary
    )
    
    try {
        $logGroupName = "/aws/disaster-recovery/backup-operations-dev"
        $logStreamName = "backup-$(Get-Date -Format 'yyyyMMdd')"
        
        # Create log stream if it doesn't exist
        aws logs create-log-stream --log-group-name $logGroupName --log-stream-name $logStreamName 2>$null
        
        # Prepare log message
        $logMessage = @{
            operation = "backup"
            status = if ($summary.FailedUploads -eq 0) { "success" } else { "failed" }
            start_time = $summary.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
            end_time = $summary.EndTime.ToString("yyyy-MM-dd HH:mm:ss")
            file_count = $summary.TotalFiles
            total_size_mb = [math]::Round($summary.TotalSizeBytes / 1MB, 2)
            compressed_size_mb = [math]::Round($summary.CompressedSizeBytes / 1MB, 2)
            compression_ratio = if ($summary.TotalSizeBytes -gt 0) { [math]::Round($summary.CompressedSizeBytes / $summary.TotalSizeBytes, 2) } else { 0 }
            successful_uploads = $summary.SuccessfulUploads
            failed_uploads = $summary.FailedUploads
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
        
        Write-LogMessage "Sent backup summary to CloudWatch Logs" "INFO"
    }
    catch {
        Write-LogMessage "Error sending logs to CloudWatch: $_" "WARN"
    }
}

# Function to perform backup verification
function Test-BackupIntegrity {
    param (
        [string]$backupDate
    )
    
    Write-LogMessage "Verifying backup integrity for date: $backupDate" "INFO"
    
    # Implementation would check S3 for backup files and validate metadata
    # This is a placeholder for the verification logic
    Write-LogMessage "Backup verification not yet implemented" "WARN"
}

# Function to list available backups
function Get-AvailableBackups {
    Write-LogMessage "Listing available backups..." "INFO"
    
    try {
        $bucketName = $env:BACKUP_BUCKET_NAME
        if (!$bucketName) {
            $stackInfo = Get-EnvironmentStackName
            $bucketName = aws cloudformation describe-stacks --stack-name "$($stackInfo.StackName)" --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" --output text 2>$null
        }
        
        if (!$bucketName) {
            throw "Backup bucket name not found"
        }
        
        aws s3 ls "s3://$bucketName/backups/" --recursive --human-readable --summarize
    }
    catch {
        Write-LogMessage "Error listing backups: $_" "ERROR"
    }
}

# Main execution logic
try {
    Initialize-Logging
    
    switch ($Action) {
        "verify" {
            if (!$BackupDate) {
                throw "BackupDate parameter is required for verify action"
            }
            Test-BackupIntegrity -backupDate $BackupDate
            return
        }
        "list" {
            Get-AvailableBackups
            return
        }
        "backup" {
            # Continue with backup process
            break
        }
    }
    
    # Load configuration
    $config = Get-BackupConfiguration -configPath $ConfigFile
    
    Write-LogMessage "Starting backup process for: $($config.backupName)" "INFO"
    if ($TestMode) {
        Write-LogMessage "Running in TEST MODE - no files will be uploaded" "WARN"
    }
    
    # Get files to backup
    Write-LogMessage "Discovering files to backup..." "INFO"
    $files = Get-FilesToBackup -config $config
    
    $script:BackupSummary.TotalFiles = $files.Count
    $script:BackupSummary.TotalSizeBytes = ($files | Measure-Object -Property Size -Sum).Sum
    
    Write-LogMessage "Found $($files.Count) files to backup (Total size: $([math]::Round($script:BackupSummary.TotalSizeBytes / 1MB, 2)) MB)" "SUCCESS"
    
    if ($files.Count -eq 0) {
        Write-LogMessage "No files found to backup. Exiting." "WARN"
        return
    }
    
    # Create backup archive
    $archive = New-BackupArchive -files $files -config $config
    
    # Upload to S3
    $s3Key = Send-ArchiveToS3 -archivePath $archive.ArchivePath -archiveName $archive.ArchiveName -config $config
    
    # Cleanup
    Remove-TempFiles -stagingDir $archive.StagingDir
    
    # Finalize summary
    $script:BackupSummary.EndTime = Get-Date
    $duration = $script:BackupSummary.EndTime - $script:BackupSummary.StartTime
    
    Write-LogMessage "Backup completed successfully!" "SUCCESS"
    Write-LogMessage "Duration: $($duration.ToString('hh\:mm\:ss'))" "INFO"
    Write-LogMessage "Files: $($script:BackupSummary.TotalFiles)" "INFO"
    Write-LogMessage "Original size: $([math]::Round($script:BackupSummary.TotalSizeBytes / 1MB, 2)) MB" "INFO"
    Write-LogMessage "Compressed size: $([math]::Round($script:BackupSummary.CompressedSizeBytes / 1MB, 2)) MB" "INFO"
    Write-LogMessage "Compression ratio: $([math]::Round($script:BackupSummary.CompressedSizeBytes / $script:BackupSummary.TotalSizeBytes * 100, 1))%" "INFO"
    
    # Send summary to CloudWatch
    Send-LogToCloudWatch -summary $script:BackupSummary
    
} catch {
    $script:BackupSummary.EndTime = Get-Date
    $script:BackupSummary.Errors += $_.Exception.Message
    
    Write-LogMessage "Backup failed: $_" "ERROR"
    Send-LogToCloudWatch -summary $script:BackupSummary
    
    exit 1
}