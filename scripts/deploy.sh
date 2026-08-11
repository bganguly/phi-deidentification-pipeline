#!/usr/bin/env bash
# Usage: ./scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

_aws_tf_ws_count() {
  local ws="$1"
  local state_file="$ROOT_DIR/infra/aws/terraform.tfstate.d/$ws/terraform.tfstate"
  [[ -f "$state_file" ]] || { printf '0'; return; }
  python3 -c "import json; d=json.load(open('$state_file')); print(sum(len(r.get('instances',[])) for r in d.get('resources',[])))" 2>/dev/null || printf '0'
}
_aws_lite_count=$(_aws_tf_ws_count lite)

_scan_sibling_keys() {
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && return
  local parent_dir dir env_file candidate found_in
  parent_dir="$(cd "${ROOT_DIR}/.." && pwd)"
  for dir in "${parent_dir}"/*/; do
    [[ -d "$dir" ]] || continue
    dir="$(cd "$dir" && pwd)"
    [[ "$dir" == "$ROOT_DIR" ]] && continue
    env_file="${dir}/.env"
    [[ -f "$env_file" ]] || continue
    candidate="$(grep "^ANTHROPIC_API_KEY=sk-ant" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [[ -n "$candidate" ]]; then
      found_in="$(basename "$dir")"
      printf '  Found ANTHROPIC_API_KEY in sibling repo: %s\n' "$found_in"
      export ANTHROPIC_API_KEY="$candidate"
      return
    fi
  done
}

printf '\n=== phi-deidentification-pipeline ===\n\n'
printf '  [1] Local  — Docker Compose local stack\n'
printf '  [2] Cloud  — GCP Cloud Run\n'
printf '  [3] Down   — tear down local Docker stack\n'
printf '  [4] Lite   — AWS: ECS Fargate + RDS db.t3.micro  (~$50-70/mo if left running)'
(( _aws_lite_count > 0 )) && printf ' [%s resources active]' "$_aws_lite_count" || printf ' [not deployed]'
printf '\n\nChoice [1/2/3/4]: '
read -r _MODE
case "$_MODE" in
  2) TARGET="cloud" ;;
  3) TARGET="down" ;;
  4) TARGET="aws"; DEPLOY_WORKSPACE="lite"; TF_VAR_name_prefix="phi-lite"
     TF_VAR_task_cpu=1024; TF_VAR_task_memory=2048
     TF_VAR_db_instance_class="db.t3.micro"
     export DEPLOY_WORKSPACE TF_VAR_name_prefix TF_VAR_task_cpu TF_VAR_task_memory TF_VAR_db_instance_class
     ;;
  *) TARGET="local" ;;
esac

# ── Down ──────────────────────────────────────────────────────────────────────
if [[ "${TARGET}" == "down" ]]; then
  docker compose -f "${ROOT_DIR}/docker-compose.yml" down -v
  echo "✓ Stack stopped."
  exit 0
fi

# ── Local ─────────────────────────────────────────────────────────────────────
if [[ "${TARGET}" == "local" ]]; then
  ENV_FILE="${ROOT_DIR}/.env"
  [[ ! -f "${ENV_FILE}" ]] && cp "${ROOT_DIR}/.env.example" "${ENV_FILE}"
  _scan_sibling_keys
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && ! grep -q "^ANTHROPIC_API_KEY=sk-ant" "${ENV_FILE}" 2>/dev/null; then
    read -rp "Enter your Anthropic API key (sk-ant-...): " _key
    [[ -z "${_key}" ]] && { echo "Error: API key required." >&2; exit 1; }
    export ANTHROPIC_API_KEY="${_key}"
    grep -q "^ANTHROPIC_API_KEY=" "${ENV_FILE}" \
      && sed -i '' "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${_key}|" "${ENV_FILE}" \
      || echo "ANTHROPIC_API_KEY=${_key}" >> "${ENV_FILE}"
  fi
  docker compose -f "${ROOT_DIR}/docker-compose.yml" up --build -d
  echo "✓ API: http://localhost:8000  |  Docs: http://localhost:8000/docs"
  exit 0
fi

# ── GCP Cloud Run ─────────────────────────────────────────────────────────────
if [[ "$TARGET" == "cloud" ]]; then
echo "▶ Cloud Run deploy"

command -v gcloud >/dev/null 2>&1 || { echo "Error: gcloud CLI not found."; exit 1; }

ENV_CLOUD="${ROOT_DIR}/.env.cloud"
[[ -f "${ENV_CLOUD}" ]] || { echo "Error: .env.cloud not found. Add DATABASE_URL, DATABASE_SYNC_URL, REDIS_URL, PIPELINE_ACCESS_TOKEN."; exit 1; }

_cv() { grep "^${1}=" "${ENV_CLOUD}" | cut -d= -f2- || true; }
CLOUD_DB_URL="$(_cv DATABASE_URL)"
CLOUD_DB_SYNC_URL="$(_cv DATABASE_SYNC_URL)"
CLOUD_REDIS_URL="$(_cv REDIS_URL)"
PIPELINE_ACCESS_TOKEN="$(_cv PIPELINE_ACCESS_TOKEN)"
_scan_sibling_keys
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(_cv ANTHROPIC_API_KEY)}"

if [[ -z "${CLOUD_DB_URL}" || -z "${CLOUD_DB_SYNC_URL}" ]]; then
  printf '\nError: Cloud Run deploy requires DATABASE_URL and DATABASE_SYNC_URL in .env.cloud.\n'
  printf '  No cloud database has ever been provisioned for this path (infra covers GKE + AWS only).\n'
  printf '  Add a reachable PostgreSQL URL (e.g. Cloud SQL) to .env.cloud before retrying.\n'
  exit 1
fi
[[ -z "${PIPELINE_ACCESS_TOKEN}" ]] && { echo "Error: PIPELINE_ACCESS_TOKEN missing from .env.cloud"; exit 1; }
if [[ -z "${ANTHROPIC_API_KEY}" ]]; then
  read -rsp "Anthropic API key (sk-ant-...): " ANTHROPIC_API_KEY; echo
  [[ -z "${ANTHROPIC_API_KEY}" ]] && { echo "Error: API key required."; exit 1; }
fi

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
[[ -z "${GCP_PROJECT}" ]] && read -rp "GCP Project ID: " GCP_PROJECT
GCP_REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="phi-pipeline-api"
IMAGE="gcr.io/${GCP_PROJECT}/${SERVICE_NAME}:latest"

echo "▶ Building and pushing image via Cloud Build..."
gcloud builds submit "${ROOT_DIR}" \
  --config "${ROOT_DIR}/cloudbuild.yaml" \
  --project "${GCP_PROJECT}"

echo "▶ Deploying to Cloud Run (${GCP_REGION})..."
gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --region "${GCP_REGION}" \
  --project "${GCP_PROJECT}" \
  --platform managed \
  --allow-unauthenticated \
  --set-env-vars "DATABASE_URL=${CLOUD_DB_URL},DATABASE_SYNC_URL=${CLOUD_DB_SYNC_URL},REDIS_URL=${CLOUD_REDIS_URL},ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY},PIPELINE_ACCESS_TOKEN=${PIPELINE_ACCESS_TOKEN}" \
  --quiet

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" \
  --region "${GCP_REGION}" --project "${GCP_PROJECT}" \
  --format 'value(status.url)')"

echo ""
echo "✓ Live: ${SERVICE_URL}"
echo "  Docs: ${SERVICE_URL}/docs"
exit 0
fi

# ── AWS ECS ───────────────────────────────────────────────────────────────────
printf '\n  Scanning sibling repos for credentials...\n'
_scan_sibling_keys
printf '\n--- AWS Lite summary ---\n'
printf '  Pipeline: ECS Fargate 1 vCPU / 2 GB (api + worker + redis sidecar)\n'
printf '  DB:       RDS PostgreSQL 16 db.t3.micro (20 GB)\n'
printf '  Cost est: ~$50-70/mo if left running — TEAR DOWN when done\n'
printf '\nProceed? [Y/n] '
read -r _CONFIRM
[[ -z "$_CONFIRM" || "$_CONFIRM" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

echo ""
echo "[1/4] Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  printf '  AWS credentials not found or invalid.\n'; exit 1
fi
printf '  Credentials valid.\n'
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "[2/4] Provisioning AWS infra (ECS cluster, ALB, RDS, ECR, EventBridge)..."
"${SCRIPT_DIR}/infra-up-aws.sh"

INFRA_DIR="${ROOT_DIR}/infra/aws"
cd "$INFRA_DIR"
terraform workspace select "$DEPLOY_WORKSPACE" >/dev/null

API_URL=$(terraform output -raw api_url)
API_ECR_URI=$(terraform output -raw api_ecr_uri)
WORKER_ECR_URI=$(terraform output -raw worker_ecr_uri)
CLUSTER_NAME=$(terraform output -raw cluster_name)
PIPELINE_SVC=$(terraform output -raw pipeline_service)
DATABASE_URL=$(terraform output -raw database_url)
DATABASE_SYNC_URL=$(terraform output -raw database_sync_url)
AWS_REGION=$(terraform output -raw aws_region)

echo ""
echo "[3/4] Building and pushing Docker images to ECR..."
if ! docker info >/dev/null 2>&1; then
  printf '  Docker not running — start Docker Desktop and retry.\n'; exit 1
fi
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

TAG=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)

printf '  Building API image...\n'
docker build --platform linux/amd64 -f "${ROOT_DIR}/docker/Dockerfile.api" \
  -t "${API_ECR_URI}:${TAG}" "${ROOT_DIR}"
docker push "${API_ECR_URI}:${TAG}"

printf '  Building Worker image...\n'
docker build --platform linux/amd64 -f "${ROOT_DIR}/docker/Dockerfile.worker" \
  -t "${WORKER_ECR_URI}:${TAG}" "${ROOT_DIR}"
docker push "${WORKER_ECR_URI}:${TAG}"

echo ""
echo "[4/4] Updating Secrets Manager and deploying to ECS..."
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$ANTHROPIC_API_KEY" ]] && [[ -f "${ROOT_DIR}/.env" ]]; then
  ANTHROPIC_API_KEY=$(grep "^ANTHROPIC_API_KEY=" "${ROOT_DIR}/.env" | cut -d= -f2- || true)
fi
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  read -rsp "Anthropic API key (sk-ant-...): " ANTHROPIC_API_KEY; echo
fi
PIPELINE_ACCESS_TOKEN="${PIPELINE_ACCESS_TOKEN:-}"
if [[ -z "$PIPELINE_ACCESS_TOKEN" ]]; then
  PIPELINE_ACCESS_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  printf '  Generated PIPELINE_ACCESS_TOKEN: %s\n' "$PIPELINE_ACCESS_TOKEN"
fi

for _pair in "anthropic-key:${ANTHROPIC_API_KEY}" "pipeline-token:${PIPELINE_ACCESS_TOKEN}"; do
  _pname="/${TF_VAR_name_prefix}/${_pair%%:*}"
  _pval="${_pair#*:}"
  [[ -z "$_pval" ]] && continue
  aws ssm put-parameter --name "$_pname" --value "$_pval" \
    --type SecureString --overwrite --no-cli-pager >/dev/null
  printf '  Updated SSM: %s\n' "$_pname"
done

ANTHROPIC_API_KEY=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/anthropic-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "$ANTHROPIC_API_KEY")
PIPELINE_ACCESS_TOKEN=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/pipeline-token" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "$PIPELINE_ACCESS_TOKEN")

SHARED_ENV=$(python3 -c "import json; print(json.dumps([
  {'name':'DATABASE_URL','value':'${DATABASE_URL}'},
  {'name':'DATABASE_SYNC_URL','value':'${DATABASE_SYNC_URL}'},
  {'name':'REDIS_URL','value':'redis://localhost:6379/0'},
  {'name':'ANTHROPIC_API_KEY','value':'${ANTHROPIC_API_KEY}'},
  {'name':'PIPELINE_ACCESS_TOKEN','value':'${PIPELINE_ACCESS_TOKEN}'}
]))")

cur_def=$(aws ecs describe-task-definition --task-definition "${TF_VAR_name_prefix}-pipeline" --output json 2>/dev/null \
  | python3 -c "import json,sys; td=json.load(sys.stdin)['taskDefinition']; \
    [td.pop(k,None) for k in ['taskDefinitionArn','revision','status','requiresAttributes','compatibilities','registeredAt','registeredBy','deregisteredAt']]; \
    print(json.dumps(td))" 2>/dev/null || echo "")

new_def=$(printf '%s' "$cur_def" | python3 - "${API_ECR_URI}:${TAG}" "${WORKER_ECR_URI}:${TAG}" "$SHARED_ENV" <<'PYEOF'
import json, sys
api_image, worker_image, extra_env_json = sys.argv[1], sys.argv[2], sys.argv[3]
td = json.load(sys.stdin)
extra_env = json.loads(extra_env_json)
for c in td['containerDefinitions']:
    if c['name'] == 'api':
        c['image'] = api_image
    elif c['name'] == 'worker':
        c['image'] = worker_image
    if c['name'] in ('api', 'worker'):
        existing = {e['name'] for e in c.get('environment', [])}
        for e in extra_env:
            if e['name'] not in existing:
                c.setdefault('environment', []).append(e)
print(json.dumps(td))
PYEOF
)

PIPELINE_TASK_ARN=$(aws ecs register-task-definition --cli-input-json "$new_def" \
  --query "taskDefinition.taskDefinitionArn" --output text --no-cli-pager)
printf '  Registered: %s\n' "$PIPELINE_TASK_ARN"

aws ecs update-service --cluster "$CLUSTER_NAME" --service "$PIPELINE_SVC" \
  --task-definition "$PIPELINE_TASK_ARN" --force-new-deployment --no-cli-pager >/dev/null

printf '\n  Waiting for service to stabilize...\n'
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$PIPELINE_SVC" \
  --region "$AWS_REGION" || printf '  (wait timed out — check ECS console)\n'

printf '\n✓ PHI Pipeline live on AWS\n'
printf '  API:         %s\n' "$API_URL"
printf '  API Docs:    %s/docs\n' "$API_URL"
printf '  Schedule:    8 am \xc2\xb7 5 pm PT weekdays\n'
printf '  Tear down:   ./scripts/infra-down.sh --aws\n'

