#!/usr/bin/env bash
# load-testing/k6/run.sh — executes k6 external load testing scenarios against frontend NodePort 30080
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/scenarios"

# Detect k6 binary
K6_BIN=$(which k6 2>/dev/null || echo "${HOME}/.local/bin/k6")
if [[ ! -x "${K6_BIN}" ]]; then
  echo "Error: k6 binary not found in PATH or ~/.local/bin/k6"
  exit 1
fi

# Detect Kubernetes Node IP — filter to first IPv4 address (handles dual-stack IPv4+IPv6)
NODE_IP=$(kubectl get nodes -o jsonpath='{range .items[0].status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}' 2>/dev/null \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
NODE_IP="${NODE_IP:-127.0.0.1}"
TARGET_URL="http://${NODE_IP}:30080/"

# Default scenario
SCENARIO="${1:-ramp-up}"
if [[ "$#" -gt 0 ]]; then
  shift
fi

# Resolve scenario file
if [[ -f "${SCENARIOS_DIR}/${SCENARIO}.js" ]]; then
  SCENARIO_FILE="${SCENARIOS_DIR}/${SCENARIO}.js"
elif [[ -f "${SCENARIO}" ]]; then
  SCENARIO_FILE="${SCENARIO}"
else
  echo "Usage: $0 [smoke | ramp-up | path/to/script.js] [k6-flags...]"
  echo ""
  echo "Available predefined scenarios:"
  echo "  smoke    - 10s light sanity check (2 VUs)"
  echo "  ramp-up  - 3m staged traffic curve (0 -> 5 -> 15 -> 0 VUs)"
  exit 1
fi

echo "=========================================================="
echo "  Grafana k6 External Load Testing Suite"
echo "=========================================================="
echo "  Scenario:   ${SCENARIO_FILE}"
echo "  Target:     ${TARGET_URL}"
echo "  Grafana:    http://${NODE_IP}:30300"
echo "=========================================================="
echo ""

"${K6_BIN}" run -e TARGET_URL="${TARGET_URL}" "${SCENARIO_FILE}" "$@"

echo ""
echo "==> Test run completed."
echo "    View metrics in Grafana at: http://${NODE_IP}:30300"
