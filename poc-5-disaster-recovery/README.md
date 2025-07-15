# Personal Computer Disaster Recovery Proof of Concept

## Overview
This proof of concept demonstrates a cost-effective disaster recovery solution for personal computer files using AWS Glacier Deep Archive storage. The implementation focuses on automated backup workflows, long-term data retention, and simple restore processes for critical personal data.

## Business Context
Many individuals and small businesses need reliable backup solutions for important documents, photos, and files but want to minimize storage costs. This POC leverages AWS Glacier Deep Archive, the lowest-cost storage class, providing durable backup storage at approximately $1 per TB per month.

## Architecture
The solution follows this workflow:
1. Local PowerShell scripts identify and compress files for backup
2. Files are uploaded to S3 with immediate transition to Glacier Deep Archive
3. CloudWatch logs track backup operations and success/failure rates
4. Restore process initiates retrieval jobs and downloads files when ready
5. Lifecycle policies manage backup retention and cleanup

## Directory Structure
```
poc-5-disaster-recovery/
├── docs/                       # Documentation
│   └── images/                 # Architecture diagrams
├── infrastructure/             # Infrastructure as Code
│   ├── cloudformation/         # CloudFormation templates
│   │   ├── iam.yaml            # IAM policies and roles
│   │   ├── s3.yaml             # S3 bucket and policies
│   │   └── cloudwatch.yaml     # CloudWatch logging and monitoring
│   └── scripts/                # Deployment and utility scripts
│       ├── deploy.ps1          # Infrastructure deployment
│       ├── teardown.ps1        # Infrastructure removal
│       ├── backup.ps1          # File backup script
│       └── restore.ps1         # File restore script
├── examples/                   # Example configurations
│   └── backup-config.json      # Sample backup configuration
└── README.md                   # This file
```

## Implementation Plan

1. Set up IAM policies and roles
   - Create CloudFormation templates for IAM resources
   - Define policies for S3 Glacier Deep Archive access
   - Implement least privilege access for backup operations

2. Create S3 bucket with Glacier Deep Archive
   - Create CloudFormation template for S3 bucket
   - Configure immediate transition to Glacier Deep Archive
   - Set up bucket policies for secure access
   - Enable versioning for data protection

3. Implement backup automation
   - Create PowerShell script for file discovery and compression
   - Implement incremental backup logic
   - Add progress tracking and error handling
   - Create backup scheduling capabilities

4. Create restore workflows
   - Implement Glacier retrieval job initiation
   - Create restore job monitoring
   - Add download automation once files are available
   - Provide restore verification

5. Add monitoring and logging
   - CloudWatch logs for backup operations
   - S3 inventory reports for backup verification
   - Cost tracking and alerts
   - Backup success/failure notifications

## Key Features

### Cost Optimization
- **Glacier Deep Archive**: Lowest cost storage at ~$1/TB/month
- **Intelligent compression**: Automatic file compression before upload
- **Lifecycle management**: Automatic cleanup of old backups
- **Incremental backups**: Only upload changed files

### Data Protection
- **Encryption**: All data encrypted in transit and at rest
- **Versioning**: Multiple versions of files retained
- **Cross-region replication**: Optional for critical data
- **Integrity checking**: Automated verification of uploaded files

### Ease of Use
- **Simple configuration**: JSON-based backup rules
- **Automated scheduling**: Windows Task Scheduler integration
- **Progress tracking**: Real-time backup progress and logs
- **Flexible restore**: Selective file restoration

## Deployment and Teardown Instructions

