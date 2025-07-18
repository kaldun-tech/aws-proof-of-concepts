#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Backup functionality tests for Disaster Recovery POC.

.DESCRIPTION
    This script tests backup functionality including configuration validation,
    file discovery, compression, and upload processes without affecting production data.

.PARAMETER ConfigFile
    Path to the backup configuration file to test.

.PARAMETER CreateTestData
    Create test data files for backup testing.

.PARAMETER CleanupTestData
    Remove test data files after testing.

.PARAMETER TestUpload
    Test actual upload to S3 (will incur small costs).

.PARAMETER Verbose
    Enable verbose output for detailed test results.

.EXAMPLE
    ./Test-Backup.ps1 -CreateTestData -Verbose
    
.EXAMPLE
    ./Test-Backup.ps1 -ConfigFile test-backup-config.json -TestUpload
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$CreateTestData,

    [Parameter(Mandatory = $false)]
    [switch]$CleanupTestData,

    [Parameter(Mandatory = $false)]
    [switch]$TestUpload
)

# Set error action preference
$ErrorActionPreference = "Continue"

# Test results tracking
$script:TestResults = @{
    TotalTests   = 0
    PassedTests  = 0
    FailedTests  = 0
    SkippedTests = 0
    Errors       = @()
    StartTime    = Get-Date
    TestDataPath = ""
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
    }
    else {
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
    
    if ($Details -and ($VerbosePreference -eq 'Continue')) {
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

# Create test data structure
function New-TestData {
    Write-Host "`n=== Creating Test Data ===" -ForegroundColor Cyan
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $testDataRoot = Join-Path $env:TEMP "dr-test-data-$timestamp"
    $script:TestResults.TestDataPath = $testDataRoot
    
    try {
        # Create directory structure
        $directories = @(
            "Documents",
            "Pictures", 
            "Videos",
            "Music",
            "Desktop",
            "CustomData",
            "TempFiles",
            "ExcludeMe"
        )
        
        foreach ($dir in $directories) {
            $fullPath = Join-Path $testDataRoot $dir
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        }
        
        # Create test files with various types and sizes
        $testFiles = @(
            @{ Path = "Documents\important-document.pdf"; Content = "PDF"; Size = 1024 },
            @{ Path = "Documents\spreadsheet.xlsx"; Content = "XLSX"; Size = 2048 },
            @{ Path = "Documents\presentation.pptx"; Content = "PPTX"; Size = 3072 },
            @{ Path = "Documents\text-file.txt"; Content = "Plain text content for testing backup functionality. This file contains multiple lines.`nLine 2`nLine 3"; Size = 0 },
            @{ Path = "Documents\temp\temp-file.tmp"; Content = "TMP"; Size = 512 },
            @{ Path = "Pictures\photo1.jpg"; Content = "JPG"; Size = 5120 },
            @{ Path = "Pictures\photo2.png"; Content = "PNG"; Size = 4096 },
            @{ Path = "Pictures\raw-photo.cr2"; Content = "RAW"; Size = 25600 },
            @{ Path = "Pictures\thumbnails\thumb.jpg"; Content = "THUMB"; Size = 256 },
            @{ Path = "Videos\movie.mp4"; Content = "MP4"; Size = 102400 },
            @{ Path = "Videos\clip.avi"; Content = "AVI"; Size = 51200 },
            @{ Path = "Music\song1.mp3"; Content = "MP3"; Size = 3072 },
            @{ Path = "Music\song2.flac"; Content = "FLAC"; Size = 8192 },
            @{ Path = "Desktop\shortcut.lnk"; Content = "LNK"; Size = 256 },
            @{ Path = "Desktop\readme.txt"; Content = "Desktop readme file"; Size = 0 },
            @{ Path = "CustomData\data1.dat"; Content = "DAT"; Size = 1536 },
            @{ Path = "CustomData\data2.xml"; Content = "<?xml version='1.0'?><root><item>test</item></root>"; Size = 0 },
            @{ Path = "TempFiles\cache.cache"; Content = "CACHE"; Size = 512 },
            @{ Path = "ExcludeMe\excluded.txt"; Content = "This should be excluded"; Size = 0 }
        )
        
        foreach ($file in $testFiles) {
            $fullPath = Join-Path $testDataRoot $file.Path
            $directory = Split-Path $fullPath -Parent
            
            if (!(Test-Path $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            
            if ($file.Size -gt 0) {
                # Create file with specific size
                $content = $file.Content * ($file.Size / $file.Content.Length)
                $content | Out-File -FilePath $fullPath -Encoding UTF8 -NoNewline
            }
            else {
                # Use actual content
                $file.Content | Out-File -FilePath $fullPath -Encoding UTF8
            }
        }
        
        # Create some additional files with timestamps
        $oldFile = Join-Path $testDataRoot "Documents\old-file.txt"
        "Old file content" | Out-File -FilePath $oldFile -Encoding UTF8
        (Get-Item $oldFile).LastWriteTime = (Get-Date).AddDays(-100)
        
        $newFile = Join-Path $testDataRoot "Documents\new-file.txt"
        "New file content" | Out-File -FilePath $newFile -Encoding UTF8
        (Get-Item $newFile).LastWriteTime = Get-Date
        
        Write-TestResult "Test data structure created" $true "Path: $testDataRoot"
        Write-TestResult "Test files created" $true "Files: $($testFiles.Count + 2)"
        
        return $testDataRoot
        
    }
    catch {
        Write-TestResult "Test data creation" $false $_.Exception.Message
        throw
    }
}

# Create test configuration file
function New-TestConfiguration {
    param (
        [string]$testDataPath
    )
    
    $testConfig = @{
        backupName  = "TestBackup"
        compression = @{
            enabled = $true
            level   = 6
            format  = "zip"
        }
        paths       = @(
            @{
                name    = "TestDocuments"
                source  = Join-Path $testDataPath "Documents"
                include = @("*.pdf", "*.txt", "*.xlsx", "*.pptx")
                exclude = @("temp/*", "*.tmp")
            },
            @{
                name    = "TestPictures"
                source  = Join-Path $testDataPath "Pictures"
                include = @("*.jpg", "*.png", "*.cr2")
                exclude = @("thumbnails/*")
            },
            @{
                name    = "TestVideos"
                source  = Join-Path $testDataPath "Videos"
                include = @("*.mp4", "*.avi")
                exclude = @()
            },
            @{
                name    = "TestMusic"
                source  = Join-Path $testDataPath "Music"
                include = @("*.mp3", "*.flac")
                exclude = @()
            },
            @{
                name    = "TestDesktop"
                source  = Join-Path $testDataPath "Desktop"
                include = @("*.*")
                exclude = @("*.lnk")
            },
            @{
                name    = "TestCustomData"
                source  = Join-Path $testDataPath "CustomData"
                include = @("*.dat", "*.xml")
                exclude = @()
            }
        )
    }
    
    $configPath = Join-Path $testDataPath "test-backup-config.json"
    $testConfig | ConvertTo-Json -Depth 4 | Out-File -FilePath $configPath -Encoding UTF8
    
    return $configPath
}

# Test configuration file validation
function Test-ConfigurationValidation {
    param (
        [string]$configPath
    )
    
    Write-Host "`n=== Configuration Validation Tests ===" -ForegroundColor Cyan
    
    try {
        # Test configuration file exists
        $configExists = Test-Path $configPath
        Write-TestResult "Configuration file exists" $configExists "Path: $configPath"
        
        if (!$configExists) {
            return
        }
        
        # Test configuration file is valid JSON
        try {
            $config = Get-Content $configPath | ConvertFrom-Json
            Write-TestResult "Configuration is valid JSON" $true
        }
        catch {
            Write-TestResult "Configuration is valid JSON" $false $_.Exception.Message
            return
        }
        
        # Test required properties exist
        $requiredProperties = @("backupName", "compression", "paths")
        foreach ($prop in $requiredProperties) {
            $hasProperty = $config.PSObject.Properties.Name -contains $prop
            Write-TestResult "Configuration has required property: $prop" $hasProperty
        }
        
        # Test paths configuration
        if ($config.paths) {
            Write-TestResult "Configuration has paths defined" ($config.paths.Count -gt 0) "Paths: $($config.paths.Count)"
            
            foreach ($pathConfig in $config.paths) {
                $pathName = $pathConfig.name
                
                # Test required path properties
                $hasSource = $pathConfig.PSObject.Properties.Name -contains "source"
                $hasInclude = $pathConfig.PSObject.Properties.Name -contains "include"
                $hasExclude = $pathConfig.PSObject.Properties.Name -contains "exclude"
                
                Write-TestResult "Path '$pathName' has source" $hasSource -Details $pathConfig.source
                Write-TestResult "Path '$pathName' has include patterns" $hasInclude "Patterns: $($pathConfig.include.Count)"
                Write-TestResult "Path '$pathName' has exclude patterns" $hasExclude "Patterns: $($pathConfig.exclude.Count)"
                
                # Test source path exists
                if ($hasSource) {
                    $sourceExists = Test-Path $pathConfig.source
                    Write-TestResult "Path '$pathName' source exists" $sourceExists -Details $pathConfig.source
                }
            }
        }
        
        # Test compression configuration
        if ($config.compression) {
            $compressionEnabled = $config.compression.enabled
            $hasLevel = $config.compression.PSObject.Properties.Name -contains "level"
            $hasFormat = $config.compression.PSObject.Properties.Name -contains "format"
            
            Write-TestResult "Compression configuration valid" ($hasLevel -and $hasFormat) "Enabled: $compressionEnabled"
        }
        
    }
    catch {
        Write-TestResult "Configuration validation" $false $_.Exception.Message
    }
}

# Test file discovery functionality
function Test-FileDiscovery {
    param (
        [string]$configPath
    )
    
    Write-Host "`n=== File Discovery Tests ===" -ForegroundColor Cyan
    
    try {
        $config = Get-Content $configPath | ConvertFrom-Json
        $totalFilesFound = 0
        $totalSizeBytes = 0
        
        foreach ($pathConfig in $config.paths) {
            $sourcePath = $pathConfig.source
            $pathName = $pathConfig.name
            
            if (!(Test-Path $sourcePath)) {
                Write-TestResult "Path '$pathName' source accessible" $false "Path not found: $sourcePath"
                continue
            }
            
            Write-TestResult "Path '$pathName' source accessible" $true
            
            # Test include pattern matching
            $filesFound = 0
            foreach ($includePattern in $pathConfig.include) {
                try {
                    $files = Get-ChildItem -Path $sourcePath -Filter $includePattern -Recurse -File -ErrorAction SilentlyContinue
                    $filesFound += $files.Count
                    
                    if ($files.Count -gt 0) {
                        $patternSize = ($files | Measure-Object -Property Length -Sum).Sum
                        $totalSizeBytes += $patternSize
                    }
                }
                catch {
                    Write-TestResult "Include pattern '$includePattern' in '$pathName'" $false $_.Exception.Message
                }
            }
            
            Write-TestResult "Files discovered in '$pathName'" ($filesFound -gt 0) "Files: $filesFound" -Details "Pattern matches found"
            $totalFilesFound += $filesFound
            
            # Test exclude pattern functionality
            if ($pathConfig.exclude -and $pathConfig.exclude.Count -gt 0) {
                $excludeWorking = $false
                foreach ($excludePattern in $pathConfig.exclude) {
                    try {
                        $excludedFiles = Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $excludePattern -or $_.FullName -like "*$excludePattern*" }
                        if ($excludedFiles.Count -gt 0) {
                            $excludeWorking = $true
                            break
                        }
                    }
                    catch {
                        # Exclude pattern testing failed, but this is not critical
                    }
                }
                Write-TestResult "Exclude patterns functional in '$pathName'" $excludeWorking -Details "Patterns would exclude files"
            }
        }
        
        Write-TestResult "Overall file discovery" ($totalFilesFound -gt 0) "Total files: $totalFilesFound, Size: $([math]::Round($totalSizeBytes / 1KB, 1)) KB"
        
    }
    catch {
        Write-TestResult "File discovery tests" $false $_.Exception.Message
    }
}

# Test compression functionality
function Test-CompressionFunctionality {
    param (
        [string]$testDataPath
    )
    
    Write-Host "`n=== Compression Tests ===" -ForegroundColor Cyan
    
    try {
        # Test .NET compression assembly
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Write-TestResult "Compression assembly loaded" $true
        
        # Create test compression
        $sourceDir = Join-Path $testDataPath "Documents"
        $archivePath = Join-Path $testDataPath "test-archive.zip"
        
        if (Test-Path $sourceDir) {
            try {
                [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDir, $archivePath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
                
                $archiveExists = Test-Path $archivePath
                Write-TestResult "Test archive created" $archiveExists
                
                if ($archiveExists) {
                    $archiveInfo = Get-Item $archivePath
                    $originalSize = (Get-ChildItem $sourceDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
                    $compressedSize = $archiveInfo.Length
                    $compressionRatio = if ($originalSize -gt 0) { [math]::Round($compressedSize / $originalSize, 2) } else { 0 }
                    
                    Write-TestResult "Compression achieved" ($compressionRatio -lt 1.0) "Ratio: $compressionRatio (Original: $originalSize bytes, Compressed: $compressedSize bytes)"
                    
                    # Test archive extraction
                    $extractPath = Join-Path $testDataPath "extracted"
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractPath)
                    
                    $extractedFiles = Get-ChildItem $extractPath -Recurse -File
                    $originalFiles = Get-ChildItem $sourceDir -Recurse -File
                    
                    Write-TestResult "Archive extraction successful" ($extractedFiles.Count -eq $originalFiles.Count) "Extracted: $($extractedFiles.Count), Original: $($originalFiles.Count)"
                    
                    # Cleanup test files
                    Remove-Item $archivePath -Force -ErrorAction SilentlyContinue
                    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                
            }
            catch {
                Write-TestResult "Test archive created" $false $_.Exception.Message
            }
        }
        else {
            Skip-Test "Compression functionality" "No test documents directory found"
        }
        
    }
    catch {
        Write-TestResult "Compression tests" $false $_.Exception.Message
    }
}

# Test backup script execution (dry run)
function Test-BackupScriptExecution {
    param (
        [string]$configPath
    )
    
    Write-Host "`n=== Backup Script Execution Tests ===" -ForegroundColor Cyan
    
    try {
        $backupScript = Join-Path $PSScriptRoot ".." "infrastructure" "scripts" "backup.ps1"
        
        # Test backup script exists
        $scriptExists = Test-Path $backupScript
        Write-TestResult "Backup script exists" $scriptExists "Path: $backupScript"
        
        if (!$scriptExists) {
            return
        }
        
        # Test script syntax (PowerShell parsing)
        try {
            $scriptContent = Get-Content $backupScript -Raw
            [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$null) | Out-Null
            Write-TestResult "Backup script syntax valid" $true
        }
        catch {
            Write-TestResult "Backup script syntax valid" $false $_.Exception.Message
        }
        
        # Test script help functionality
        try {
            $helpOutput = & $backupScript -? 2>&1
            $hasHelp = $helpOutput -like "*SYNOPSIS*" -or $helpOutput -like "*DESCRIPTION*"
            Write-TestResult "Backup script help available" $hasHelp
        }
        catch {
            Write-TestResult "Backup script help available" $false $_.Exception.Message
        }
        
        # Test script with test mode (dry run)
        if ($TestUpload) {
            Skip-Test "Backup script dry run execution" "TestUpload specified - will test actual upload instead"
        }
        else {
            try {
                Write-Host "    Running backup script in test mode..." -ForegroundColor Gray
                $testOutput = & $backupScript -ConfigFile $configPath -TestMode $true -Verbose 2>&1
                $testSuccessful = $LASTEXITCODE -eq 0
                
                # Check for expected output patterns
                $hasProcessingOutput = $testOutput -like "*Processing*" -or $testOutput -like "*files*" -or $testOutput -like "*TEST MODE*"
                
                Write-TestResult "Backup script dry run execution" $testSuccessful "Output patterns found: $hasProcessingOutput"
                
                if (($VerbosePreference -eq 'Continue') -and $testOutput) {
                    Write-Host "        Script output:" -ForegroundColor Gray
                    $testOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
                }
                
            }
            catch {
                Write-TestResult "Backup script dry run execution" $false $_.Exception.Message
            }
        }
        
    }
    catch {
        Write-TestResult "Backup script execution tests" $false $_.Exception.Message
    }
}

# Test actual S3 upload (if requested)
function Test-S3Upload {
    param (
        [string]$configPath
    )
    
    if (!$TestUpload) {
        Skip-Test "S3 upload functionality" "TestUpload not specified"
        return
    }
    
    Write-Host "`n=== S3 Upload Tests ===" -ForegroundColor Cyan
    Write-Host "WARNING: This will incur small AWS charges!" -ForegroundColor Red
    
    try {
        # Get bucket name
        $bucketName = $env:BACKUP_BUCKET_NAME
        if (!$bucketName) {
            # Use environment-aware stack name (default to dev for tests)
            $testEnvironment = $env:DR_ENVIRONMENT ?? "dev"
            $stackName = "disaster-recovery-main-$testEnvironment"
            $bucketName = aws cloudformation describe-stacks --stack-name "$stackName" --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" --output text 2>$null
        }
        
        if (!$bucketName) {
            Write-TestResult "S3 bucket accessible for upload" $false "Bucket name not found"
            return
        }
        
        Write-TestResult "S3 bucket name retrieved" $true "Bucket: $bucketName"
        
        # Test bucket access
        try {
            aws s3api head-bucket --bucket $bucketName 2>$null
            Write-TestResult "S3 bucket accessible for upload" ($LASTEXITCODE -eq 0)
        }
        catch {
            Write-TestResult "S3 bucket accessible for upload" $false $_.Exception.Message
            return
        }
        
        # Run backup script with actual upload
        $backupScript = Join-Path $PSScriptRoot ".." "infrastructure" "scripts" "backup.ps1"
        
        try {
            Write-Host "    Running backup script with S3 upload..." -ForegroundColor Gray
            $uploadOutput = & $backupScript -ConfigFile $configPath -TestMode $false -Verbose 2>&1
            $uploadSuccessful = $LASTEXITCODE -eq 0
            
            Write-TestResult "Backup script S3 upload execution" $uploadSuccessful
            
            if ($uploadSuccessful) {
                # Verify upload by checking S3
                Start-Sleep -Seconds 5  # Give S3 a moment to process
                
                $timestamp = Get-Date -Format "yyyy/MM/dd"
                $listOutput = aws s3 ls "s3://$bucketName/backups/$timestamp/" 2>$null
                $hasBackupFiles = $listOutput -and $listOutput.Length -gt 0
                
                Write-TestResult "Backup files uploaded to S3" $hasBackupFiles "Found files in S3"
                
                if ($hasBackupFiles -and ($VerbosePreference -eq 'Continue')) {
                    Write-Host "        S3 contents:" -ForegroundColor Gray
                    $listOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
                }
            }
            
            if (($VerbosePreference -eq 'Continue') -and $uploadOutput) {
                Write-Host "        Upload output:" -ForegroundColor Gray
                $uploadOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
            }
            
        }
        catch {
            Write-TestResult "Backup script S3 upload execution" $false $_.Exception.Message
        }
        
    }
    catch {
        Write-TestResult "S3 upload tests" $false $_.Exception.Message
    }
}

# Cleanup test data
function Remove-TestData {
    param (
        [string]$testDataPath
    )
    
    if (!$CleanupTestData) {
        Write-Host "`nTest data preserved at: $testDataPath" -ForegroundColor Yellow
        Write-Host "Use -CleanupTestData to automatically remove test data" -ForegroundColor Yellow
        return
    }
    
    Write-Host "`n=== Cleaning Up Test Data ===" -ForegroundColor Cyan
    
    try {
        if ($testDataPath -and (Test-Path $testDataPath)) {
            Remove-Item $testDataPath -Recurse -Force
            $cleanupSuccessful = !(Test-Path $testDataPath)
            Write-TestResult "Test data cleanup" $cleanupSuccessful "Path: $testDataPath"
        }
        else {
            Skip-Test "Test data cleanup" "No test data path specified or path does not exist"
        }
    }
    catch {
        Write-TestResult "Test data cleanup" $false $_.Exception.Message
    }
}

# Main test execution
function Invoke-BackupTests {
    Write-Host "=== Disaster Recovery Backup Tests ===" -ForegroundColor Magenta
    Write-Host "Started: $($script:TestResults.StartTime)"
    
    if ($TestUpload) {
        Write-Host "⚠️  WARNING: TestUpload is enabled. This will incur AWS charges!" -ForegroundColor Red
    }
    
    Write-Host ""
    
    # Create test data if requested or if no config file specified
    $testDataPath = ""
    $configPath = $ConfigFile
    
    if ($CreateTestData -or !$ConfigFile) {
        $testDataPath = New-TestData
        $script:TestResults.TestDataPath = $testDataPath
        
        if (!$ConfigFile) {
            $configPath = New-TestConfiguration -testDataPath $testDataPath
            Write-Host "Created test configuration: $configPath" -ForegroundColor Green
        }
    }
    
    # Run backup functionality tests
    if ($configPath) {
        Test-ConfigurationValidation -configPath $configPath
        Test-FileDiscovery -configPath $configPath
        Test-BackupScriptExecution -configPath $configPath
        Test-S3Upload -configPath $configPath
    }
    else {
        Skip-Test "All backup functionality tests" "No configuration file specified"
    }
    
    # Test compression independently
    if ($testDataPath) {
        Test-CompressionFunctionality -testDataPath $testDataPath
        Remove-TestData -testDataPath $testDataPath
    }
    
    # Summary
    $script:TestResults.EndTime = Get-Date
    $duration = $script:TestResults.EndTime - $script:TestResults.StartTime
    
    Write-Host "`n=== Backup Test Summary ===" -ForegroundColor Magenta
    Write-Host "Total Tests: $($script:TestResults.TotalTests)"
    Write-Host "Passed: $($script:TestResults.PassedTests)" -ForegroundColor Green
    Write-Host "Failed: $($script:TestResults.FailedTests)" -ForegroundColor Red
    Write-Host "Skipped: $($script:TestResults.SkippedTests)" -ForegroundColor Yellow
    Write-Host "Duration: $($duration.ToString('mm\:ss'))"
    
    if ($script:TestResults.TestDataPath -and !$CleanupTestData) {
        Write-Host "Test Data: $($script:TestResults.TestDataPath)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    if ($script:TestResults.FailedTests -gt 0) {
        Write-Host "Failed Tests:" -ForegroundColor Red
        foreach ($next_err in $script:TestResults.Errors) {
            Write-Host "  - $next_err" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    $successRate = if ($script:TestResults.TotalTests -gt 0) { [math]::Round(($script:TestResults.PassedTests / $script:TestResults.TotalTests) * 100, 1) } else { 0 }
    
    if ($script:TestResults.FailedTests -eq 0) {
        Write-Host "🎉 All backup tests passed! Backup functionality is working correctly." -ForegroundColor Green
        return 0
    }
    elseif ($successRate -ge 80) {
        Write-Host "⚠️  Most backup tests passed ($successRate%). Check failed tests above." -ForegroundColor Yellow
        return 1
    }
    else {
        Write-Host "❌ Many backup tests failed ($successRate%). Backup functionality may have issues." -ForegroundColor Red
        return 2
    }
}

# Execute tests
try {
    $exitCode = Invoke-BackupTests
    exit $exitCode
}
catch {
    Write-Host "❌ Backup test execution failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}