#!/usr/bin/env bash
# traffic-gen.sh — starts an in-cluster curl loop hitting frontend
# Generates realistic service-to-service HTTP traffic for Beyla to observe
set -euo pipefail

NAMESPACE="demo"
POD_NAME="traffic-gen"

echo "==> Starting traffic generator pod in namespace: ${NAMESPACE}"
echo "    Target: http://frontend:8080/"
echo "    Interval: 0.5s"
echo "    Press Ctrl+C and run: kubectl delete pod ${POD_NAME} -n ${NAMESPACE}  to stop"
echo ""

# Delete any existing traffic-gen pod first
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true

kubectl run "${POD_NAME}" \
  --namespace="${NAMESPACE}" \
  --image=curlimages/curl:8.7.1 \
  --restart=Never \
  --command \
  -- sh -c 'while true; do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://frontend:8080/);
    echo "$(date -Iseconds) HTTP $code";
    sleep 0.5;
  done'

echo ""
echo "==> Pod started. Tail logs with:"
echo "    kubectl logs -f ${POD_NAME} -n ${NAMESPACE}"
