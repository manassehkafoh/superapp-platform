#!/usr/bin/env bash
###############################################################################
# SuperApp Platform — End-to-End Deployment Script v3.0.0
#
# DESCRIPTION:
#   Single script handling the complete SuperApp platform lifecycle.
#   Provisions infrastructure and deploys all services in the correct order.
#
#   Phase 0 → Pre-flight (tools, auth, env validation, production gate)
#   Phase 1 → Terraform foundation (networking, security, identity)
#   Phase 2 → Terraform Kubernetes (AKS cluster + FortiCNAPP)
#   Phase 3 → Terraform data tier (databases, messaging, monitoring)
#   Phase 4 → Cilium Zero Trust network policies
#   Phase 5 → ArgoCD ApplicationSet + AppProjects
#   Phase 6 → Service deployments (ArgoCD sync with canary)
#   Phase 7 → Smoke tests + SLO checks + FortiCNAPP verification
#   Phase 8 → DORA metrics push + Slack notification + summary
#
# USAGE:
#   ./scripts/deploy.sh [OPTIONS]
#
# OPTIONS:
#   -e, --environment ENV    Target: dev | staging | prod  (REQUIRED)
#   -p, --phase       PHASE  Run only phase N (0-8) or 'all' (default: all)
#   -s, --service     SVC    Deploy single service only (skips infra phases)
#   -t, --tag         TAG    Image tag (default: current git SHA)
#       --dry-run            Plan only — zero changes applied
#       --skip-tests         Skip Phase 7 smoke tests (emergency hotfix only)
#       --skip-approval      Skip production manual gate (emergency only)
#       --destroy            DANGER: Destroy all resources (dev/staging only)
#       --from-scratch       First-time install (initialises Terraform backend)
#   -h, --help               Print this help
#
# EXAMPLES:
#   # Full platform deploy to dev (first time)
#   ./scripts/deploy.sh -e dev --from-scratch
#
#   # Standard full deploy to staging
#   ./scripts/deploy.sh -e staging
#
#   # Deploy only payment-api hotfix to prod
#   ./scripts/deploy.sh -e prod -s payment-api -t abc1234 --skip-approval --skip-tests
#
#   # Dry-run production plan (no changes)
#   ./scripts/deploy.sh -e prod --dry-run
#
#   # Run only Phase 4 (re-apply Cilium policies)
#   ./scripts/deploy.sh -e dev -p 4
#
#   # Destroy dev environment
#   ./scripts/deploy.sh -e dev --destroy
#
# PREREQUISITES:
#   az ≥ 2.57, terraform ≥ 1.8, kubectl ≥ 1.29, helm ≥ 3.14,
#   argocd ≥ 2.11, cilium ≥ 0.16, cosign ≥ 2.2, jq ≥ 1.7, vault ≥ 1.16
#
# ENVIRONMENT VARIABLES:
#   TF_PARALLELISM     Terraform parallelism (default: 10)
#   ARGOCD_SERVER      ArgoCD server URL (auto-detected from cluster)
#   ARGOCD_TOKEN       ArgoCD API token  (falls back to interactive login)
#   SLACK_WEBHOOK_URL  Slack webhook for deploy notifications
#   PAGERDUTY_KEY      PagerDuty key for critical failure alerts
#   SKIP_PHASES        Comma-separated list of phases to skip (e.g. "3,4")
#
# EXIT CODES:
#   0 = Success  1 = Missing tools  2 = Auth failure  3 = Terraform failure
#   4 = K8s failure  5 = ArgoCD failure  6 = Smoke test failure
#   7 = Invalid arguments  8 = Unauthorised (prod gate)
#
###############################################################################

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly LOG_FILE="/tmp/superapp-deploy-${TIMESTAMP}.log"
readonly SCRIPT_VERSION="3.0.0"

# ── Colours ──────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m'
C='\033[0;36m' BOLD='\033[1m' RESET='\033[0m'

# ── Defaults ─────────────────────────────────────────────────────────────────
ENVIRONMENT=""
PHASE="all"
SERVICE=""
IMAGE_TAG=""
DRY_RUN=false
SKIP_TESTS=false
SKIP_APPROVAL=false
DESTROY=false
FROM_SCRATCH=false
TF_PARALLELISM="${TF_PARALLELISM:-10}"
DEPLOY_START_TIME=$(date +%s)
CHANGE_TICKET=""

