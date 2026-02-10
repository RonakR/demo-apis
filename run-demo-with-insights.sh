#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-demo}"

# Repo dirs + image tags (match your layout)
IDENTITY_DIR="${IDENTITY_DIR:-./identity-api}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-./accounts-api}"
CATALOG_DIR="${CATALOG_DIR:-./catalog-api}"

IDENTITY_IMG="${IDENTITY_IMG:-identity-api:dev}"
ACCOUNTS_IMG="${ACCOUNTS_IMG:-accounts-api:dev}"
CATALOG_IMG="${CATALOG_IMG:-catalog-api:dev}"

FORCE_REBUILD="${FORCE_REBUILD:-0}"

KIND_CONFIG="${KIND_CONFIG:-./k8s/kind-config.yaml}"
APPS_YAML="${APPS_YAML:-k8s/apps.yaml}"

# Postman DaemonSet install
POSTMAN_DS_URL="${POSTMAN_DS_URL:-https://releases.observability.postman.com/scripts/postman-insights-agent-daemonset.yaml}"
POSTMAN_DS_LOCAL="${POSTMAN_DS_LOCAL:-k8s/postman-insights-agent-daemonset.yaml}"

# Your namespace + deployment names from apps.yaml
NS="${NS:-demo}"
DEP_IDENTITY="${DEP_IDENTITY:-identity-api}"
DEP_ACCOUNTS="${DEP_ACCOUNTS:-accounts-api}"
DEP_CATALOG="${DEP_CATALOG:-catalog-api}"

# K8s Secret that will store the Postman API key
INSIGHTS_SECRET_NAME="${INSIGHTS_SECRET_NAME:-postman-insights-secret}"
INSIGHTS_SECRET_KEY="${INSIGHTS_SECRET_KEY:-POSTMAN_INSIGHTS_API_KEY}"

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
dir_exists(){ [[ -d "$1" ]] || { echo "ERROR: missing dir $1" >&2; exit 1; }; }
file_exists(){ [[ -f "$1" ]] || { echo "ERROR: missing file $1" >&2; exit 1; }; }
cluster_exists(){ kind get clusters | grep -qx "${CLUSTER_NAME}"; }
image_exists(){ docker image inspect "$1" >/dev/null 2>&1; }

need_cmd docker
need_cmd kind
need_cmd kubectl
need_cmd curl

dir_exists "${IDENTITY_DIR}"
dir_exists "${ACCOUNTS_DIR}"
dir_exists "${CATALOG_DIR}"
file_exists "${KIND_CONFIG}"
file_exists "${APPS_YAML}"

#####################################
# 1) Kind cluster
#####################################
if cluster_exists; then
  echo "✅ Kind cluster '${CLUSTER_NAME}' already exists"
else
  echo "🚀 Creating Kind cluster '${CLUSTER_NAME}'"
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

#####################################
# 2) Ingress NGINX
#####################################
# Ensure kubectl context points to the live Kind API server
kind export kubeconfig --name "${CLUSTER_NAME}"
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl get nodes >/dev/null

echo "📦 Ensuring ingress-nginx is installed..."
kubectl apply --validate=false -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "⏳ Waiting for ingress-nginx controller..."
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s


#####################################
# 3) Build images (conditional)
#####################################
build_if_needed() {
  local img="$1"
  local dir="$2"
  if [[ "${FORCE_REBUILD}" == "1" ]]; then
    echo "🐳 Rebuilding (forced) ${img}"
    docker build -t "${img}" "${dir}"
  else
    if image_exists "${img}"; then
      echo "✅ Image ${img} exists (skip). Set FORCE_REBUILD=1 to rebuild."
    else
      echo "🐳 Building ${img}"
      docker build -t "${img}" "${dir}"
    fi
  fi
}
build_if_needed "${IDENTITY_IMG}" "${IDENTITY_DIR}"
build_if_needed "${ACCOUNTS_IMG}" "${ACCOUNTS_DIR}"
build_if_needed "${CATALOG_IMG}" "${CATALOG_DIR}"

#####################################
# 4) Load images into Kind
#####################################
echo "📥 Loading images into Kind..."
kind load docker-image "${IDENTITY_IMG}" --name "${CLUSTER_NAME}"
kind load docker-image "${ACCOUNTS_IMG}" --name "${CLUSTER_NAME}"
kind load docker-image "${CATALOG_IMG}" --name "${CLUSTER_NAME}"

#####################################
# 5) Apply your apps.yaml (idempotent)
#####################################
echo "📄 Applying app manifests (${APPS_YAML})"
kubectl apply -f "${APPS_YAML}"

#####################################
# 6) Install Postman Insights agent DaemonSet (once per cluster)
#####################################
echo "🛰️  Installing Postman Insights Agent DaemonSet (cluster-wide)..."
mkdir -p "$(dirname "${POSTMAN_DS_LOCAL}")"
if [[ ! -f "${POSTMAN_DS_LOCAL}" ]]; then
  echo "⬇️  Downloading Postman DaemonSet manifest to ${POSTMAN_DS_LOCAL}"
  curl -fsSL "${POSTMAN_DS_URL}" -o "${POSTMAN_DS_LOCAL}"
