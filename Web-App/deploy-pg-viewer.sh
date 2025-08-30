#!/usr/bin/env bash
set -euo pipefail

# Usage: ./deploy-pg-viewer.sh <namespace> <app_dir>
# Example:
#   ./deploy-pg-viewer.sh bank-test1 ./pg-viewer-single
#   ./deploy-pg-viewer.sh bank-test2 ./pg-viewer-single

NS="${1:-}"
APP_DIR="${2:-}"
APP_NAME="pg-viewer-single"      # ImageStream/Deployment/Service/Route name
PORT=8080                        # viewer container/listen port
VIEWER_IMAGE_TAG="latest"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }
need oc

[[ -n "$NS" && -n "$APP_DIR" ]] || { echo "Usage: $0 <namespace> <app_dir>"; exit 1; }
[[ -d "$APP_DIR" ]] || { echo "ERROR: app dir '$APP_DIR' not found"; exit 1; }

echo "==> Using namespace: $NS"
oc new-project "$NS" >/dev/null 2>&1 || oc project "$NS" >/dev/null

# --- find E-STAP LB service (expects port 8888) ---
echo "==> Discovering E-STAP LoadBalancer service on port 8888 in $NS"
LB_SVC="$(oc -n "$NS" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.type}{"|"}{.spec.ports[*].port}{"\n"}{end}' \
  | awk -F'|' '$2=="LoadBalancer" && $3 ~ /(^| )8888( |$)/ {print $1; exit}')"
if [[ -z "${LB_SVC}" ]]; then
  echo "ERROR: Could not find an LB service on port 8888 in $NS (E-STAP not installed/ready?)"
  oc -n "$NS" get svc
  exit 1
fi
echo "    LB service: ${LB_SVC}"

LB_HOST="$(oc -n "$NS" get svc "$LB_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
[[ -n "$LB_HOST" ]] || LB_HOST="$(oc -n "$NS" get svc "$LB_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "$LB_HOST" ]]; then
  echo "WARN: LB external endpoint not ready yet; the app may fail until the LB is provisioned."
else
  echo "    LB endpoint: ${LB_HOST}:8888"
fi

# --- read DB env from postgres Deployment (user/db/password) ---
echo "==> Reading DB credentials from deploy/postgres in $NS"
if ! oc -n "$NS" get deploy/postgres >/dev/null 2>&1; then
  echo "ERROR: deploy/postgres not found in $NS"
  exit 1
fi

PGUSER="$(oc -n "$NS" get deploy postgres -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_USER")].value}')"
PGDATABASE="$(oc -n "$NS" get deploy postgres -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_DB")].value}')"
PGPASSWORD="$(oc -n "$NS" get deploy postgres -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_PASSWORD")].value}')"
# fallbacks if the envs aren’t at index 0
if [[ -z "$PGUSER" ]]; then
  PGUSER="$(oc -n "$NS" get deploy postgres -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}={"\""}{.value}{"\""}{"\n"}{end}' | awk -F= '$1=="POSTGRES_USER"{gsub(/"/,"",$2);print $2}')"
fi
if [[ -z "$PGDATABASE" ]]; then
  PGDATABASE="$(oc -n "$NS" get deploy postgres -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}={"\""}{.value}{"\""}{"\n"}{end}' | awk -F= '$1=="POSTGRES_DB"{gsub(/"/,"",$2);print $2}')"
fi
if [[ -z "$PGPASSWORD" ]]; then
  PGPASSWORD="$(oc -n "$NS" get deploy postgres -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}={"\""}{.value}{"\""}{"\n"}{end}' | awk -F= '$1=="POSTGRES_PASSWORD"{gsub(/"/,"",$2);print $2}')"
fi

echo "    PGUSER=${PGUSER:-<empty>}  PGDATABASE=${PGDATABASE:-<empty>}  (password: ${PGPASSWORD:+<set>}${PGPASSWORD:+' '})"
[[ -n "$PGUSER" && -n "$PGDATABASE" && -n "$PGPASSWORD" ]] || { echo "ERROR: Failed to read DB env (user/db/password)"; exit 1; }

# --- ensure ImageStream & BuildConfig ---
echo "==> Ensure ImageStream & BuildConfig exist"
if ! oc -n "$NS" get is "$APP_NAME" >/dev/null 2>&1; then
  oc -n "$NS" new-build --name "$APP_NAME" --binary --strategy docker
fi

echo "==> Start build from $APP_DIR"
oc -n "$NS" start-build "$APP_NAME" --from-dir="$APP_DIR" --wait --follow

# internal registry image reference for this namespace
IMG="image-registry.openshift-image-registry.svc:5000/${NS}/${APP_NAME}:${VIEWER_IMAGE_TAG}"

# --- create or update Deployment using internal registry image ---
if ! oc -n "$NS" get deploy "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Create Deployment"
  oc -n "$NS" create deployment "$APP_NAME" --image="$IMG"
else
  echo "==> Update Deployment image"
  oc -n "$NS" set image "deploy/${APP_NAME}" "${APP_NAME}=${IMG}"
fi

# create Service if needed
if ! oc -n "$NS" get svc "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Create Service"
  oc -n "$NS" expose deploy "$APP_NAME" --port="$PORT" --name "$APP_NAME" --target-port="$PORT" --type=ClusterIP
fi

# create Route if needed
if ! oc -n "$NS" get route "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Create Route"
  oc -n "$NS" expose svc "$APP_NAME"
fi

# --- set env vars expected by the app ---
echo "==> Set env on deploy/${APP_NAME}"
oc -n "$NS" set env "deploy/${APP_NAME}" \
  PGHOST="${LB_HOST}" \
  PGPORT="8888" \
  PGUSER="${PGUSER}" \
  PGPASSWORD="${PGPASSWORD}" \
  PGDATABASE="${PGDATABASE}"

echo "    Current env:"
oc -n "$NS" set env "deploy/${APP_NAME}" --list | egrep 'PGHOST|PGPORT|PGUSER|PGPASSWORD|PGDATABASE' || true

echo "==> Wait for rollout"
oc -n "$NS" rollout status "deploy/${APP_NAME}" --timeout=300s || true

ROUTE_URL="$(oc -n "$NS" get route "$APP_NAME" -o jsonpath='http://{.spec.host}')"
echo
echo "✅ Viewer ready:"
echo "  Route: ${ROUTE_URL}"
echo "  Will connect to ${LB_HOST:-<pending>}:8888, DB ${PGDATABASE} as ${PGUSER}"

