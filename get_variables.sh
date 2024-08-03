#!/bin/bash
# Fetch public IP
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)

# Fetch other dynamic variables
PROJECT_ID=$(gcloud config get-value project)
REGION=$(gcloud config get-value compute/region)
ZONE=$(gcloud config get-value compute/zone)
USERNAME=$(whoami)

# Fetch the service account email dynamically
SERVICE_ACCOUNT_EMAIL=$(gcloud iam service-accounts list --filter="displayName:cs service acct" --format="value(email)")

# Export the variables in TF_VAR format
export TF_VAR_project=$PROJECT_ID
export TF_VAR_region=$REGION
export TF_VAR_zone=$ZONE
export TF_VAR_public_ip=$PUBLIC_IP
export TF_VAR_username=$USERNAME
export TF_VAR_service_account_email=$SERVICE_ACCOUNT_EMAIL

echo "Environment variables set for Terraform:"
echo "TF_VAR_project=$TF_VAR_project"
echo "TF_VAR_region=$TF_VAR_region"
echo "TF_VAR_zone=$TF_VAR_zone"
echo "TF_VAR_public_ip=$TF_VAR_public_ip"
echo "TF_VAR_username=$TF_VAR_username"
echo "TF_VAR_service_account_email=$TF_VAR_service_account_email"