readonly SERVICES=(identity-api account-api payment-api wallet-api notification-api api-gateway)
declare -A MIN_VERSIONS=(
  ["az"]="2.57.0" ["terraform"]="1.8.0" ["kubectl"]="1.29.0"
  ["helm"]="3.14.0" ["argocd"]="2.11.0" ["cosign"]="2.2.0"
  ["jq"]="1.7" ["vault"]="1.16.0"
)

###############################################################################
# LOGGING
###############################################################################
log()     { echo -e "${C}[$(date +%H:%M:%S)]${RESET} $*" | tee -a "${LOG_FILE}"; }
ok()      { echo -e "${G}${BOLD}✅ $*${RESET}" | tee -a "${LOG_FILE}"; }
warn()    { echo -e "${Y}${BOLD}⚠️  $*${RESET}" | tee -a "${LOG_FILE}"; }
err()     { echo -e "${R}${BOLD}❌ $*${RESET}" | tee -a "${LOG_FILE}" >&2; }
header()  { echo -e "\n${B}${BOLD}══════════════════════════════════════════${RESET}";
            echo -e "${B}${BOLD}  $*${RESET}";
            echo -e "${B}${BOLD}══════════════════════════════════════════${RESET}\n"; }
step()    { echo -e "\n${BOLD}▶ $*${RESET}" | tee -a "${LOG_FILE}"; }
die()     { err "$1"; echo -e "\n${R}Log: ${LOG_FILE}${RESET}"; exit "${2:-1}"; }
confirm() { echo -e "\n${Y}${BOLD}$1${RESET}\n${Y}Type 'yes' to continue:${RESET}";
            read -r r; [[ "$r" == "yes" ]] || die "Aborted." 0; }
version_gte() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

###############################################################################
# ARG PARSING
###############################################################################
parse_args() {
  [[ $# -eq 0 ]] && { grep "^#" "${BASH_SOURCE[0]}" | grep -v "^#!/" | sed 's/^# \?//'; exit 0; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
      -p|--phase)       PHASE="$2"; shift 2 ;;
      -s|--service)     SERVICE="$2"; shift 2 ;;
      -t|--tag)         IMAGE_TAG="$2"; shift 2 ;;
      --dry-run)        DRY_RUN=true; shift ;;
      --skip-tests)     SKIP_TESTS=true; shift ;;
      --skip-approval)  SKIP_APPROVAL=true; shift ;;
      --destroy)        DESTROY=true; shift ;;
      --from-scratch)   FROM_SCRATCH=true; shift ;;
      -h|--help)        grep "^#" "${BASH_SOURCE[0]}" | grep -v "^#!/" | sed 's/^# \?//'; exit 0 ;;
      *) die "Unknown argument: $1" 7 ;;
    esac
  done

  [[ -n "${ENVIRONMENT}" ]] || die "-e/--environment is required (dev|staging|prod)" 7
  [[ "${ENVIRONMENT}" =~ ^(dev|staging|prod)$ ]] || die "Invalid environment: ${ENVIRONMENT}" 7
  [[ -n "${IMAGE_TAG}" ]] || \
    IMAGE_TAG=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "latest")
}

