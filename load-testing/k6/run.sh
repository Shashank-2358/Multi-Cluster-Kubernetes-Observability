#!/usr/bin/env bash
# ==============================================================================
# load-testing/k6/run.sh — Multi-Cluster Kubernetes k6 Load Generation Suite
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/scenarios"

# Terminal formatting
BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
MAGENTA="\033[0;35m"
RED="\033[0;31m"
RESET="\033[0m"

# Help / Usage Function
show_help() {
  echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
  echo -e "${BOLD}       Multi-Cluster Kubernetes k6 Load Testing Suite                         ${RESET}"
  echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
  echo -e "${BOLD}Usage:${RESET} $0 <scenario> [k6-flags...]"
  echo ""
  echo -e "${BOLD}Available Scenarios:${RESET}"
  echo -e "  ${GREEN}1, smoke${RESET}          15s light check (2 VUs) — verifies pods and 200 OK responses"
  echo -e "  ${GREEN}2, load, ramp-up${RESET}  3m realistic traffic curve (0 -> 10 -> 15 -> 0 VUs)"
  echo -e "  ${YELLOW}3, spike, hpa${RESET}     1m30s VIOLENT surge (2 -> 45 VUs) — ${BOLD}Triggers HPA pod autoscaling!${RESET}"
  echo -e "  ${MAGENTA}4, stress${RESET}         2m30s step-ladder test (10 -> 25 -> 50 -> 75 VUs) — finds breaking point"
  echo -e "  ${CYAN}5, soak${RESET}           10m sustained load (10 VUs) — checks for memory leaks & stability"
  echo -e "  ${CYAN}6, constant, rps${RESET}  2m fixed throughput (40 RPS arrival rate) — open workload model"
  echo -e "  ${RED}stop${RESET}                  Stop / kill any active background k6 tests"
  echo -e "  ${CYAN}status${RESET}                Check if k6 load test is currently running"
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo -e "  $0 ${GREEN}smoke${RESET}                     # Quick sanity check"
  echo -e "  $0 ${YELLOW}spike${RESET}                     # Trigger HPA autoscaling (watch with kubectl get hpa -w)"
  echo -e "  nohup $0 ${GREEN}load${RESET} > k6.log 2>&1 &  # Run in background"
  echo -e "  $0 ${RED}stop${RESET}                      # Stop the background test"
  echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
}

# Check if arguments provided
if [[ "$#" -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "list" ]]; then
  show_help
  exit 0
fi

# Stop command
if [[ "$1" == "stop" ]]; then
  echo -e "${YELLOW}Stopping all running k6 load generation processes...${RESET}"
  if pkill -f "k6 run" 2>/dev/null; then
    echo -e "${GREEN}==> Successfully stopped all k6 processes.${RESET}"
  else
    echo -e "${CYAN}No active k6 processes found.${RESET}"
  fi
  exit 0
fi

# Status command
if [[ "$1" == "status" ]]; then
  if pgrep -a k6 2>/dev/null; then
    echo -e "${GREEN}Active k6 process found:${RESET}"
    pgrep -a k6
  else
    echo -e "${CYAN}No k6 processes currently running.${RESET}"
  fi
  exit 0
fi

# 1. Detect k6 binary
K6_BIN=$(which k6 2>/dev/null || echo "${HOME}/.local/bin/k6")
if [[ ! -x "${K6_BIN}" ]]; then
  echo -e "${RED}Error: k6 binary not found in PATH or ~/.local/bin/k6${RESET}"
  echo "Install k6 with: sudo gpg -k && sudo apt-get install k6"
  exit 1
fi

# 2. Detect Kubernetes Node IP & Target URL
if [[ -z "${TARGET_URL:-}" ]]; then
  NODE_IP=$(kubectl get nodes --request-timeout='2s' -o jsonpath='{range .items[0].status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}' 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  NODE_IP="${NODE_IP:-127.0.0.1}"
  TARGET_URL="http://${NODE_IP}:30080/"
else
  NODE_IP=$(echo "${TARGET_URL}" | sed -E 's|https?://([^:/]+).*|\1|')
fi

# 3. Resolve scenario name to file
SCENARIO="$1"
shift

case "${SCENARIO}" in
  1|smoke|1_smoke)
    SCENARIO_FILE="${SCENARIOS_DIR}/1_smoke.js"
    SCENARIO_NAME="Smoke Test (Sanity Check)"
    ;;
  2|load|2_load|ramp-up)
    SCENARIO_FILE="${SCENARIOS_DIR}/2_load.js"
    SCENARIO_NAME="Load / Ramp-Up Test (Normal Peak Traffic)"
    ;;
  3|spike|3_spike|hpa)
    SCENARIO_FILE="${SCENARIOS_DIR}/3_spike.js"
    SCENARIO_NAME="Spike Test (HPA Autoscaling Trigger)"
    ;;
  4|stress|4_stress)
    SCENARIO_FILE="${SCENARIOS_DIR}/4_stress.js"
    SCENARIO_NAME="Stress Test (Finding Upper Limits)"
    ;;
  5|soak|5_soak)
    SCENARIO_FILE="${SCENARIOS_DIR}/5_soak.js"
    SCENARIO_NAME="Soak / Endurance Test (Reliability & Memory)"
    ;;
  6|constant|6_constant_rate|rps)
    SCENARIO_FILE="${SCENARIOS_DIR}/6_constant_rate.js"
    SCENARIO_NAME="Constant Arrival Rate (Fixed 40 RPS)"
    ;;
  *)
    if [[ -f "${SCENARIO}" ]]; then
      SCENARIO_FILE="${SCENARIO}"
      SCENARIO_NAME="Custom Script: ${SCENARIO}"
    elif [[ -f "${SCENARIOS_DIR}/${SCENARIO}.js" ]]; then
      SCENARIO_FILE="${SCENARIOS_DIR}/${SCENARIO}.js"
      SCENARIO_NAME="Scenario: ${SCENARIO}"
    else
      echo -e "${RED}Error: Unknown scenario '${SCENARIO}'${RESET}\n"
      show_help
      exit 1
    fi
    ;;
esac

# 4. Banner
echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
echo -e "${BOLD}  Grafana k6 Load Generator: ${GREEN}${SCENARIO_NAME}${RESET}"
echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
echo -e "  ${BOLD}Target App:${RESET}      ${TARGET_URL} (frontend -> backend -> auth)"
echo -e "  ${BOLD}Scenario File:${RESET}   ${SCENARIO_FILE}"
echo -e "  ${BOLD}Grafana URL:${RESET}     http://${NODE_IP}:30300"
if [[ "${SCENARIO}" =~ (3|spike|3_spike|hpa) ]]; then
  echo -e "  ${YELLOW}${BOLD}HPA Live Watch:${RESET}  ${YELLOW}kubectl get hpa -n demo -w${RESET} (run in another terminal!)"
fi
echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
echo ""

# 5. Execute k6
"${K6_BIN}" run -e TARGET_URL="${TARGET_URL}" "${SCENARIO_FILE}" "$@"

echo ""
echo -e "${GREEN}==> Load generation finished successfully.${RESET}"
echo -e "    View eBPF telemetry in Grafana at: ${CYAN}http://${NODE_IP}:30300${RESET}"
