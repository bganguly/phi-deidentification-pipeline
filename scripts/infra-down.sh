#!/usr/bin/env bash
# infra-down.sh — tear down local Docker, GCP Cloud Run, or AWS ECS/RDS resources
# Usage: ./scripts/infra-down.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT/infra/aws"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

_aws_deployed=0
[[ -f "$INFRA_DIR/terraform.tfstate.d/lite/terraform.tfstate" ]] && _aws_deployed=1 || true

_gcp_deployed=0
_GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if gcloud run services describe phi-pipeline-api --region=us-central1 \
    --project="${_GCP_PROJECT:-_}" --format='value(metadata.name)' >/dev/null 2>&1; then
  _gcp_deployed=1
fi

printf '\n=== phi-deidentification-pipeline teardown ===\n\n'
printf '  [1] Local  — stop Docker Compose stack\n'
printf '  [2] GCP    — Cloud Run phi-pipeline-api'
(( _gcp_deployed )) && printf ' [deployed]' || printf ' [not detected]'
printf '\n'
printf '  [3] AWS    — ECS Fargate + RDS + ECR  (~$50-70/mo if running)'
(( _aws_deployed )) && printf ' [deployed]' || printf ' [not deployed]'
printf '\n'
printf '\nChoice [1/2/3, default 2]: '
read -r _MODE

case "${_MODE:-2}" in
  1) _TARGET="local" ;;
  3) _TARGET="aws" ;;
  *) _TARGET="gcp" ;;
esac

# ── Local ─────────────────────────────────────────────────────────────────────
if [[ "$_TARGET" == "local" ]]; then
  command -v docker >/dev/null 2>&1 || { red 'Docker not installed.'; exit 1; }
  docker compose -f "$ROOT/docker-compose.yml" down -v
  green 'Local stack stopped.'
  exit 0
fi

# ── GCP Cloud Run ─────────────────────────────────────────────────────────────
if [[ "$_TARGET" == "gcp" ]]; then
  command -v gcloud >/dev/null 2>&1 || { red 'gcloud CLI not found.'; exit 1; }

  GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  [[ -z "$GCP_PROJECT" ]] && read -rp '  GCP Project ID: ' GCP_PROJECT
  GCP_REGION="${GCP_REGION:-us-central1}"
  SERVICE_NAME="phi-pipeline-api"

  _STATUS="$(gcloud run services describe "$SERVICE_NAME" \
    --region="$GCP_REGION" --project="$GCP_PROJECT" \
    --format='value(status.conditions[0].status)' 2>/dev/null || echo 'not found')"

  printf '\n  Cloud Run %s: %s\n' "$SERVICE_NAME" "${_STATUS}"
  printf '  Cloud Run scales to zero automatically — no cost when idle.\n'
  printf '\n  [enter] Delete service permanently  [ctrl-c] Abort: '
  read -r _CONFIRM
  [[ "${_CONFIRM:-y}" =~ ^[Yy]$|^$ ]] || { red 'Aborted.'; exit 1; }

  printf '\n  Confirm delete %s? [Y/n]: ' "$SERVICE_NAME"
  read -r _CONFIRM2
  [[ "${_CONFIRM2:-y}" =~ ^[Yy]$ ]] || { red 'Aborted.'; exit 1; }

  gcloud run services delete "$SERVICE_NAME" \
    --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null \
    && green "  Deleted Cloud Run service: $SERVICE_NAME" \
    || dim '  Service not found or already deleted.'

  green '\nGCP teardown complete.'
  printf '  Redeploy: %s/scripts/deploy.sh\n' "$ROOT"
  exit 0
fi