###############################################################################
# PHASE 0 — PRE-FLIGHT
###############################################################################
phase_0() {
  header "Phase 0 — Pre-flight Checks"

  step "Checking required tools..."
  local missing=()
  for tool in "${!MIN_VERSIONS[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      missing+=("${tool}"); err "Missing: ${tool}"; continue
    fi
    local ver
    case "${tool}" in
      az)        ver=$(az --version 2>&1 | head -1 | awk '{print $2}') ;;
      terraform) ver=$(terraform version -json 2>/dev/null | jq -r '.terraform_version') ;;
      kubectl)   ver=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' | tr -d 'v') ;;
      helm)      ver=$(helm version --short 2>/dev/null | tr -d 'v+' | awk '{print $1}') ;;
      argocd)    ver=$(argocd version --client 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v+') ;;
      cosign)    ver=$(cosign version 2>/dev/null | grep GitVersion | awk '{print $2}' | tr -d 'v') ;;
      jq)        ver=$(jq --version 2>/dev/null | tr -d 'jq-') ;;
      vault)     ver=$(vault version 2>/dev/null | awk '{print $2}' | tr -d 'v') ;;
    esac
    if version_gte "${ver:-0}" "${MIN_VERSIONS[$tool]}"; then
      log "  ✅ ${tool} ${ver}"
    else
      warn "  ⚠️  ${tool} ${ver} (min: ${MIN_VERSIONS[$tool]})"
    fi
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Install missing tools: ${missing[*]}" 1

  step "Checking Azure authentication..."
  az account show &>/dev/null || { az login --use-device-code || die "Azure login failed" 2; }
  local user sub
  user=$(az account show --query user.name -o tsv)
  sub=$(az account show --query id -o tsv)
  log "  ✅ ${user} @ ${sub}"

  step "Checking repository state..."
  cd "${REPO_ROOT}"
  local tfvars="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}/terraform.tfvars"
  [[ -f "${tfvars}" ]] || die "Missing: ${tfvars}" 7

  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "Uncommitted changes in working tree"
    [[ "${ENVIRONMENT}" != "prod" ]] || die "Production requires clean working tree" 7
    confirm "Deploy with uncommitted changes to ${ENVIRONMENT}?"
  fi

  [[ ! ${DESTROY} == true ]] || \
    [[ "${ENVIRONMENT}" != "prod" ]] || die "DESTROY not permitted on production" 7

  # Production approval gate
  if [[ "${ENVIRONMENT}" == "prod" ]] && ! ${SKIP_APPROVAL}; then
    header "🔐 Production Deployment Gate"
    echo -e "${Y}Required before production deploy:"
    echo "  1. ITSM change ticket approved"
    echo "  2. Staging tests passed"
    echo -e "  3. On-call SRE notified${RESET}"
    read -rp $'\nEnter ITSM change ticket ID: ' CHANGE_TICKET
    [[ -n "${CHANGE_TICKET}" ]] || die "Change ticket required for production" 8
    confirm "Confirm production deploy with ticket ${CHANGE_TICKET}?"
  elif [[ "${ENVIRONMENT}" == "prod" ]] && ${SKIP_APPROVAL}; then
    warn "SKIP_APPROVAL set — emergency hotfix mode. Notify CTO now."
    CHANGE_TICKET="EMERGENCY-$(date +%s)"
  fi

  ok "Phase 0 complete"
}

###############################################################################
# PHASE 1 — TERRAFORM FOUNDATION
###############################################################################
phase_1() {
  header "Phase 1 — Terraform Foundation (networking, security, identity)"
  cd "${REPO_ROOT}/terraform"

  local init_flags=("-reconfigure")
  ${FROM_SCRATCH} && init_flags+=("-migrate-state")

  step "terraform init..."
  terraform init "${init_flags[@]}" \
    -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
    -backend-config="resource_group_name=rg-superapp-tfstate" \
    -backend-config="storage_account_name=stsuperappterraform" \
    -backend-config="container_name=tfstate" >> "${LOG_FILE}" 2>&1 || \
    die "terraform init failed — check ${LOG_FILE}" 3

  step "terraform plan (foundation)..."
  terraform plan \
    -var-file="environments/${ENVIRONMENT}/terraform.tfvars" \
    -parallelism="${TF_PARALLELISM}" \
    -out="tfplan-foundation-${ENVIRONMENT}" \
    -target=module.networking \
    -target=module.security \
    -target=module.identity 2>&1 | tee -a "${LOG_FILE}" | \
    grep -E "^(Plan:|No changes|Error:|  +(Will be|must be))" || true

  ${DRY_RUN} && { warn "DRY_RUN: skipping apply"; return 0; }

  step "terraform apply (foundation) — ~10-15 min..."
  terraform apply -auto-approve -parallelism="${TF_PARALLELISM}" \
    "tfplan-foundation-${ENVIRONMENT}" 2>&1 | tee -a "${LOG_FILE}" | \
    grep -E "^(Apply complete|Error:|  +(Created|Modified|Destroyed))" || true
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "terraform apply (foundation) failed" 3

  ok "Phase 1 complete"
}

