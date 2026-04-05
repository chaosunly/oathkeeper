# Oathkeeper — API Gateway Decision Point

ORY Oathkeeper acts as the authentication and authorization proxy for all `/api/*` traffic in this platform. It sits behind nginx (the public-facing gateway) and in front of the Next.js application (`iam-app`), enforcing identity and permission rules before any request reaches application code.

## Architecture

```
Browser / Client
      │
      ▼
  nginx (gateway)          ← public entrypoint, routes by path prefix
      │
      ├─ /auth/*           → iam-app directly (login/registration UI, no auth needed)
      ├─ /.ory/*           → Kratos public API (self-service flows)
      ├─ /oauth2/*         → Hydra public API (OAuth2/OIDC endpoints)
      ├─ /self-service/*   → Kratos public API
      ├─ /api/*            → Oathkeeper proxy (port 4455)  ◄── this service
      └─ /*                → iam-app directly (Next.js pages)
              │
              ▼
        Oathkeeper (4455)
              │  evaluates each request against rules.json
              │  authenticates, authorizes, mutates, then proxies
              ▼
           iam-app (Next.js)
```

Oathkeeper also exposes a management API on port `4456` (rules, health).

## Environment Variables

All values are injected at container start by `entrypoint.sh` via `envsubst`. None are baked into the image.

| Variable           | Example                                  | Used in              |
|--------------------|------------------------------------------|----------------------|
| `KRATOS_INTERNAL`  | `kratos.railway.internal`                | `config.yml` — cookie session check URL |
| `HYDRA_INTERNAL`   | `hydra.railway.internal`                 | `config.yml` — JWKS URL, introspection URL |
| `KETO_INTERNAL`    | `keto.railway.internal`                  | `config.yml` & `rules.json` — permission check URL |
| `UI_INTERNAL`      | `iam-app.railway.internal`               | `rules.json` — upstream proxy target host |
| `UI_PORT`          | `8080`                                   | `rules.json` — upstream proxy target port |
| `PUBLIC_URL`       | `https://gateway-production-6cac.up.railway.app` | `config.yml` & `rules.json` — login redirect base URL, id_token issuer |

## Container Startup

The image uses a two-phase startup to avoid baking secrets into the image:

```
Docker image build
  config.yml   → stored as /config.yml.template
  rules.json   → stored as /rules.json.template
  jwks.json    → stored as /jwks.json  (static, no env vars)
  entrypoint.sh

Container start (entrypoint.sh)
  1. Assert all required env vars are present (fails fast if any are missing)
  2. envsubst renders /config.yml.template → /config.yml
  3. envsubst renders /rules.json.template → /rules.json
  4. exec oathkeeper serve --config /config.yml
```

## Configuration (`config.yml`)

### Serve

| Port | Purpose |
|------|---------|
| 4455 | Proxy — receives requests from nginx, applies rules, proxies to upstream |
| 4456 | API — management endpoint (rules CRUD, health) |

### Authenticators

| Handler | Enabled | What it does |
|---|---|---|
| `anonymous` | yes | Passes the request through with subject `guest`. Used on public routes only. |
| `cookie_session` | yes | Calls Kratos `/sessions/whoami` to validate the `ory_kratos_session` cookie. Extracts `identity.id` as the subject. |
| `jwt` | yes | Validates Hydra-issued JWT bearer tokens locally using the JWKS endpoint (`/well-known/jwks.json`). No round-trip to Hydra. Trade-off: revoked tokens remain valid until `exp`. |
| `oauth2_introspection` | yes (available) | Calls Hydra admin `/admin/oauth2/introspect` to verify token active status and catch revocation. Not used in default rules — enable per-rule when revocation checking is required. |

> The `jwt` authenticator is preferred for API-to-API calls due to lower latency. `cookie_session` is preferred for browser sessions.

### Authorizers

| Handler | Enabled | What it does |
|---|---|---|
| `allow` | yes | Permits the request unconditionally (used on public routes or after the authenticator has already established trust). |
| `deny` | yes | Rejects the request unconditionally. |
| `remote_json` | yes | POSTs a Go-template-rendered JSON payload to a remote URL. Allows on 2xx, denies on non-2xx. Used for Keto permission checks. |

**Why `remote_json` instead of `keto_engine_acp_ory`:**
`keto_engine_acp_ory` targets Keto's legacy ACL engine (pre-Zanzibar). This platform uses Keto v0.11+ with the Zanzibar relation-tuple model. There is no dedicated native authorizer for that model in Oathkeeper v25.4.0, so `remote_json` against Keto's `/relation-tuples/check` endpoint is the documented approach.

