FROM oryd/oathkeeper:v25.4.0

# Copy static JWKS key (not a template - does not contain env var placeholders).
ADD jwks.json /jwks.json

# Copy config and rules as templates; entrypoint renders them at container start.
ADD config.yml /config.yml.template
ADD rules.json /rules.json.template

# Entrypoint: validates env vars, runs envsubst on templates, then starts Oathkeeper.
COPY entrypoint.sh /entrypoint.sh

USER root
RUN chmod +x /entrypoint.sh \
  && if ! command -v envsubst >/dev/null 2>&1; then \
  if command -v apk >/dev/null 2>&1; then \
  apk add --no-cache gettext; \
  elif command -v apt-get >/dev/null 2>&1; then \
  apt-get update \
  && apt-get install -y --no-install-recommends gettext-base \
  && rm -rf /var/lib/apt/lists/*; \
  else \
  echo "No supported package manager found to install envsubst" >&2; \
  exit 1; \
  fi; \
  fi

ENTRYPOINT ["/entrypoint.sh"]