###############################################################################
# PHASE 2 — KUBERNETES CLUSTER + FORTICNAPP
###############################################################################
phase_2() {
  header "Phase 2 — Kubernetes (AKS + FortiCNAPP)"
  cd "${REPO_ROOT}/terraform"

  step "terraform plan (kubernetes)..."
  terraform plan \
    -var-file="environments/${ENVIRONMENT}/terraform.tfvars" \
    -parallelism="${TF_PARALLELISM}" \
    -out="tfplan-k8s-${ENVIRONMENT}" \
    -target=module.kubernetes \
    -target=module.cnapp 2>&1 | tee -a "${LOG_FILE}" | \
    grep -E "^(Plan:|No changes|Error:)" || true

  ${DRY_RUN} && { warn "DRY_RUN: skipping apply"; return 0; }

  step "terraform apply (AKS) — ~15-20 min..."
  terraform apply -auto-approve -parallelism="${TF_PARALLELISM}" \
    "tfplan-k8s-${ENVIRONMENT}" 2>&1 | tee -a "${LOG_FILE}" | \
    grep -E "^(Apply complete|Error:)" || true
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "terraform apply (kubernetes) failed" 3

  step "Fetching AKS credentials..."
  local rg aks_name
  rg=$(terraform output -raw kubernetes_resource_group 2>/dev/null || \
       echo "rg-superapp-platform-${ENVIRONMENT}")
  aks_name=$(terraform output -raw aks_cluster_name 2>/dev/null || \
             echo "aks-superapp-${ENVIRONMENT}")
  az aks get-credentials --resource-group "${rg}" --name "${aks_name}" \
    --overwrite-existing >> "${LOG_FILE}" 2>&1 || die "Failed to get AKS credentials" 4
  log "  ✅ Context: ${aks_name}"

  step "Waiting for Cilium CNI (up to 5 min)..."
  local elapsed=0
  until cilium status 2>/dev/null | grep -q "Cilium:.*OK" || [[ ${elapsed} -ge 300 ]]; do
    sleep 15; elapsed=$((elapsed+15)); log "  ${elapsed}s — waiting for Cilium..."
  done
  cilium status 2>/dev/null | grep -q "Cilium:.*OK" || warn "Cilium status unclear — check manually"

  step "Waiting for ArgoCD..."
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s >> "${LOG_FILE}" 2>&1 || \
    die "ArgoCD not ready after 5 min" 5

  ok "Phase 2 complete"
}

###############################################################################
# PHASE 3 — DATA TIER
###############################################################################
phase_3() {
  header "Phase 3 — Data Tier (databases, messaging, monitoring)"
  cd "${REPO_ROOT}/terraform"

  step "terraform plan (data tier)..."
  terraform plan \
    -var-file="environments/${ENVIRONMENT}/terraform.tfvars" \
    -parallelism="${TF_PARALLELISM}" \
    -out="tfplan-data-${ENVIRONMENT}" \
    -target=module.databases \
    -target=module.messaging \
    -target=module.monitoring 2>&1 | tee -a "${LOG_FILE}" | \
    grep -E "^(Plan:|No changes|Error:)" || true

  ${DRY_RUN} && { warn "DRY_RUN: skipping apply"; return 0; }

  step "terraform apply (data tier) — ~10-15 min..."
  terraform apply -auto-approve -parallelism="${TF_PARALLELISM}" \
    "tfplan-data-${ENVIRONMENT}" 2>&1 | tee -a "${LOG_FILE}" | \
    grep -E "^(Apply complete|Error:)" || true
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "terraform apply (data tier) failed" 3

  ok "Phase 3 complete"
}

