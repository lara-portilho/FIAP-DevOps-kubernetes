#!/usr/bin/env bash
# Cria a API key de servico chamando o auth-service (POST /admin/keys com o
# MASTER_KEY), e atualiza o Secret do evaluation-service no cluster.
# Rode DEPOIS que o ArgoCD ja tiver sincronizado os 6 Applications e os pods
# estiverem saudaveis (kubectl get pods -n togglemaster).
#
# Uso:
#   export MASTER_KEY='a MASTER_KEY gerada pelo render-secrets.sh'
#   ./setup-service-key.sh
set -euo pipefail

NAMESPACE="togglemaster"
: "${MASTER_KEY:?defina MASTER_KEY (a mesma gerada pelo render-secrets.sh)}"

echo "==> Obtendo URL do Load Balancer (Nginx Ingress)..."
ELB=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -z "$ELB" ]; then
  echo "ERRO: Ingress nao encontrado ainda. Confirme que o ArgoCD ja sincronizou 'togglemaster-platform'."
  exit 1
fi
AUTH_URL="http://${ELB}/auth"

echo "==> Aguardando auth-service responder em ${AUTH_URL}/health..."
MAX_ATTEMPTS=30
ATTEMPT=0
until curl -sf "${AUTH_URL}/health" > /dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    echo "ERRO: auth-service nao respondeu apos $((MAX_ATTEMPTS * 10))s. Verifique 'kubectl get pods -n ${NAMESPACE}'."
    exit 1
  fi
  echo "  aguardando... (${ATTEMPT}/${MAX_ATTEMPTS})"
  sleep 10
done
echo "==> auth-service OK."

echo "==> Criando API key em ${AUTH_URL}..."
RESPONSE=$(curl -s -X POST "${AUTH_URL}/admin/keys" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"name": "service-key"}')

NEW_KEY=$(echo "$RESPONSE" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)

if [ -z "$NEW_KEY" ]; then
  echo "ERRO: Nao foi possivel extrair a key. Resposta: $RESPONSE"
  exit 1
fi

echo "==> Key gerada: ${NEW_KEY}"

echo "==> Atualizando Secret no Kubernetes..."
kubectl patch secret evaluation-service-secrets -n "$NAMESPACE" \
  -p "{\"data\":{\"SERVICE_API_KEY\":\"$(echo -n "$NEW_KEY" | base64)\"}}"

echo "==> Reiniciando evaluation-service..."
kubectl rollout restart deployment/evaluation-service -n "$NAMESPACE"
kubectl rollout status deployment/evaluation-service -n "$NAMESPACE"

echo ""
echo "Concluido! api_key para o Insomnia/testes: ${NEW_KEY}"
echo ""
echo "Nota: o ArgoCD tem selfHeal ativado no Application 'togglemaster-evaluation-service'."
echo "Como o Secret commitado no Git ainda tem o placeholder, o ArgoCD pode reverter esse"
echo "patch no proximo sync. Depois de rodar este script, atualize tambem"
echo "manifests/evaluation-service/secret.yaml com esta key e faca commit/push,"
echo "para o Git continuar sendo a fonte da verdade."