**Schema requirement:** When `remote_json.enabled: true`, the global config must include `remote` and `payload` (required by Oathkeeper's JSON Schema `oneOf`). The global values act as defaults; per-rule `config` blocks override them.

### Mutators

| Handler | Enabled | What it does |
|---|---|---|
| `noop` | yes | Forwards the request unchanged. |
| `header` | yes | Injects `X-User-Id: <subject>` so upstream services know who is authenticated without re-validating the session. |
| `id_token` | yes | Mints a signed JWT (`id_token`) for service-to-service auth. Uses the JWKS at `/jwks.json` (the static key baked into the image). |

### Error Handlers

| Handler | Behaviour |
|---|---|
| `json` | Returns a structured JSON error (default fallback). |
| `redirect` | Redirects browser requests (`Accept: text/html`) with `unauthorized` or `forbidden` errors to `${PUBLIC_URL}/auth/login`. |

## Access Rules (`rules.json`)

Rules are evaluated in order. The first matching rule wins.

### Rule priority

```
1. api-auth-public    /api/auth/*       anonymous
2. api-admin-protected /api/admin/*     authenticated + Keto admin check
3. api-oauth2-public  /api/oauth2/*     anonymous
4. api-protected      /api/*            authenticated
```

### Rule details

#### `api-auth-public`

```
Match:          GET POST OPTIONS  /api/auth/*
Authenticator:  anonymous
Authorizer:     allow
Mutator:        noop
```

Handles Kratos registration webhooks and third-party OAuth callbacks. Methods are intentionally narrow — PUT/PATCH/DELETE are never legitimate on public auth endpoints.

#### `api-admin-protected`

```
Match:          GET POST PUT PATCH DELETE OPTIONS  /api/admin/*
Authenticator:  cookie_session → jwt  (first success wins)
Authorizer:     remote_json → POST http://${KETO_INTERNAL}:4466/relation-tuples/check
                  payload: { namespace: "GlobalRole", object: "admin",
                             relation: "members", subject_id: "{{ .Subject }}" }
Mutator:        header  (X-User-Id: {{ .Subject }})
Errors:         browser → redirect to /auth/login
                API     → JSON 401/403
```

A request must both authenticate (valid Kratos session **or** valid Hydra JWT) **and** pass the Keto permission check (the identity must be a member of `GlobalRole:admin`). Keto returns `200` if the tuple exists (allowed) and `403` if not (denied).

#### `api-oauth2-public`

```
Match:          GET POST OPTIONS  /api/oauth2/*
Authenticator:  anonymous
Authorizer:     allow
Mutator:        noop
```

Handles Hydra's login/consent/logout redirect targets (`/api/oauth2/login`, `/api/oauth2/consent`, `/api/oauth2/logout`). These endpoints **must** be public because they are part of the authentication flow itself — Hydra redirects here before the user has a Kratos session. The route handlers themselves call Hydra's admin API to accept or reject the challenge, and redirect to Kratos login if no session is present.

> This rule must appear before `api-protected` so that `/api/oauth2/*` is not caught by the authenticated catch-all.

#### `api-protected`

```
Match:          GET POST PUT PATCH DELETE OPTIONS  /api/*
Authenticator:  cookie_session → jwt  (first success wins)
Authorizer:     allow
Mutator:        header  (X-User-Id: {{ .Subject }})
Errors:         browser → redirect to /auth/login
                API     → JSON 401/403
```

The catch-all for all other application API routes. Requires a valid Kratos session or Hydra JWT. The authenticated subject is forwarded upstream as `X-User-Id`.

## JWKS (`jwks.json`)

A static RSA key pair used by the `id_token` mutator to sign service-to-service JWTs. This file is copied directly into the image (not a template). The public key is served at Oathkeeper's `/.well-known/jwks.json` endpoint for downstream verification.

> Rotate this key by replacing `jwks.json` and rebuilding the image. Any service verifying `id_token` JWTs must update its trusted JWKS URL accordingly.

## Common Issues

### `remote_json` config validation failure at startup

**Error:** `oneOf failed … missing properties: "remote", "payload"`

Oathkeeper's schema requires the global `remote_json.config` to have `remote` and `payload` even if every rule overrides them. Ensure `config.yml` includes a valid global config block under `authorizers.remote_json.config`.

### `/api/oauth2/*` returns 404 or redirect loop

**Cause:** A rule requiring authentication (e.g. `api-protected`) matched before `api-oauth2-public`. Oathkeeper denied the unauthenticated Hydra redirect, sent the browser to `/auth/login`, which rendered with no `flow` or `return_to`, triggering another OAuth2 redirect — creating a loop.

**Fix:** Ensure `api-oauth2-public` appears in `rules.json` before `api-protected`.

### Oathkeeper 500 on `/api/oauth2/login` — ambiguous rule match

**Symptoms:**

```
service_name: ORY Oathkeeper
error.status_code: 500
error.message: An internal server error occurred, please contact the system administrator
http_request.path: /api/oauth2/login
```

**Cause:** Oathkeeper returns a hard 500 when a request matches more than one access rule simultaneously. `/api/oauth2/login` matched **two rules** at once:

- `api-oauth2-public` — pattern `/api/oauth2/<.*>`
- `api-protected` — pattern `/api/<.*>` (the `<.*>` wildcard matches `oauth2/login`)

The same ambiguity exists for `/api/auth/*` (vs `api-auth-public`) and `/api/admin/*` (vs `api-admin-protected`).

**Fix:** Add a negative lookahead to the `api-protected` catch-all URL pattern so it does not match paths already claimed by a more-specific rule:

```json
// before
"url": "<http|https>://<[^/]+>/api/<.*>"

// after
"url": "<http|https>://<[^/]+>/api/<(?!auth|admin|oauth2).*>"
```

The regex `(?!auth|admin|oauth2)` prevents the catch-all from matching any path under `/api/auth/`, `/api/admin/`, or `/api/oauth2/`, eliminating the ambiguity.

**File:** `oathkeeper/rules.json` — `api-protected` rule → `match.url`

---

### Kratos 400 `self_service_flow_return_to_forbidden` — `http://` in `return_to`

**Symptoms:**

```json
{
  "error": {
    "id": "self_service_flow_return_to_forbidden",
    "code": 400,
    "reason": "Requested return_to URL \"http://gateway-production-6cac.up.railway.app/api/oauth2/login?login_challenge=...\" is not allowed."
  }
}
```

**Cause:** Kratos's `selfservice.allowed_return_urls` only allows `https://...` URLs. The `return_to` URL was being generated with `http://` instead.

The route handler in `iam-app/app/api/oauth2/login/route.ts` constructed the base URL by reading the `x-forwarded-proto` request header:

```text
Browser → nginx (sets X-Forwarded-Proto: https) → Oathkeeper → iam-app
```

nginx correctly sets `X-Forwarded-Proto: https` when forwarding to Oathkeeper. However, Oathkeeper proxies to iam-app over a plain HTTP connection internally and does **not** re-inject `X-Forwarded-Proto: https` into the upstream request. The Next.js route handler therefore saw `x-forwarded-proto: http` (or nothing, falling back to `request.nextUrl.protocol` = `http:`), and constructed `return_to=http://...`.

**Fix:** Replace the header-reconstruction logic with the `NEXT_PUBLIC_APP_URL` environment variable, which is explicitly set to the correct public HTTPS URL in production and is not affected by the internal HTTP proxy chain:

```typescript
// before — unreliable when Oathkeeper strips X-Forwarded-Proto
const forwardedProto = request.headers.get("x-forwarded-proto") || request.nextUrl.protocol.replace(":", "");
const baseUrl = `${forwardedProto}://${forwardedHost}`;
const returnToUrl = `${baseUrl}/api/oauth2/login?login_challenge=${login_challenge}`;

// after — always uses the configured public HTTPS URL
const appUrl = (process.env.NEXT_PUBLIC_APP_URL || "").replace(/\/$/, "");
const returnToUrl = `${appUrl}/api/oauth2/login?login_challenge=${login_challenge}`;
```

**Files changed:**

- `iam-app/app/api/oauth2/login/route.ts` — base URL construction and Kratos redirect

**Prerequisite:** `NEXT_PUBLIC_APP_URL` must be set to the full public HTTPS URL (e.g. `https://gateway-production-6cac.up.railway.app`) in the iam-app Railway service environment variables. See `.env.example` for the full variable list.

---

### nginx `connect() failed (111: Connection refused)` for `/auth/*`

**Cause:** nginx's `/auth/` location proxies directly to iam-app. During Railway cold starts, nginx may receive browser RSC prefetch requests before iam-app is fully ready. This is transient and resolves once iam-app is healthy.
