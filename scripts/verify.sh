#!/usr/bin/env bash
# verify.sh — end-to-end pipeline health check for Phase 0
# Checks all 6 stages: cluster, sample-apps, beyla, prometheus, grafana, traffic-gen
set -euo pipefail

PASS=0; FAIL=0
GREEN="\033[0;32m"; RED="\033[0;31m"; RESET="\033[0m"; BOLD="\033[1m"

pass() { echo -e "  ${GREEN}✅ PASS${RESET}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}❌ FAIL${RESET}  $1"; ((FAIL++)) || true; }

check_cmd() {
  # check_cmd "label" cmd args...   (no nested eval — runs directly)
  local label="$1"; shift
  if "$@" &>/dev/null; then pass "$label"; else fail "$label"; fi
}

echo -e "\n${BOLD}=== Phase 0 Pipeline Verification ===${RESET}\n"

# ── [1] Cluster ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[1] Cluster${RESET}"
check_cmd "Node is Ready" bash -c "kubectl get node | grep -q Ready"

# ── [2] Sample Apps ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2] Sample Apps (namespace: demo)${RESET}"
for svc in backend frontend auth; do
  check_cmd "${svc} pod Running"      bash -c "kubectl get pod -n demo -l app=${svc} | grep -q Running"
  check_cmd "${svc} service exists"   bash -c "kubectl get svc ${svc} -n demo &>/dev/null"
done

# ── [3] Grafana Beyla (eBPF) ─────────────────────────────────────────────────
echo -e "\n${BOLD}[3] Grafana Beyla (namespace: beyla)${RESET}"
check_cmd "beyla DaemonSet exists" bash -c "kubectl get ds beyla -n beyla &>/dev/null"
check_cmd "beyla pod Running"      bash -c "kubectl get pod -n beyla -l app=beyla | grep -q Running"

BEYLA_POD=$(kubectl get pod -n beyla -l app=beyla -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
PROM_POD=$(kubectl get pod -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${BEYLA_POD}" && -n "${PROM_POD}" ]]; then
  BEYLA_HOST_IP=$(kubectl get pod -n beyla "${BEYLA_POD}" -o jsonpath='{.status.hostIP}' 2>/dev/null || true)

  # Check 1: Prometheus has an 'up' target (proves scraping works end-to-end)
  if kubectl exec -n monitoring "${PROM_POD}" -- \
      wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null | grep -q '"health":"up"'; then
    pass "beyla target scraped by Prometheus (health=up)"
  else
    fail "beyla target scraped by Prometheus (health=up)"
  fi

  # Check 2: L4 metric exists in TSDB
  if kubectl exec -n monitoring "${PROM_POD}" -- \
      wget -qO- 'http://localhost:9090/api/v1/query?query=beyla_network_flow_bytes_total' 2>/dev/null \
      | grep -q '"result":\[{'; then
    pass "L4: beyla_network_flow_bytes_total metric present in Prometheus"
  else
    fail "L4: beyla_network_flow_bytes_total metric present in Prometheus"
  fi

  # Check 3: L7 HTTP server metric exists in TSDB
  if kubectl exec -n monitoring "${PROM_POD}" -- \
      wget -qO- 'http://localhost:9090/api/v1/query?query=http_server_request_duration_seconds_count' 2>/dev/null \
      | grep -q '"result":\[{'; then
    pass "L7: http_server_request_duration_seconds_count metric present"
  else
    fail "L7: http_server_request_duration_seconds_count metric present"
  fi

  echo "  ℹ️  Beyla pod: ${BEYLA_POD}  hostIP: ${BEYLA_HOST_IP}"
fi

# ── [4] Prometheus ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}[4] Prometheus (namespace: monitoring)${RESET}"
check_cmd "prometheus pod Running" bash -c "kubectl get pod -n monitoring -l app=prometheus | grep -q Running"

if [[ -n "${PROM_POD}" ]]; then
  if kubectl exec -n monitoring "${PROM_POD}" -- \
      wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null | grep -q '"health":"up"'; then
    pass "beyla target is UP in Prometheus"
  else
    fail "beyla target is UP in Prometheus"
  fi
fi

# ── [5] Grafana ──────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[5] Grafana (namespace: monitoring)${RESET}"
check_cmd "grafana pod Running" bash -c "kubectl get pod -n monitoring -l app=grafana | grep -q Running"

GRAFANA_POD=$(kubectl get pod -n monitoring -l app=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${GRAFANA_POD}" ]]; then
  if kubectl exec -n monitoring "${GRAFANA_POD}" -- \
      wget -qO- http://localhost:3000/api/health 2>/dev/null | grep -q ok; then
    pass "grafana /api/health returns ok"
  else
    fail "grafana /api/health returns ok"
  fi

  # Check dashboard is provisioned
  if kubectl exec -n monitoring "${GRAFANA_POD}" -- \
      wget -qO- 'http://admin:admin@localhost:3000/api/search?type=dash-db' 2>/dev/null \
      | grep -q 'phase0-beyla'; then
    pass "Grafana dashboard 'phase0-beyla' provisioned"
  else
    fail "Grafana dashboard 'phase0-beyla' provisioned"
  fi

  # Check datasource
  if kubectl exec -n monitoring "${GRAFANA_POD}" -- \
      wget -qO- 'http://admin:admin@localhost:3000/api/datasources' 2>/dev/null \
      | grep -q '"uid":"prometheus"'; then
    pass "Grafana Prometheus datasource (uid: prometheus) present"
  else
    fail "Grafana Prometheus datasource (uid: prometheus) present"
  fi
fi

# ── [6] Traffic Generator ────────────────────────────────────────────────────
echo -e "\n${BOLD}[6] Traffic Generator${RESET}"
check_cmd "traffic-gen deployment exists" bash -c "kubectl get deployment traffic-gen -n demo &>/dev/null"
check_cmd "traffic-gen pod Running"      bash -c "kubectl get pod -n demo -l app=traffic-gen | grep -q Running"

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Summary ===${RESET}"
echo -e "  Passed: ${GREEN}${PASS}${RESET}  Failed: ${RED}${FAIL}${RESET}\n"
[[ ${FAIL} -eq 0 ]] \
  && echo -e "${GREEN}${BOLD}All checks passed! Pipeline is healthy.${RESET}" \
  || echo -e "${RED}${BOLD}Some checks failed. Review output above.${RESET}"

NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")
echo -e "\nAccess points:"
echo "  Grafana:    http://${NODE_IP}:30300  (admin/admin)"
echo "  Prometheus: http://${NODE_IP}:30900"
