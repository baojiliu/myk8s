# Istio Operator (Sail Operator)

Sail Operator is deployed by the Argo CD Application `argocd/platform/istio-operator.yaml`,
which installs the official Helm chart from `https://istio-ecosystem.github.io/sail-operator`.

The Istio control plane is managed separately via `platform/base/istio-control-plane/`.
