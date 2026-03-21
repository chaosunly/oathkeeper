FROM oryd/oathkeeper:v25.4.0

# Copy static JWKS key (not a template - does not contain env var placeholders).
ADD jwks.json /jwks.json

# Copy config and rules as templates; entrypoint renders them at container start.
ADD config.yml /config.yml.template
ADD rules.json /rules.json.template

# Entrypoint: validates env vars, runs envsubst on templates, then starts Oathkeeper.
COPY entrypoint.sh /entrypoint.sh

USER root
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