else
  echo "✅ Using existing ${POSTMAN_DS_LOCAL}"
fi

kubectl apply -f "${POSTMAN_DS_LOCAL}"

# Kind: allow scheduling on control-plane if needed
kubectl -n postman-insights-namespace patch daemonset postman-insights-agent --type='merge' -p '{
  "spec": {
    "template": {
      "spec": {
        "tolerations": [
          { "key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule" },
          { "key": "node-role.kubernetes.io/master", "operator": "Exists", "effect": "NoSchedule" }
        ]
      }
    }
  }
}' >/dev/null 2>&1 || true

echo "⏳ Waiting for Postman Insights agent DaemonSet..."
kubectl -n postman-insights-namespace rollout status daemonset/postman-insights-agent --timeout=240s || true

#####################################
# 7) Onboard each service to Insights (env vars per service)
#####################################
if [[ -z "${POSTMAN_API_KEY:-}" ]]; then
  echo "⚠️  POSTMAN_API_KEY not set. Skipping Insights onboarding env/secret patching."
  echo "    Export POSTMAN_API_KEY plus the three *_PROJECT_ID vars, then re-run."
else
  # create/update secret once in demo namespace
  echo "🔐 Ensuring secret '${INSIGHTS_SECRET_NAME}' exists in namespace '${NS}'"
  kubectl -n "${NS}" create secret generic "${INSIGHTS_SECRET_NAME}" \
    --from-literal="${INSIGHTS_SECRET_KEY}=${POSTMAN_API_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  set_project_env_if_missing() {
    local dep="$1"
    local project_id="$2"
    local label="$3"

    if [[ -z "${project_id}" ]]; then
      echo "⚠️  Missing ${label}. Skipping ${NS}/${dep}."
      return 0
    fi

    if kubectl -n "${NS}" get deploy "${dep}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTMAN_INSIGHTS_PROJECT_ID")].name}' 2>/dev/null | grep -q POSTMAN_INSIGHTS_PROJECT_ID; then
      echo "✅ ${NS}/${dep}: POSTMAN_INSIGHTS_PROJECT_ID already set"
    else
      echo "➕ ${NS}/${dep}: setting POSTMAN_INSIGHTS_PROJECT_ID=${project_id}"
      kubectl -n "${NS}" set env deploy/"${dep}" POSTMAN_INSIGHTS_PROJECT_ID="${project_id}" >/dev/null
    fi
  }

  set_apikey_env_from_secret_if_missing() {
    local dep="$1"

    if kubectl -n "${NS}" get deploy "${dep}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTMAN_INSIGHTS_API_KEY")].name}' 2>/dev/null | grep -q POSTMAN_INSIGHTS_API_KEY; then
      echo "✅ ${NS}/${dep}: POSTMAN_INSIGHTS_API_KEY already set"
    else
      echo "➕ ${NS}/${dep}: adding POSTMAN_INSIGHTS_API_KEY from secret"
      kubectl -n "${NS}" patch deploy "${dep}" --type='json' -p="[
        {
          \"op\": \"add\",
          \"path\": \"/spec/template/spec/containers/0/env/-\",
          \"value\": {
            \"name\": \"POSTMAN_INSIGHTS_API_KEY\",
            \"valueFrom\": {
              \"secretKeyRef\": {
                \"name\": \"${INSIGHTS_SECRET_NAME}\",
                \"key\": \"${INSIGHTS_SECRET_KEY}\"
              }
            }
          }
        }
      ]" >/dev/null
    fi
  }

  echo "🔧 Patching Deployments with Insights env vars (1 project per service)..."
  set_project_env_if_missing "${DEP_IDENTITY}" "${IDENTITY_PROJECT_ID:-}" "IDENTITY_PROJECT_ID"
  set_apikey_env_from_secret_if_missing "${DEP_IDENTITY}"

  set_project_env_if_missing "${DEP_ACCOUNTS}" "${ACCOUNTS_PROJECT_ID:-}" "ACCOUNTS_PROJECT_ID"
  set_apikey_env_from_secret_if_missing "${DEP_ACCOUNTS}"

  set_project_env_if_missing "${DEP_CATALOG}" "${CATALOG_PROJECT_ID:-}" "CATALOG_PROJECT_ID"
  set_apikey_env_from_secret_if_missing "${DEP_CATALOG}"

  echo "⏳ Rolling deployments..."
  kubectl -n "${NS}" rollout status deploy/"${DEP_IDENTITY}" --timeout=180s || true
  kubectl -n "${NS}" rollout status deploy/"${DEP_ACCOUNTS}" --timeout=180s || true
  kubectl -n "${NS}" rollout status deploy/"${DEP_CATALOG}" --timeout=180s || true
fi

#####################################
# 8) Health checks
#####################################
echo
echo "❤️ Health checks"
set +e
curl -sS -o /dev/null -w "identity:  %{http_code}\n"  http://localhost/identity/health
curl -sS -o /dev/null -w "accounts:  %{http_code}\n"  http://localhost/accounts/health
curl -sS -o /dev/null -w "catalog:   %{http_code}\n"   http://localhost/catalog/health
set -e

echo
echo "✅ Done."
echo "Next: generate real traffic (not just health checks) so Insights discovers endpoints."
