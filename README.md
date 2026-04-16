# passkey-proxy

**Self-hosted reverse proxy with passkey authentication — a lightweight Authelia / Authentik / Cloudflare Access alternative you can run in one command.**

Put any local HTTP service behind passkey authentication with automatic HTTPS — no app code changes, no password management, no SaaS.

```
Internet → Caddy (:443, auto TLS)
              ├─ auth.app.example.com → Pocket ID (OIDC + passkeys)
              └─ app.example.com  → oauth2-proxy (forward_auth) → your service
```

## Why passkey-proxy?

- **One command** — `docker compose up` and your service is on the public internet behind auth.
- **Passkey-first** — no passwords to manage, rotate, or leak. Pocket ID handles WebAuthn.
- **Free automatic TLS** — Caddy provisions and renews Let's Encrypt certificates for you.
- **Works with any HTTP service** — point it at a port on the host, done. No SDK, no middleware, no code changes.

## Prerequisites

- Ports 80 and 443 open on your host
- A domain with two DNS A records pointing to your server (e.g. `app.example.com`, `auth.app.example.com`)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/valentinpx/passkey-proxy/main/setup.sh -o setup.sh && sh setup.sh
```

The script will:
1. Clone the repo (if needed) and check prerequisites
2. Ask for your domain, upstream port, and email
3. Generate secrets and write `.env`
4. Start Caddy + Pocket ID
5. Walk you through creating an OIDC client in Pocket ID
6. Start all services

After setup, visit `https://your-app-domain` — you'll be redirected through passkey auth.

## Manual setup

If you prefer to configure things yourself:

### 1. Clone and configure

```bash
git clone https://github.com/valentinpx/passkey-proxy.git
cd passkey-proxy
cp .env.example .env
```

Edit `.env` — set your domains, email, upstream port, and generate secrets:

```bash
openssl rand -base64 32  # use for COOKIE_SECRET
openssl rand -base64 32  # use for POCKET_ID_ENCRYPTION_KEY
```

### 2. Start Caddy + Pocket ID

```bash
docker compose up -d caddy pocket-id
```

### 3. Set up Pocket ID

1. Visit `https://auth.your-domain.com/setup`
2. Create your admin account and register a passkey
3. Go to **OIDC Clients** → **New Client**
   - **Callback URL**: `https://app.your-domain.com/oauth2/callback`
   - After saving, either toggle **Restricted** off, or create a group, add your user, and assign it under **Allowed user groups** — otherwise login fails with *"You're not allowed to access this service."*
4. Copy the **Client ID** and **Client Secret** into `.env`

### 4. Start everything

```bash
docker compose up -d
```

Visit `https://app.your-domain.com` — you should be redirected to Pocket ID for passkey login.

## Configuration reference

| Variable | Description | Example |
|----------|-------------|---------|
| `APP_DOMAIN` | Domain for your protected service | `app.example.com` |
| `AUTH_DOMAIN` | Domain for Pocket ID | `auth.example.com` |
| `BASE_DOMAIN` | Parent domain (cookie sharing) | `example.com` |
| `ACME_EMAIL` | Let's Encrypt notification email | `you@example.com` |
| `UPSTREAM_PORT` | Host port of the service to protect | `3456` |
| `OIDC_CLIENT_ID` | From Pocket ID OIDC client setup | — |
| `OIDC_CLIENT_SECRET` | From Pocket ID OIDC client setup | — |
| `COOKIE_SECRET` | oauth2-proxy session encryption | Auto-generated |
| `POCKET_ID_ENCRYPTION_KEY` | Pocket ID data encryption | Auto-generated |

## Alternatives

passkey-proxy is intentionally the smallest possible stack that gives you passkey login in front of an arbitrary HTTP service. You can self-host it in one command TLS included. If you need ACLs, group policies, LDAP, or user federation, you can pick Authelia or Authentik.

## Troubleshooting

**"You're not allowed to access this service." on the auth page**
Pocket ID OIDC clients are **Restricted** by default. Open the client in the Pocket ID admin and either toggle **Restricted** off, or assign your user's group under **Allowed user groups**.

**oauth2-proxy keeps restarting**
Expected before OIDC setup is complete. Run `setup.sh` or follow the manual steps above.

**Certificate errors**
Ensure ports 80/443 are open and DNS records point to your server. Caddy uses the HTTP-01 challenge.

**"502 Bad Gateway" after login**
Your upstream service isn't running or isn't on the configured port. Check `UPSTREAM_PORT` matches your service.

**Can't reach host service from Docker**
On Linux, requires Docker 20.10+. The `host.docker.internal` alias is set via `extra_hosts` in the compose file.

## License

This project is released by [Valentin Sene](https://valentinsene.me) under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/) — public domain. No attribution required.