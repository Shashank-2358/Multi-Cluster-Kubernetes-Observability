#!/usr/bin/env bash
# verify.sh — end-to-end pipeline health check for Phase 0
set -euo pipefail

PASS=0; FAIL=0
GREEN="\033[0;32m"; RED="\033[0;31m"; RESET="\033[0m"; BOLD="\033[1m"

check() {
  local label="$1"; shift
  if eval "$@" &>/dev/null; then
    echo -e "  ${GREEN}✅ PASS${RESET}  ${label}"
    ((PASS++)) || true
  else
    echo -e "  ${RED}❌ FAIL${RESET}  ${label}"
    ((FAIL++)) || true
  fi
}

echo -e "\n${BOLD}=== Phase 0 Pipeline Verification ===${RESET}\n"

echo -e "${BOLD}[1] Cluster${RESET}"
check "Node is Ready" "kubectl get node | grep -q Ready"

echo -e "\n${BOLD}[2] Sample Apps (namespace: demo)${RESET}"
check "backend pod Running" "kubectl get pod -n demo -l app=backend | grep -q Running"
check "frontend pod Running" "kubectl get pod -n demo -l app=frontend | grep -q Running"
check "backend service exists" "kubectl get svc backend -n demo"
check "frontend service exists" "kubectl get svc frontend -n demo"

echo -e "\n${BOLD}[3] Grafana Beyla (namespace: beyla)${RESET}"
check "beyla DaemonSet exists" "kubectl get ds beyla -n beyla"
check "beyla pod Running" "kubectl get pod -n beyla -l app=beyla | grep -q Running"
BEYLA_POD=$(kubectl get pod -n beyla -l app=beyla -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${BEYLA_POD}" ]]; then
  check "beyla /metrics returns 200" \
    "curl -sf http://localhost:9090/metrics | grep -E -q '(beyla|http_server)'"
  echo "  ℹ️  Beyla pod: ${BEYLA_POD}"
fi

echo -e "\n${BOLD}[4] Prometheus (namespace: monitoring)${RESET}"
check "prometheus pod Running" "kubectl get pod -n monitoring -l app=prometheus | grep -q Running"
PROM_POD=$(kubectl get pod -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${PROM_POD}" ]]; then
  check "beyla target is UP in Prometheus" \
    "kubectl exec -n monitoring ${PROM_POD} -- wget -qO- 'http://localhost:9090/api/v1/targets' | grep -q '\"health\":\"up\"'"
fi

echo -e "\n${BOLD}[5] Grafana (namespace: monitoring)${RESET}"
check "grafana pod Running" "kubectl get pod -n monitoring -l app=grafana | grep -q Running"
GRAFANA_POD=$(kubectl get pod -n monitoring -l app=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${GRAFANA_POD}" ]]; then
  check "grafana /api/health returns ok" \
    "kubectl exec -n monitoring ${GRAFANA_POD} -- wget -qO- http://localhost:3000/api/health | grep -q ok"
fi

echo -e "\n${BOLD}[6] Traffic Generator${RESET}"
check "traffic-gen pod exists" "kubectl get pod traffic-gen -n demo"

echo -e "\n${BOLD}=== Summary ===${RESET}"
echo -e "  Passed: ${GREEN}${PASS}${RESET}  Failed: ${RED}${FAIL}${RESET}\n"
[[ ${FAIL} -eq 0 ]] && echo -e "${GREEN}${BOLD}All checks passed! Pipeline is healthy.${RESET}" \
                     || echo -e "${RED}${BOLD}Some checks failed. Review output above.${RESET}"

echo -e "\nAccess points:"
echo "  Grafana:    http://172.23.95.187:30300  (admin/admin)"
echo "  Prometheus: http://172.23.95.187:30900"