# ── AWS ECS ───────────────────────────────────────────────────────────────────
command -v aws       >/dev/null 2>&1 || { red 'aws CLI not found.'; exit 1; }
command -v terraform >/dev/null 2>&1 || { red 'terraform not found.'; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 \
  || { red 'AWS credentials not configured — run: aws configure'; exit 1; }
dim "  Credentials: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"

DEPLOY_WORKSPACE="lite"
TF_VAR_name_prefix="phi-lite"
_CLUSTER="${TF_VAR_name_prefix}-cluster"
_PIPELINE_SVC="${TF_VAR_name_prefix}-pipeline"

_DESIRED="$(aws ecs describe-services --cluster "$_CLUSTER" --services "$_PIPELINE_SVC" \
  --query 'services[0].desiredCount' --output text 2>/dev/null || echo 'n/a')"

printf '\n  ECS pipeline (%s) desired count: %s\n' "$_PIPELINE_SVC" "${_DESIRED}"
printf '  [1] Start (desired=1)  [2] Stop (desired=0, no compute charges)  [enter] Tear down: '
read -r _PRE

case "${_PRE:-}" in
  1)
    aws ecs update-service --cluster "$_CLUSTER" --service "$_PIPELINE_SVC" \
      --desired-count 1 --no-cli-pager >/dev/null \
      && green '  Pipeline starting.' || red '  Failed to start.'
    exit 0
    ;;
  2)
    aws ecs update-service --cluster "$_CLUSTER" --service "$_PIPELINE_SVC" \
      --desired-count 0 --no-cli-pager >/dev/null \
      && green '  Pipeline stopped (desired=0).' || red '  Failed to stop.'
    printf '\n  Note: RDS still running (~$15/mo). Tear down fully to eliminate all cost.\n'
    exit 0
    ;;
esac

if (( ! _aws_deployed )); then
  red '  No Terraform state found for workspace "lite" — nothing to tear down.'
  exit 0
fi

cd "$INFRA_DIR"
terraform init -input=false -upgrade >/dev/null
terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null \
  || { red "Terraform workspace '$DEPLOY_WORKSPACE' not found."; exit 0; }

_API_ECR="$(terraform output -raw api_ecr_uri 2>/dev/null | sed 's|.*/||' || true)"
_WORKER_ECR="$(terraform output -raw worker_ecr_uri 2>/dev/null | sed 's|.*/||' || true)"

printf '\n  This will destroy:\n'
printf '    ECS Fargate cluster + service: %s\n' "$_CLUSTER"
printf '    RDS PostgreSQL — DATA PERMANENTLY DELETED\n'
[[ -n "$_API_ECR" ]]    && printf '    ECR repo: %s\n' "$_API_ECR"
[[ -n "$_WORKER_ECR" ]] && printf '    ECR repo: %s\n' "$_WORKER_ECR"
printf '    ALB, VPC subnets, EventBridge rules, SSM params\n'
printf '\n  Proceed? [Y/n]: '
read -r _CONFIRM
[[ "${_CONFIRM:-y}" =~ ^[Yy]$ ]] || { red 'Aborted.'; exit 1; }

bold 'Stopping ECS service...'
aws ecs update-service --cluster "$_CLUSTER" --service "$_PIPELINE_SVC" \
  --desired-count 0 --no-cli-pager >/dev/null 2>/dev/null || true
green '  ECS service stopped.'

for _REPO in "$_API_ECR" "$_WORKER_ECR"; do
  [[ -z "$_REPO" ]] && continue
  bold "Flushing ECR images: $_REPO"
  _IDS="$(aws ecr list-images --repository-name "$_REPO" \
    --query 'imageIds[*]' --output json --no-cli-pager 2>/dev/null || echo '[]')"
  if [[ "$_IDS" != "[]" && "$_IDS" != "" ]]; then
    aws ecr batch-delete-image --repository-name "$_REPO" \
      --image-ids "$_IDS" --no-cli-pager >/dev/null 2>/dev/null \
      && green "  Deleted images from $_REPO" || dim '  ECR delete skipped'
  else
    dim "  $_REPO already empty"
  fi
done

bold 'Running terraform destroy...'
terraform destroy -auto-approve -input=false \
  -var "name_prefix=${TF_VAR_name_prefix}"

green '\nAWS infrastructure torn down.'
printf '  Redeploy: %s/scripts/deploy.sh\n' "$ROOT"
