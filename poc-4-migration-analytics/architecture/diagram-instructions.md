# Architecture Diagram Instructions

## Diagram Requirements

Create a high-level architecture diagram that depicts the migration of on-premises workloads to AWS, including:

1. Three-tier web application migration
2. Data analytics workload migration

## Tools

Use one of the following tools to create your diagram:
- [diagrams.net](https://app.diagrams.net/?splash=0&libs=aws4) (recommended)
- [Lucidchart](https://www.lucidchart.com/pages/aws-architecture-diagram)
- [Draw.io](https://draw.io/) with AWS icons

## AWS Architecture Icons

Download the official AWS Architecture Icons from:
- [AWS Architecture Icons](https://aws.amazon.com/architecture/icons/)

## Diagram Components

### Web Application Architecture
1. **Frontend Layer**:
   - Amazon S3 bucket for static content
   - Amazon CloudFront distribution

2. **Application Layer**:
   - Application Load Balancer
   - EC2 instances in Auto Scaling Group across multiple AZs
   - Optional: Elastic Beanstalk or ECS/EKS for containerized approach

3. **Database Layer**:
   - Amazon RDS for MySQL or Aurora MySQL-compatible
   - Multi-AZ deployment

### Data Analytics Architecture
1. **Data Storage**:
   - Amazon S3 data lake

2. **Data Processing**:
   - Amazon EMR cluster
   - EMR Notebooks for interactive analysis

3. **Data Ingestion**:
   - AWS Glue for ETL
   - Optional: Amazon Kinesis for real-time data

4. **Visualization**:
   - Amazon QuickSight dashboards

### Networking Components
1. **VPC with public and private subnets**
2. **Security Groups and NACLs**
3. **Internet Gateway and NAT Gateway**
4. **Optional: Direct Connect or VPN for hybrid connectivity**

## Diagram Structure

1. Clearly separate the web application and data analytics workloads
2. Use color coding to distinguish between different layers
3. Include arrows to show data flow
4. Add brief annotations to explain key components
5. Show multi-AZ deployment for high availability

## Example Layout

```
+--------------------------------------------------+
|                     AWS Cloud                     |
|  +----------------+        +------------------+   |
|  | Web Application|        | Data Analytics   |   |
|  | Architecture   |        | Architecture     |   |
|  +----------------+        +------------------+   |
|                                                   |
+--------------------------------------------------+
```

## Save Your Diagram

Save your diagram in the following formats:
1. Native format of your diagramming tool (.drawio, .vsdx, etc.)
2. PNG or SVG for easy viewing
3. PDF for high-quality printing

Place all files in the `architecture` directory of this project.
