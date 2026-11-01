#!/usr/bin/env bash
# Bootstrap completo do GitOps, do zero ate os pods rodando.
# Rode depois de um `terraform apply` (ou re-apply) no repo FIAP-DevOps-terraform.
#
# Uso:
#   export DB_PASSWORD='a mesma senha de db_password no terraform.tfvars'
#   export NEW_RELIC_LICENSE_KEY='sua license key de ingest do New Relic'
#   ./bootstrap.sh
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-togglemaster-cluster}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="togglemaster"
OBS_NAMESPACE="observability"

: "${DB_PASSWORD:?defina DB_PASSWORD (a mesma senha de db_password no terraform.tfvars)}"
: "${NEW_RELIC_LICENSE_KEY:?defina NEW_RELIC_LICENSE_KEY (license key de ingest do New Relic)}"

echo "==> [1/4] Configurando kubectl para o cluster ${CLUSTER_NAME}..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo "==> [2/4] Criando namespaces ${NAMESPACE} e ${OBS_NAMESPACE} (idempotente)..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$OBS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [3/4] Gerando e aplicando os Secrets (nunca vao pro Git; a SERVICE_API_KEY"
echo "    ja e semeada no banco pelo init container do auth-service)..."
./render-secrets.sh
kubectl apply -f secrets/

echo "==> [4/4] Aplicando as 9 Applications do ArgoCD (plataforma, 5 servicos e"
echo "    stack de observabilidade: kube-prometheus-stack, Loki e Alloy)..."
echo "    (se a infra acabou de ser recriada do zero, os Deployments comecam com uma"
echo "     imagem PLACEHOLDER ate os 5 CIs de servico rodarem pelo menos uma vez --"
echo "     dispare um push/re-run em cada um dos 5 repos de servico se for o caso)"
kubectl apply -f argocd/

echo ""
echo "==> Bootstrap completo! Acompanhando o status dos pods (Ctrl+C pra sair):"
echo ""
kubectl get applications -n argocd
kubectl get pods -n "$NAMESPACE" -w
