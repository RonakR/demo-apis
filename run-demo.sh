#!/usr/bin/env bash
set -euo pipefail

#####################################
# Config
#####################################
CLUSTER_NAME="${CLUSTER_NAME:-demo}"

# Repo dirs (match your markdown)
IDENTITY_DIR="${IDENTITY_DIR:-./identity-api}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-./accounts-api}"
CATALOG_DIR="${CATALOG_DIR:-./catalog-api}"

# Image tags
IDENTITY_IMG="${IDENTITY_IMG:-identity-api:dev}"
ACCOUNTS_IMG="${ACCOUNTS_IMG:-accounts-api:dev}"
CATALOG_IMG="${CATALOG_IMG:-catalog-api:dev}"

# Namespaces
NAMESPACES=("identity" "accounts" "catalog")

# Rebuild behavior:
#   FORCE_REBUILD=1 ./run-demo.sh  -> always rebuild
FORCE_REBUILD="${FORCE_REBUILD:-0}"

#####################################
# Helpers
#####################################
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

cluster_exists() {
  kind get clusters | grep -qx "${CLUSTER_NAME}"
}

namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

dir_exists_or_die() {
  local d="$1"
  [[ -d "$d" ]] || { echo "ERROR: directory not found: $d" >&2; exit 1; }
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

#####################################
# Preconditions
#####################################
need_cmd docker
need_cmd kind
need_cmd kubectl
need_cmd curl

dir_exists_or_die "${IDENTITY_DIR}"
dir_exists_or_die "${ACCOUNTS_DIR}"
dir_exists_or_die "${CATALOG_DIR}"

#####################################
# 1) Create Kind cluster (if needed)
#####################################
if cluster_exists; then
  echo "✅ Kind cluster '${CLUSTER_NAME}' already exists"
else
  echo "🚀 Creating Kind cluster '${CLUSTER_NAME}' using k8s/kind-config.yaml"
  [[ -f k8s/kind-config.yaml ]] || { echo "ERROR: k8s/kind-config.yaml not found in current dir" >&2; exit 1; }
  kind create cluster --name "${CLUSTER_NAME}" --config k8s/kind-config.yaml
fi

# Ensure kubectl context
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null

#####################################
# 2) Install ingress-nginx (if needed)
#####################################
echo "📦 Ensuring ingress-nginx is installed..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "⏳ Waiting for ingress-nginx controller deployment..."
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

# Extra: ensure at least one controller pod exists
if ! kubectl -n ingress-nginx get pods -l app.kubernetes.io/name=ingress-nginx >/dev/null 2>&1; then
  echo "WARN: ingress-nginx controller pods not found by expected label. Listing pods:"
  kubectl -n ingress-nginx get pods --show-labels
fi


#####################################
# 3) Create namespaces (if needed)
#####################################
for ns in "${NAMESPACES[@]}"; do
  if namespace_exists "$ns"; then
    echo "✅ Namespace '$ns' exists"
  else
    echo "📁 Creating namespace '$ns'"
    kubectl create namespace "$ns"
  fi
done

#####################################
# 4) Build Docker images (conditional)
#####################################
build_if_needed() {
  local img="$1"
  local dir="$2"

  if [[ "${FORCE_REBUILD}" == "1" ]]; then
    echo "🐳 Rebuilding (forced) ${img} from ${dir}"
    docker build -t "${img}" "${dir}"
    return
  fi

  if image_exists "${img}"; then
    echo "✅ Docker image ${img} already exists (skip build). Set FORCE_REBUILD=1 to rebuild."
  else
    echo "🐳 Building ${img} from ${dir}"
    docker build -t "${img}" "${dir}"
  fi
}

build_if_needed "${IDENTITY_IMG}" "${IDENTITY_DIR}"
build_if_needed "${ACCOUNTS_IMG}" "${ACCOUNTS_DIR}"
build_if_needed "${CATALOG_IMG}" "${CATALOG_DIR}"

#####################################
# 5) Load images into Kind (safe to re-run)
#####################################
echo "📥 Loading images into Kind cluster '${CLUSTER_NAME}'"
kind load docker-image "${IDENTITY_IMG}" --name "${CLUSTER_NAME}"
kind load docker-image "${ACCOUNTS_IMG}" --name "${CLUSTER_NAME}"
kind load docker-image "${CATALOG_IMG}" --name "${CLUSTER_NAME}"

#####################################
# 6) Apply manifests
#####################################
[[ -f k8s/apps.yaml ]] || { echo "ERROR: k8s/apps.yaml not found in current dir" >&2; exit 1; }

echo "📄 Applying Kubernetes manifests (k8s/apps.yaml)"
kubectl apply -f k8s/apps.yaml

#####################################
# 7) Show status
#####################################
echo
echo "📊 Resources (all namespaces)"
kubectl get pods,svc,ingress -A

#####################################
# 8) Health checks (don’t hard-fail)
#####################################
echo
echo "❤️ Health checks via Ingress"
set +e
curl -sS -o /dev/null -w "identity:  %{http_code}\n"  http://localhost/identity/health
curl -sS -o /dev/null -w "accounts:  %{http_code}\n"  http://localhost/accounts/health
curl -sS -o /dev/null -w "catalog:   %{http_code}\n"  http://localhost/catalog/health
set -e

echo
echo "✅ Done. If any health check is not 200, check pods/logs:"
echo "  kubectl get pods -A"
echo "  kubectl -n identity logs deploy/identity-api --tail=200"
echo "  kubectl -n accounts logs deploy/accounts-api --tail=200"
echo "  kubectl -n catalog logs deploy/catalog-api --tail=200"
