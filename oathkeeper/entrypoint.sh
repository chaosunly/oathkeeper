#!/bin/sh
set -e

# Ensure required environment variables are present before rendering templates.
: "${KRATOS_INTERNAL:?KRATOS_INTERNAL is required (e.g., kratos.railway.internal)}"
: "${HYDRA_INTERNAL:?HYDRA_INTERNAL is required (e.g., hydra.railway.internal)}"
: "${KETO_INTERNAL:?KETO_INTERNAL is required (e.g., keto.railway.internal)}"
: "${UI_INTERNAL:?UI_INTERNAL is required (e.g., ui.railway.internal)}"
: "${UI_PORT:?UI_PORT is required (e.g., 8080)}"
: "${PUBLIC_URL:?PUBLIC_URL is required (full public base URL, e.g., https://gateway.railway.app)}"

echo "Oathkeeper configuration:"
echo "  KRATOS_INTERNAL: ${KRATOS_INTERNAL}"
echo "  HYDRA_INTERNAL:  ${HYDRA_INTERNAL}"
echo "  KETO_INTERNAL:   ${KETO_INTERNAL}"
echo "  UI_INTERNAL:     ${UI_INTERNAL}:${UI_PORT}"
echo "  PUBLIC_URL:      ${PUBLIC_URL}"

# Render config and rules templates using environment variables.
envsubst '${KRATOS_INTERNAL} ${HYDRA_INTERNAL} ${KETO_INTERNAL} ${UI_INTERNAL} ${UI_PORT} ${PUBLIC_URL}' \
  < /config.yml.template \
  > /config.yml

envsubst '${KETO_INTERNAL} ${UI_INTERNAL} ${UI_PORT} ${PUBLIC_URL}' \
  < /rules.json.template \
  > /rules.json

exec oathkeeper serve --config /config.yml
