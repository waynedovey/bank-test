#!/bin/bash
# Guardium Collector Security Group Setup
# Region: ap-southeast-2
# VPC: vpc-0a4ba92d83f569956

REGION="ap-southeast-2"
VPC_ID="vpc-0a4ba92d83f569956"
SG_NAME="GuardiumCollectorSG"

# Try to fetch existing SG
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=$SG_NAME Name=vpc-id,Values=$VPC_ID \
  --region $REGION \
  --query 'SecurityGroups[0].GroupId' --output text)

if [ "$SG_ID" == "None" ]; then
  echo "Security Group does not exist. Creating new one..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name $SG_NAME \
    --description "IBM Guardium Data Protection Collector - Open Access" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query 'GroupId' --output text)
else
  echo "Reusing existing Security Group: $SG_ID"
fi

# Now apply rules
echo "Adding inbound rules to SG: $SG_ID"

# SSH
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION || true

# Guardium Web UI
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8443 --cidr 0.0.0.0/0 --region $REGION || true

# GIM
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8081 --cidr 0.0.0.0/0 --region $REGION || true
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8444-8446 --cidr 0.0.0.0/0 --region $REGION || true

# Unix STAP
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 16016-16018 --cidr 0.0.0.0/0 --region $REGION || true

# Windows STAP
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 9500-9501 --cidr 0.0.0.0/0 --region $REGION || true

# Quick Search
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8983 --cidr 0.0.0.0/0 --region $REGION || true
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 9983 --cidr 0.0.0.0/0 --region $REGION || true

# MySQL
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 3306 --cidr 0.0.0.0/0 --region $REGION || true

# Verify
aws ec2 describe-security-groups --group-ids $SG_ID --region $REGION
