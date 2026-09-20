#!/usr/bin/env bash
# traffic-gen.sh — starts an in-cluster curl loop hitting frontend
# Generates realistic service-to-service HTTP traffic for Beyla to observe
set -euo pipefail

NAMESPACE="demo"
DEPLOYMENT_NAME="traffic-gen"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../sample-apps/traffic-gen.yaml"

echo "==> Deploying traffic generator Deployment in namespace: ${NAMESPACE}"
echo "    Target: http://frontend:8080/"
echo "    Interval: 0.5s"
echo "    Self-healing Deployment with restartPolicy: Always"
echo ""

# Remove any legacy bare pod if present
kubectl delete pod "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --ignore-not-found=true

# Apply deployment manifest idempotently
kubectl apply -f "${MANIFEST}"

echo ""
echo "==> Deployment applied. Check status with:"
echo "    kubectl rollout status deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE}"
echo "    kubectl logs -f -l app=${DEPLOYMENT_NAME} -n ${NAMESPACE}"
