#!/usr/bin/env bash
# Gera secrets/*.yaml com valores reais, a partir dos outputs do Terraform
# (RDS/Redis/SQS) + variaveis de ambiente para o resto.
#
# O diretorio secrets/ esta no .gitignore -- esses arquivos NUNCA sao
# commitados. O ArgoCD nao rastreia esse diretorio (nao faz parte de
# manifests/), entao aplique-os manualmente com kubectl e o ArgoCD nao vai
# reverter (selfHeal so age sobre o que esta no Git).
#
# SERVICE_API_KEY do evaluation-service NAO e gerado aqui -- fica como
# placeholder ate rodar ./setup-service-key.sh depois que o auth-service
# estiver de pe (precisa chamar o proprio auth-service pra emitir a key).
#
# Uso:
#   export DB_PASSWORD='a mesma senha do terraform.tfvars'
#   ./render-secrets.sh
#   kubectl apply -f secrets/
set -euo pipefail

TF_DIR="${TF_DIR:-../FIAP-DevOps-terraform}"
DB_USERNAME="${DB_USERNAME:-postgres}"
: "${DB_PASSWORD:?defina DB_PASSWORD (a mesma senha de db_password no terraform.tfvars)}"
AUTH_MASTER_KEY="${AUTH_MASTER_KEY:-$(openssl rand -hex 24)}"

mkdir -p secrets

echo "==> Lendo outputs do Terraform em ${TF_DIR}..."
RDS_JSON=$(terraform -chdir="$TF_DIR" output -json rds_endpoints)
RDS_AUTH=$(echo "$RDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth'])")
RDS_FLAGS=$(echo "$RDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['flags'])")
RDS_TARGETING=$(echo "$RDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['targeting'])")
REDIS_ENDPOINT=$(terraform -chdir="$TF_DIR" output -raw redis_endpoint)
SQS_URL=$(terraform -chdir="$TF_DIR" output -raw sqs_queue_url)

echo "==> Gerando secrets/auth-service-secret.yaml..."
cat > secrets/auth-service-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-service-secrets
  namespace: togglemaster
type: Opaque
stringData:
  DATABASE_URL: "postgres://${DB_USERNAME}:${DB_PASSWORD}@${RDS_AUTH}:5432/auth_db"
  MASTER_KEY: "${AUTH_MASTER_KEY}"
EOF

echo "==> Gerando secrets/flag-service-secret.yaml..."
cat > secrets/flag-service-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: flag-service-secrets
  namespace: togglemaster
type: Opaque
stringData:
  DATABASE_URL: "postgres://${DB_USERNAME}:${DB_PASSWORD}@${RDS_FLAGS}:5432/flags_db"
EOF

echo "==> Gerando secrets/targeting-service-secret.yaml..."
cat > secrets/targeting-service-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: targeting-service-secrets
  namespace: togglemaster
type: Opaque
stringData:
  DATABASE_URL: "postgres://${DB_USERNAME}:${DB_PASSWORD}@${RDS_TARGETING}:5432/targeting_db"
EOF

echo "==> Gerando secrets/evaluation-service-secret.yaml..."
cat > secrets/evaluation-service-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: evaluation-service-secrets
  namespace: togglemaster
type: Opaque
stringData:
  REDIS_URL: "redis://${REDIS_ENDPOINT}:6379"
  SERVICE_API_KEY: "PENDING_RUN_SETUP_SERVICE_KEY_SH"
  AWS_SQS_URL: "${SQS_URL}"
EOF

echo "==> Gerando secrets/analytics-service-secret.yaml..."
cat > secrets/analytics-service-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: analytics-service-secrets
  namespace: togglemaster
type: Opaque
stringData:
  AWS_SQS_URL: "${SQS_URL}"
EOF

echo ""
echo "==> MASTER_KEY gerada para o auth-service (guarde, precisa dela no setup-service-key.sh):"
echo "    ${AUTH_MASTER_KEY}"
echo ""
echo "==> Pronto. Aplique direto no cluster (nada aqui vai pro Git):"
echo "    kubectl apply -f secrets/"
