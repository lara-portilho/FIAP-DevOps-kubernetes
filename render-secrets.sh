#!/usr/bin/env bash
# Gera secrets/*.yaml com valores reais, a partir dos outputs do Terraform
# (RDS/Redis/SQS) + variaveis de ambiente para o resto.
#
# O diretorio secrets/ esta no .gitignore -- esses arquivos NUNCA sao
# commitados. O ArgoCD nao rastreia esse diretorio (nao faz parte de
# manifests/), entao aplique-os manualmente com kubectl e o ArgoCD nao vai
# reverter (selfHeal so age sobre o que esta no Git).
#
# A SERVICE_API_KEY do evaluation-service e gerada aqui e semeada direto no
# banco do auth-service via um ConfigMap extra (auth-db-seed) que o init
# container do auth-service roda junto com a migration -- o auth-service so
# guarda o hash SHA-256 da key (nunca o valor em texto puro), entao inserir o
# hash direto no banco e equivalente a criar a key pela API, sem precisar
# esperar o servico subir pra chamar HTTP.
#
# Se voce rodar este script de novo com um cluster ja em pe (nao logo apos um
# terraform apply do zero), a key so passa a valer depois que o pod do
# auth-service for recriado (o init container so roda na criacao do pod):
#   kubectl rollout restart deployment/auth-service -n togglemaster
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
SERVICE_API_KEY="${SERVICE_API_KEY:-tm_key_$(openssl rand -hex 24)}"

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}
SERVICE_API_KEY_HASH=$(sha256_hex "$SERVICE_API_KEY")

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

echo "==> Gerando secrets/auth-db-seed-configmap.yaml (semeia a SERVICE_API_KEY no banco)..."
cat > secrets/auth-db-seed-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: auth-db-seed
  namespace: togglemaster
data:
  seed.sql: |
    INSERT INTO api_keys (name, key_hash, is_active)
    VALUES ('service-key', '${SERVICE_API_KEY_HASH}', true)
    ON CONFLICT (key_hash) DO NOTHING;
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
  SERVICE_API_KEY: "${SERVICE_API_KEY}"
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
echo "==> MASTER_KEY gerada para o auth-service (use se quiser criar outras keys via POST /admin/keys):"
echo "    ${AUTH_MASTER_KEY}"
echo ""
echo "==> Pronto. Aplique direto no cluster (nada aqui vai pro Git):"
echo "    kubectl apply -f secrets/"