### Prerequisites
- AWS CLI installed and configured with appropriate credentials
- PowerShell 5.1 or later
- S3 bucket name for CloudFormation templates (bucket will be created automatically if it doesn't exist)
- At least 1GB free disk space for temporary compression
- Windows 10 or later (scripts can be adapted for other platforms)

### Deployment

This project includes a comprehensive PowerShell deployment script that handles all aspects of deploying the infrastructure.

#### Deploy the Entire Stack

```powershell
# Navigate to the scripts directory
cd infrastructure/scripts

# Deploy all components
./deploy.ps1 -Environment dev -BackupBucketName your-backup-bucket-name -UserEmail your-email@example.com
```

#### Deployment Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Deployment environment (dev, test, prod) | Yes | - |
| BackupBucketName | S3 bucket name for backups (must be globally unique) | Yes | - |
| UserEmail | Email address for backup notifications | Yes | - |
| Region | AWS region for deployment | No | us-east-1 |
| RetentionYears | Years to retain backups | No | 7 |

### Setting Up Backups

After infrastructure deployment, configure your backup settings:

```powershell
# Copy and customize the backup configuration
cp examples/backup-config.json backup-config.json

# Edit backup-config.json to specify:
# - Folders to backup
# - File patterns to include/exclude
# - Backup schedule
# - Compression settings

# Run initial backup
./infrastructure/scripts/backup.ps1 -ConfigFile backup-config.json
```

### Teardown

To remove the deployed infrastructure:

```powershell
# Navigate to the scripts directory
cd infrastructure/scripts

# Remove all components (WARNING: This will delete all backup data)
./teardown.ps1 -Environment dev -Force $false
```

#### Teardown Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|--------|
| Environment | Environment name (dev, test, prod) | No | dev |
| Force | Skip confirmation prompt | No | $false |
| EmptyBucket | Automatically empty S3 bucket before deletion | No | $true |

## Backup Configuration

### Example backup-config.json

```json
{
  "backupName": "PersonalFiles",
  "compression": {
    "enabled": true,
    "level": 6,
    "format": "zip"
  },
  "schedule": {
    "frequency": "daily",
    "time": "02:00"
  },
  "paths": [
    {
      "source": "C:\\Users\\%USERNAME%\\Documents",
      "include": ["*.pdf", "*.docx", "*.xlsx", "*.txt"],
      "exclude": ["temp/*", "cache/*"]
    },
    {
      "source": "C:\\Users\\%USERNAME%\\Pictures",
      "include": ["*.jpg", "*.png", "*.raw", "*.tiff"],
      "exclude": ["thumbnails/*"]
    }
  ],
  "retention": {
    "keepDaily": 30,
    "keepWeekly": 12,
    "keepMonthly": 12,
    "keepYearly": 7
  }
}
```

## Restore Process

### Initiating a Restore

```powershell
# List available backups
./infrastructure/scripts/restore.ps1 -Action list

# Initiate restore job for specific backup
./infrastructure/scripts/restore.ps1 -Action initiate -BackupDate 2024-01-15 -RestoreType expedited

# Check restore job status
./infrastructure/scripts/restore.ps1 -Action status -JobId your-job-id

# Download restored files
./infrastructure/scripts/restore.ps1 -Action download -JobId your-job-id -DestinationPath C:\Restored
```

### Restore Options

| Type | Retrieval Time | Cost | Use Case |
|------|---------------|------|----------|
| Standard | 12 hours | Lowest | Regular restore operations |
| Expedited | 1-5 minutes | Higher | Emergency file recovery |
| Bulk | 5-12 hours | Lowest for large amounts | Massive data restore |

## Cost Estimation

### Monthly Storage Costs (Glacier Deep Archive)
- 100 GB: ~$0.10
- 1 TB: ~$1.00
- 5 TB: ~$5.00
- 10 TB: ~$10.00

### Restore Costs (per GB)
- Standard: $0.02
- Expedited: $0.10
- Bulk: $0.0025

### Additional Costs
- PUT requests: $0.05 per 1,000 requests
- Lifecycle transitions: $0.05 per 1,000 requests
- Early deletion: Pro-rated if deleted within 180 days

## Security Features

### Data Protection
- **Client-side encryption**: Files encrypted before upload
- **Server-side encryption**: S3-managed encryption (SSE-S3)
- **Access logging**: All bucket access logged
- **IAM policies**: Principle of least privilege

### Access Control
- **Dedicated IAM user**: Backup-only permissions
- **MFA requirements**: Optional for restore operations
- **VPC endpoints**: Optional for private network access
- **Bucket policies**: Restrict access by IP/time

## Monitoring and Alerts

### CloudWatch Metrics
- Backup success/failure rates
- Data transfer volumes
- Storage usage trends
- Cost monitoring

### Notifications
- Backup completion status
- Restore job completion
- Cost threshold alerts
- Error notifications

## Best Practices

### Backup Strategy
- **Test restores regularly**: Verify backup integrity
- **Document recovery procedures**: Keep restore instructions accessible
- **Monitor costs**: Set up billing alerts
- **Version control**: Keep multiple versions of critical files

### Security
- **Regular access reviews**: Audit IAM permissions
- **Encrypt sensitive data**: Additional encryption for PII
- **Secure credentials**: Use IAM roles instead of access keys
- **Network security**: Consider VPC endpoints for additional security

## Limitations and Considerations

### Glacier Deep Archive Limitations
- **Minimum storage duration**: 180 days
- **Retrieval time**: 12+ hours for standard retrieval
- **Minimum object size**: Objects smaller than 128KB charged as 128KB
- **Request costs**: Charges apply for PUT, GET, and lifecycle operations

### Use Case Suitability
- **Ideal for**: Long-term archival, disaster recovery, compliance backups
- **Not ideal for**: Frequently accessed files, real-time backup needs
- **Consider alternatives**: S3 Standard-IA or Glacier Instant Retrieval for more frequent access

## Testing

### Backup Testing
```powershell
# Test backup configuration
./infrastructure/scripts/backup.ps1 -ConfigFile backup-config.json -TestMode $true

# Verify backup integrity
./infrastructure/scripts/backup.ps1 -Action verify -BackupDate 2024-01-15
```

### Restore Testing
```powershell
# Test restore process with small file
./infrastructure/scripts/restore.ps1 -Action test -RestoreType expedited
```

## Troubleshooting

### Common Issues
- **Upload failures**: Check network connectivity and file permissions
- **High costs**: Review lifecycle policies and request patterns
- **Slow restores**: Verify retrieval type and job status
- **Access denied**: Check IAM policies and bucket permissions

### Log Locations
- Backup logs: `%TEMP%\aws-backup-logs\`
- CloudWatch logs: `/aws/s3/disaster-recovery-backups`
- AWS CLI logs: `%USERPROFILE%\.aws\cli\cache\`

## References

- [AWS Glacier Deep Archive Documentation](https://docs.aws.amazon.com/amazonglacier/latest/dev/introduction.html)
- [S3 Lifecycle Management](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
- [AWS Backup Best Practices](https://docs.aws.amazon.com/aws-backup/latest/devguide/best-practices.html)