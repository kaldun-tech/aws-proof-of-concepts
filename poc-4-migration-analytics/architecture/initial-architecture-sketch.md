# AWS Migration Architecture Diagram (Mermaid)

Below is a Mermaid representation of the AWS migration architecture. Note that Mermaid doesn't support AWS-specific icons, so we're using standard shapes with labels.

```mermaid
flowchart TB
    %% Define styles
    classDef aws fill:#FF9900,stroke:#232F3E,color:#232F3E
    classDef vpc fill:#E9F3E6,stroke:#7AA116,stroke-width:2px
    classDef publicSubnet fill:#B5FFFF,stroke:#1A73E8,stroke-width:1px
    classDef privateSubnet fill:#F3F2E9,stroke:#7AA116,stroke-width:1px
    classDef database fill:#3B48CC,stroke:#0A215C,color:white
    classDef storage fill:#3F8624,stroke:#0A215C,color:white
    classDef compute fill:#D86613,stroke:#0A215C,color:white
    classDef analytics fill:#C925D1,stroke:#0A215C,color:white
    classDef security fill:#DD344C,stroke:#0A215C,color:white

    %% External Users
    Users((Internet Users))
    OnPrem[On-Premises Data Center]

    %% AWS Cloud boundary
    subgraph AWS["AWS Cloud"]
        %% VPC and Network Components
        subgraph VPC["VPC"]
            %% Public Subnets
            subgraph PublicSubnets["Public Subnets (Multiple AZs)"]
                IGW[Internet Gateway]
                ELB[Elastic Load Balancer]
                NAT[NAT Gateway]
            end

            %% Private Subnets - Application Tier
            subgraph AppSubnets["Private Subnets - Application Tier"]
                ASG[Auto Scaling Group]
                EC2_1[EC2 Instance]
                EC2_2[EC2 Instance]
            end

            %% Private Subnets - Database Tier
            subgraph DBSubnets["Private Subnets - Database Tier"]
                Aurora[(Aurora MySQL)]
                AuroraReplica[(Aurora Read Replica)]
            end

            %% Private Subnets - Analytics
            subgraph AnalyticsSubnets["Private Subnets - Analytics"]
                EMR[EMR Cluster]
                Glue[AWS Glue]
            end
        end

        %% Global Services
        S3[(S3 Data Lake)]
        CloudFront[CloudFront]
        Route53[Route 53]
        
        %% Analytics Services
        Athena[Amazon Athena]
        QuickSight[Amazon QuickSight]
        
        %% Security Services
        IAM[IAM]
        KMS[KMS]
        WAF[WAF & Shield]
        
        %% Management Services
        CloudWatch[CloudWatch]
        CloudTrail[CloudTrail]
        SSM[Systems Manager]
    end

    %% Data Migration
    DataSync[AWS DataSync]
    Snowball[AWS Snowball]
    DirectConnect[Direct Connect/VPN]

    %% Connections
    Users --> CloudFront
    CloudFront --> S3
    CloudFront --> ELB
    OnPrem --> DataSync
    OnPrem --> Snowball
    OnPrem --> DirectConnect
    DataSync --> S3
    Snowball --> S3
    DirectConnect --> VPC
    
    IGW --> ELB
    ELB --> ASG
    ASG --> EC2_1 & EC2_2
    EC2_1 & EC2_2 --> Aurora
    EC2_1 & EC2_2 --> NAT
    NAT --> IGW
    
    Aurora --> AuroraReplica
    
    S3 <--> EMR
    S3 <--> Glue
    EMR --> Athena
    Glue --> Athena
    Athena --> QuickSight
    
    %% Apply styles
    class AWS,S3,CloudFront,Route53,IAM,KMS,WAF,CloudWatch,CloudTrail,SSM,Athena,QuickSight,DataSync,Snowball,DirectConnect aws
    class VPC vpc
    class PublicSubnets,IGW,ELB,NAT publicSubnet
    class AppSubnets,DBSubnets,AnalyticsSubnets,EC2_1,EC2_2,ASG privateSubnet
    class Aurora,AuroraReplica database
    class S3 storage
    class EC2_1,EC2_2,ASG,EMR compute
    class EMR,Glue,Athena,QuickSight analytics
    class IAM,KMS,WAF security
```

## Notes on the Mermaid Diagram

1. This is a simplified representation. For a professional AWS architecture diagram, use the AWS Architecture Icons with a tool like diagrams.net.

2. The diagram shows:
   - Web application components (CloudFront, ELB, EC2, Aurora)
   - Data analytics components (EMR, Glue, Athena, QuickSight)
   - Data migration paths (DataSync, Snowball, Direct Connect)
   - Security and management services

3. For a complete diagram with proper AWS icons, use the instructions in the diagram-instructions.md file.

## Recommended Next Steps

1. Use diagrams.net with AWS Architecture Icons for a professional diagram
2. Add more details to show multi-AZ deployment
3. Include CI/CD pipeline components
4. Show data flow paths more explicitly