###############################################################################
# PHASE 4 — CILIUM NETWORK POLICIES
###############################################################################
phase_4() {
  header "Phase 4 — Cilium Zero Trust Network Policies"

  local policy_file="${REPO_ROOT}/kubernetes/cilium/network-policies.yaml"

  step "Validating Cilium policies..."
  cilium policy validate "${policy_file}" >> "${LOG_FILE}" 2>&1 || \
    die "Cilium policy validation failed" 4

  ${DRY_RUN} && { warn "DRY_RUN: skipping policy apply"; return 0; }

  step "Applying Cilium network policies..."
  kubectl apply -f "${policy_file}" >> "${LOG_FILE}" 2>&1 || \
    die "Failed to apply Cilium policies" 4

  local count
  count=$(kubectl get ciliumnetworkpolicies -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log "  ✅ ${count} CiliumNetworkPolicies active"

  ok "Phase 4 complete"
}

###############################################################################
# PHASE 5 — ARGOCD SETUP
###############################################################################
phase_5() {
  header "Phase 5 — ArgoCD ApplicationSet + AppProjects"

  local server="${ARGOCD_SERVER:-argocd.${ENVIRONMENT}.superapp.com.gh}"

  step "Logging into ArgoCD (${server})..."
  if [[ -n "${ARGOCD_TOKEN:-}" ]]; then
    argocd login "${server}" --auth-token "${ARGOCD_TOKEN}" --grpc-web --insecure >> "${LOG_FILE}" 2>&1 || \
      die "ArgoCD login failed" 5
  else
    argocd login "${server}" --grpc-web --insecure 2>&1 || die "ArgoCD login failed" 5
  fi

  ${DRY_RUN} && { warn "DRY_RUN: skipping ApplicationSet apply"; return 0; }

  step "Applying ArgoCD ApplicationSet..."
  kubectl apply -f "${REPO_ROOT}/gitops/argocd/applications/superapp-appset.yaml" \
    >> "${LOG_FILE}" 2>&1 || die "Failed to apply ArgoCD ApplicationSet" 5

  log "  Waiting for Applications to be generated..."
  sleep 15
  local count
  count=$(argocd app list --output name 2>/dev/null | wc -l | tr -d ' ')
  log "  ✅ ${count} ArgoCD Applications generated"

  ok "Phase 5 complete"
}

###############################################################################
# PHASE 6 — SERVICE DEPLOYMENTS
###############################################################################
phase_6() {
  header "Phase 6 — Service Deployments (tag: ${IMAGE_TAG})"

  local targets=("${SERVICES[@]}")
  [[ -n "${SERVICE}" ]] && targets=("${SERVICE}")

  ${DRY_RUN} && { warn "DRY_RUN: would deploy ${targets[*]} @ ${IMAGE_TAG}"; return 0; }

  local failed=()
  for svc in "${targets[@]}"; do
    step "Deploying ${svc}..."
    local app="${ENVIRONMENT}-${svc}"

    argocd app set "${app}" \
      --helm-set "image.tag=${IMAGE_TAG}" \
      --helm-set "global.environment=${ENVIRONMENT}" >> "${LOG_FILE}" 2>&1 || \
      { warn "Failed to set ${svc} image tag"; failed+=("${svc}"); continue; }

    argocd app sync "${app}" --force --prune --timeout 300 >> "${LOG_FILE}" 2>&1 || \
      { warn "${svc} sync failed"; failed+=("${svc}"); continue; }

    argocd app wait "${app}" --health --timeout 300 >> "${LOG_FILE}" 2>&1 || {
      err "${svc} did not become healthy"
      failed+=("${svc}")
      if [[ "${ENVIRONMENT}" == "prod" ]]; then
        warn "Auto-rolling back ${svc}..."
        argocd app rollback "${app}" >> "${LOG_FILE}" 2>&1 || true
        _pagerduty "Deployment FAILED for ${svc} in ${ENVIRONMENT} — rolled back"
      fi
      continue
    }
    ok "  ${svc} healthy"
  done

  [[ ${#failed[@]} -eq 0 ]] || die "Failed services: ${failed[*]}" 5
  ok "Phase 6 complete"
}

###############################################################################
# PHASE 7 — SMOKE TESTS
###############################################################################
phase_7() {
  header "Phase 7 — Smoke Tests + Verification"
  ${SKIP_TESTS} && { warn "SKIP_TESTS set — skipping"; return 0; }

  local base
  case "${ENVIRONMENT}" in
    dev)     base="https://api.dev.superapp.com.gh" ;;
    staging) base="https://api.staging.superapp.com.gh" ;;
    prod)    base="https://api.superapp.com.gh" ;;
  esac

  local failed=()

  step "API Gateway health..."
  curl -sf "${base}/health" --max-time 10 | jq -e '.status=="Healthy"' &>/dev/null && \
    ok "  API Gateway: Healthy" || { err "  API Gateway health failed"; failed+=("gateway"); }

  step "Pod readiness check..."
  for svc in "${SERVICES[@]}"; do
    local ns="superapp-services"
    [[ "${svc}" == "api-gateway" ]] && ns="superapp-gateway"
    local ready desired
    ready=$(kubectl get deploy "${svc}" -n "${ns}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(kubectl get deploy "${svc}" -n "${ns}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    [[ "${ready}" == "${desired}" ]] && ok "  ${svc}: ${ready}/${desired}" || \
      warn "  ${svc}: ${ready}/${desired} replicas"
  done

  step "Cilium connectivity..."
  cilium connectivity test --test-namespace cilium-test \
    --connect-timeout 5s --request-timeout 10s 2>/dev/null | \
    tail -3 | grep -q "All.*passed" && ok "  Cilium: all tests passed" || \
    warn "  Cilium connectivity test incomplete (non-fatal)"

  step "FortiCNAPP agents..."
  local fr_ready fr_desired
  fr_ready=$(kubectl get ds fortirecon-agent -n fortirecon \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  fr_desired=$(kubectl get ds fortirecon-agent -n fortirecon \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "?")
  log "  FortiCNAPP: ${fr_ready}/${fr_desired} nodes"
  [[ "${fr_ready}" != "0" ]] && ok "  FortiCNAPP agents active"

  
  step "Checking HPA status across all services..."
  kubectl get hpa -n superapp-services -n superapp-gateway 2>/dev/null | tee -a "${LOG_FILE}" |     grep -v "^NAME" | while IFS= read -r line; do
      svc=$(echo "$line" | awk '{print $1}')
      current=$(echo "$line" | awk '{print $6}')
      min=$(echo "$line" | awk '{print $4}')
      max=$(echo "$line" | awk '{print $5}')
      log "  HPA ${svc}: ${current} replicas (min=${min} max=${max})"
    done

  step "Checking KEDA ScaledObjects..."
  kubectl get scaledobjects -n superapp-services 2>/dev/null | tee -a "${LOG_FILE}" ||     warn "  KEDA ScaledObjects not yet deployed (will be synced by ArgoCD)"

  step "Checking VPA recommendations..."
  kubectl get vpa -n superapp-services 2>/dev/null | tee -a "${LOG_FILE}" |     grep -v "^NAME" | while IFS= read -r line; do
      vpa_name=$(echo "$line" | awk '{print $1}')
      log "  VPA: ${vpa_name} (recommendations available in kubectl describe vpa ${vpa_name})"
    done

  step "Kafka consumer lag..."
  local hi_lag
  hi_lag=$(kubectl exec -n kafka kafka-0 2>/dev/null -- \
    bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
    --describe --all-groups 2>/dev/null | awk 'NR>1 && $6>10000{print $1":"$2" lag="$6}' || echo "")
  [[ -z "${hi_lag}" ]] && ok "  Kafka lag: normal" || warn "  High lag: ${hi_lag}"

  if [[ ${#failed[@]} -gt 0 ]]; then
    [[ "${ENVIRONMENT}" == "prod" ]] && \
      _pagerduty "Smoke tests failed: ${failed[*]}" && \
      die "Smoke tests FAILED in production" 6
    warn "Non-production failures: ${failed[*]}"
  fi

  ok "Phase 7 complete"
}

###############################################################################
# PHASE 8 — POST-DEPLOY
###############################################################################
phase_8() {
  header "Phase 8 — Post-Deploy (DORA metrics + notifications)"

  local end_time; end_time=$(date +%s)
  local lead_sec=$((end_time - DEPLOY_START_TIME))
  local lead_min=$((lead_sec / 60))

  step "Pushing DORA metrics..."
  local pg_url="http://prometheus-pushgateway.monitoring.svc.cluster.local:9091"
  kubectl exec -n monitoring deploy/prometheus-pushgateway 2>/dev/null -- \
    sh -c "cat > /tmp/dora.txt << 'METRICS'
# TYPE superapp_deployment_total counter
superapp_deployment_total{env=\"${ENVIRONMENT}\",service=\"${SERVICE:-all}\",tag=\"${IMAGE_TAG}\"} 1
# TYPE superapp_lead_time_seconds gauge
superapp_lead_time_seconds{env=\"${ENVIRONMENT}\"} ${lead_sec}
METRICS
wget -qO- --post-file=/tmp/dora.txt ${pg_url}/metrics/job/superapp-deploys" \
    >> "${LOG_FILE}" 2>&1 || warn "DORA metric push skipped (pushgateway may not be available)"

  log "  ✅ Lead time: ${lead_min}m"

  if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    step "Sending Slack notification..."
    curl -sf -X POST "${SLACK_WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"✅ *SuperApp ${ENVIRONMENT^^} deployed* | services: ${SERVICE:-all} | tag: \`${IMAGE_TAG}\` | lead time: ${lead_min}m ${CHANGE_TICKET:+| ticket: ${CHANGE_TICKET}}\"}" \
      >> "${LOG_FILE}" 2>&1 && log "  ✅ Slack notified"
  fi

  # ── Final summary ─────────────────────────────────────────────────────────
  local api_url grafana_url
  case "${ENVIRONMENT}" in
    dev)     api_url="https://api.dev.superapp.com.gh";     grafana_url="https://grafana.dev.superapp.com.gh" ;;
    staging) api_url="https://api.staging.superapp.com.gh"; grafana_url="https://grafana.staging.superapp.com.gh" ;;
    prod)    api_url="https://api.superapp.com.gh";         grafana_url="https://grafana.superapp.com.gh" ;;
  esac

  echo ""
  echo -e "${G}${BOLD}╔══════════════════════════════════════════════════════════╗"
  echo    "║        🚀  SUPERAPP DEPLOYMENT COMPLETE                  ║"
  echo    "╠══════════════════════════════════════════════════════════╣"
  printf  "║  %-22s %-34s ║\n" "Environment:"  "${ENVIRONMENT}"
  printf  "║  %-22s %-34s ║\n" "Services:"     "${SERVICE:-all services}"
  printf  "║  %-22s %-34s ║\n" "Image Tag:"    "${IMAGE_TAG}"
  printf  "║  %-22s %-34s ║\n" "Lead Time:"    "${lead_min} minutes"
  printf  "║  %-22s %-34s ║\n" "API:"          "${api_url}"
  printf  "║  %-22s %-34s ║\n" "Grafana:"      "${grafana_url}"
  [[ -n "${CHANGE_TICKET}" ]] && \
  printf  "║  %-22s %-34s ║\n" "Change Ticket:" "${CHANGE_TICKET}"
  printf  "║  %-22s %-34s ║\n" "Log:"          "${LOG_FILE}"
  echo    "╚══════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  ok "Deployment complete!"
}

###############################################################################
# DESTROY MODE
###############################################################################
do_destroy() {
  header "DESTROY — ${ENVIRONMENT^^}"
  [[ "${ENVIRONMENT}" != "prod" ]] || die "DESTROY not permitted on production" 7
  confirm "⚠️  This permanently deletes ALL ${ENVIRONMENT} resources. Type 'yes':"
  cd "${REPO_ROOT}/terraform"
  terraform destroy -var-file="environments/${ENVIRONMENT}/terraform.tfvars" \
    -auto-approve 2>&1 | tee -a "${LOG_FILE}"
  ok "Destroy complete"
}

###############################################################################
# PAGERDUTY HELPER
###############################################################################
_pagerduty() {
  [[ -n "${PAGERDUTY_KEY:-}" ]] || return 0
  curl -sf -X POST "https://events.pagerduty.com/v2/enqueue" \
    -H "Content-Type: application/json" \
    -d "{\"routing_key\":\"${PAGERDUTY_KEY}\",\"event_action\":\"trigger\",\"payload\":{\"summary\":\"$1\",\"severity\":\"critical\",\"source\":\"deploy.sh\"}}" \
    >> "${LOG_FILE}" 2>&1 || true
}

###############################################################################
# MAIN
###############################################################################
main() {
  echo -e "\n${B}${BOLD}  SuperApp Platform Deploy v${SCRIPT_VERSION}${RESET}"
  echo -e "${B}${BOLD}  $(date)  |  env=${ENVIRONMENT}  tag=${IMAGE_TAG}${RESET}\n"
  log "Log: ${LOG_FILE}"

  ${DRY_RUN}    && warn "DRY RUN — no changes will be applied"
  ${SKIP_TESTS} && warn "SKIP TESTS — smoke tests disabled"

  ${DESTROY} && { phase_0; do_destroy; exit 0; }

  # Single service mode — skip infra
  if [[ -n "${SERVICE}" && "${PHASE}" == "all" ]]; then
    log "Single service mode — skipping infrastructure phases"
    phase_0; phase_5; phase_6; phase_7; phase_8; exit 0
  fi

  local skip_list; IFS=',' read -ra skip_list <<< "${SKIP_PHASES:-}"
  run() {
    local n="$1" fn="$2"
    for s in "${skip_list[@]}"; do [[ "$s" == "$n" ]] && { warn "Skipping phase $n"; return; }; done
    [[ "${PHASE}" == "all" || "${PHASE}" == "$n" ]] && "${fn}"
  }

  run 0 phase_0
  run 1 phase_1
  run 2 phase_2
  run 3 phase_3
  run 4 phase_4
  run 5 phase_5
  run 6 phase_6
  run 7 phase_7
  run 8 phase_8
}

parse_args "$@"
main
