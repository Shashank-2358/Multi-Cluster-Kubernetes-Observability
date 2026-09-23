# Observability (Phase 0) Helm Chart

This Helm chart deploys the **Multi-Cluster Kubernetes Observability — Phase 0** stack.

## What is Helm and Why Was it Added?
Helm is a package manager for Kubernetes. It allows you to package multiple Kubernetes YAML manifests into a single reusable "Chart".

This Helm chart is the **primary deployment method** for the project, replacing the previous static YAML manifests. It allows you to:
- Deploy the entire stack with a single command.
- Easily toggle individual components on/off (via `values.yaml`).
- Package and version the observability stack for future multi-cluster environments.

## Helm Chart Structure
- `Chart.yaml`: Contains metadata about the chart (name, version, etc.).
- `values.yaml`: Contains the default configuration values. You can toggle components on/off here (e.g., `prometheus.enabled: true`).
- `templates/`: Contains the Kubernetes manifests. Helm reads the configuration from `values.yaml` and injects them into these templates before sending them to Kubernetes.

## How to Use This Helm Chart

### 1. Validate the Chart (Static Validation)
Before installing, you can lint the chart to ensure there are no syntax errors:
```bash
helm lint ./helm/observability
```

You can also render the templates locally to see exactly what Kubernetes manifests will be generated, without actually deploying anything:
```bash
helm template observability ./helm/observability
```

### 2. Install on a Cluster
You can install the entire observability stack with:
```bash
helm install observability ./helm/observability
```

### 3. Upgrade the Deployment
If you make changes to `values.yaml` or the templates, apply the changes with:
```bash
helm upgrade observability ./helm/observability
```

### 4. Uninstall
To completely remove the stack deployed by Helm:
```bash
helm uninstall observability
```

## Future Multi-Cluster Architecture
In Phase 1 and beyond, Helm makes it significantly easier to deploy this stack to multiple clusters. Instead of copying YAML files and manually changing labels (like `cluster-01` to `cluster-02`), you can deploy the same chart with different `values.yaml` overrides for each cluster.
