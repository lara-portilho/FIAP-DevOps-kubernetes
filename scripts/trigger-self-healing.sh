#!/usr/bin/env bash
# Simula o webhook do alerta: dispara o workflow Self-Healing via repository_dispatch.
#
# Uso:
#   export GITHUB_TOKEN=<fine-grained PAT com "Contents: read & write" neste repo>
#   ./scripts/trigger-self-healing.sh auth-service "erro 5xx acima de 5%"
set -euo pipefail

SERVICE="${1:?informe o serviço, ex: auth-service}"
REASON="${2:-teste manual via script}"
REPO="${GITHUB_REPO:-lara-portilho/FIAP-DevOps-kubernetes}"
: "${GITHUB_TOKEN:?defina GITHUB_TOKEN}"

payload=$(jq -n --arg s "$SERVICE" --arg r "$REASON" \
  '{event_type: "self-healing", client_payload: {service: $s, alertname: "TesteManual", reason: $r}}')

curl -fsS -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${REPO}/dispatches" \
  -d "$payload"

echo "Disparado. Acompanhe em https://github.com/${REPO}/actions/workflows/self-healing.yml"
