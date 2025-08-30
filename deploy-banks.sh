#!/usr/bin/env bash
set -euo pipefail

# Deploy Postgres + Guardium External S-TAP in:
#   - bank-test1  (release: estap-bank1 -> deployment estap-bank1-estap)
#   - bank-test2  (release: estap-bank2 -> deployment estap-bank2-estap)

CHART_DIR="Guardium_External_S-TAP/charts/estap"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }
need oc; need helm

ensure_ns_and_sa() {
  local ns="$1" sa="$2"
  echo "==> Project: ${ns}"
  oc new-project "${ns}" >/dev/null 2>&1 || oc project "${ns}" >/dev/null
  oc -n "${ns}" create sa "${sa}" >/dev/null 2>&1 || true
  oc -n "${ns}" get sa "${sa}" -o name
}

deploy_postgres() {
  local ns="$1" yaml="Postgres-${ns}/postgres.yaml"
  echo "==> Apply Postgres: ${yaml}"
  [[ -f "${yaml}" ]] || { echo "ERROR: missing ${yaml}"; exit 1; }
  oc -n "${ns}" apply -f "${yaml}"
  echo "==> Wait for deploy/postgres"
  oc -n "${ns}" rollout status deploy/postgres --timeout=300s
  oc -n "${ns}" get svc postgres -o wide
}

grant_scc_anyuid() {
  local ns="$1" sa="$2"
  echo "==> Grant anyuid SCC to SA '${sa}' in ${ns} (TEST ONLY)"
  oc -n "${ns}" adm policy add-scc-to-user anyuid -z "${sa}" >/dev/null 2>&1 || true
}

install_estap() {
  local ns="$1" release="$2" values="Guardium_External_S-TAP/charts/${ns}.yaml"
  echo "==> Install/upgrade E-STAP in ${ns} (release=${release})"
  [[ -d "${CHART_DIR}" ]] || { echo "ERROR: chart dir ${CHART_DIR} not found"; exit 1; }
  [[ -f "${values}"   ]] || { echo "ERROR: values file ${values} not found"; exit 1; }

  helm upgrade --install "${release}" "${CHART_DIR}" -n "${ns}" -f "${values}"

  # Wait for the expected deployment name: <release>-estap
  local deploy="${release}-estap"
  echo "==> Wait for deploy/${deploy}"
  oc -n "${ns}" rollout status "deploy/${deploy}" --timeout=300s || true

  # Prefer the expected LB service name <release>-estap-lb; fall back to search
  local svc="${release}-estap-lb"
  if ! oc -n "${ns}" get svc "${svc}" >/dev/null 2>&1; then
    svc="$(oc -n "${ns}" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.type}{"|"}{.spec.ports[*].port}{"\n"}{end}' \
      | awk -F'|' '$2=="LoadBalancer" && $3 ~ /(^| )8888( |$)/ {print $1; exit}')"
  fi
  [[ -n "${svc}" ]] || { echo "ERROR: no LoadBalancer service on port 8888 found in ${ns}"; oc -n "${ns}" get svc; exit 1; }
  echo "    LB service: ${svc}"

  # Wait for external hostname/IP
  echo -n "==> Waiting for external endpoint"
  local host=""
  for _ in {1..60}; do
    host="$(oc -n "${ns}" get svc "${svc}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${host}" ]] || host="$(oc -n "${ns}" get svc "${svc}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && break
    echo -n "."
    sleep 3
  done
  echo
  if [[ -z "${host}" ]]; then
    echo "WARN: LB not ready yet. Check later:"
    echo "  oc -n ${ns} get svc ${svc} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{\"\\n\"}{.status.loadBalancer.ingress[0].ip}{\"\\n\"}'"
  else
    echo "    External endpoint: ${host}:8888"
  fi
  oc -n "${ns}" get svc "${svc}" -o wide
}

deploy_bank() {
  local ns="$1" sa="$2" release="$3"
  echo
  echo "==================== ${ns} (release: ${release}) ===================="
  ensure_ns_and_sa "${ns}" "${sa}"
  deploy_postgres "${ns}"
  grant_scc_anyuid "${ns}" "${sa}"
  install_estap "${ns}" "${release}"
}

# ----- run both -----
deploy_bank "bank-test1" "estap" "estap-bank1"
deploy_bank "bank-test2" "estap" "estap-bank2"

echo
echo "✅ Done."
echo "Show E-STAP LBs:"
echo "  for ns in bank-test1 bank-test2; do oc -n \$ns get svc | grep estap | grep LoadBalancer; done"

