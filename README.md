# passkey-proxy

**Self-hosted reverse proxy with passkey authentication — a lightweight Authelia / Authentik / Cloudflare Access alternative you can run in one command.**

Put any number of local HTTP services behind passkey authentication with automatic HTTPS — no app code changes, no password management, no SaaS. One sign-in unlocks every protected app (SSO).

```
Internet → Caddy (:443, auto TLS)
              ├─ auth.example.com       → Pocket ID (OIDC + passkeys)
              │                           + oauth2-proxy (/oauth2/*)
              ├─ app.example.com        → oauth2-proxy (forward_auth) → your service
              └─ dashboard.example.com  → oauth2-proxy (forward_auth) → another service
```

## Why passkey-proxy?

- **One command** — `docker compose up` and your services are on the public internet behind auth.
- **Passkey-first** — no passwords to manage, rotate, or leak. Pocket ID handles WebAuthn.
- **Free automatic TLS** — Caddy provisions and renews Let's Encrypt certificates for you.
- **Works with any HTTP service** — point it at a port on the host, done. No SDK, no middleware, no code changes.
- **Multi-app SSO** — protect as many apps as you want behind a single login.

## Prerequisites

- Ports 80 and 443 open on your host
- A DNS A record pointing to your server for **each protected app** and for the auth domain (e.g. `example.com`, `*.example.com`)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/valentinpx/passkey-proxy/main/setup.sh -o setup.sh && sh setup.sh
```

The script will:
1. Clone the repo (if needed) and check prerequisites
2. Ask for one or more `(domain, upstream port)` pairs, plus the auth domain and email
3. Generate secrets, write `.env`, and regenerate `Caddyfile` with a block per app
4. Start Caddy + Pocket ID
5. Walk you through creating an OIDC client in Pocket ID
6. Start all services

After setup, visit any of your app domains — you'll be redirected through passkey auth on the shared auth domain, and signing in once grants access to all of them.

## Manual setup

If you prefer to configure things yourself:

### 1. Clone and configure

```bash
git clone https://github.com/valentinpx/passkey-proxy.git
cd passkey-proxy
cp .env.example .env
```

Edit `.env` — set `AUTH_DOMAIN`, `BASE_DOMAIN`, `ACME_EMAIL`, and generate secrets:

```bash
openssl rand -base64 32  # use for COOKIE_SECRET
openssl rand -base64 32  # use for POCKET_ID_ENCRYPTION_KEY
```

Edit `Caddyfile` — one block per app you want to protect:

```caddy
app.example.com {
    import protected 3456
}
dashboard.example.com {
    import protected 3000
}
```

The second argument to `import protected` is the port on the host where that upstream service listens.

### 2. Start Caddy + Pocket ID

```bash
docker compose up -d caddy pocket-id
```

### 3. Set up Pocket ID

1. Visit `https://auth.your-domain.com/setup`
2. Create your admin account and register a passkey
3. Go to **OIDC Clients** → **New Client**
   - **Callback URL**: `https://auth.your-domain.com/oauth2/callback` (one URL serves every app)
   - After saving, either toggle **Restricted** off, or create a group, add your user, and assign it under **Allowed user groups** — otherwise login fails with *"You're not allowed to access this service."*
4. Copy the **Client ID** and **Client Secret** into `.env`

### 4. Start everything

```bash
docker compose up -d
```

Visit any protected app domain — you should be redirected to Pocket ID for passkey login, and once signed in you can reach every other protected app without re-auth.

## Adding another app

Either:

- Re-run `setup.sh` and answer `y` to "Overwrite and reconfigure?" — the existing secrets will be regenerated, so remember to update the OIDC client if you change domains, or
- Append a block to `Caddyfile` and restart Caddy:
  ```caddy
  newapp.example.com {
      import protected 8080
  }
  ```
  ```bash
  docker compose restart caddy
  ```

No `.env` or OIDC changes are needed — the callback lives on the auth domain and cookies are scoped to `BASE_DOMAIN`.

## Configuration reference

| Variable | Description | Example |
|----------|-------------|---------|
| `AUTH_DOMAIN` | Domain for Pocket ID and the shared sign-in page | `auth.example.com` |
| `BASE_DOMAIN` | Parent domain (cookie sharing — must cover every app + auth) | `example.com` |
| `ACME_EMAIL` | Let's Encrypt notification email | `you@example.com` |
| `OIDC_CLIENT_ID` | From Pocket ID OIDC client setup | — |
| `OIDC_CLIENT_SECRET` | From Pocket ID OIDC client setup | — |
| `COOKIE_SECRET` | oauth2-proxy session encryption | Auto-generated |
| `POCKET_ID_ENCRYPTION_KEY` | Pocket ID data encryption | Auto-generated |

Protected apps themselves are declared in `Caddyfile`, not `.env` — one `domain { import protected <PORT> }` block per app.

## SSO scope

Any Pocket ID user who has access to the OIDC client reaches every protected app. That's the whole point of the shared login. If you need **per-app** authorization, run a separate oauth2-proxy + OIDC client for that app — the single-oauth2-proxy setup here is intentionally the simplest shape.

## Alternatives

passkey-proxy is intentionally the smallest possible stack that gives you passkey login in front of arbitrary HTTP services. You can self-host it in one command, TLS included. If you need ACLs, group policies, LDAP, or user federation, pick Authelia or Authentik.

## Troubleshooting

**"You're not allowed to access this service." on the auth page**
Pocket ID OIDC clients are **Restricted** by default. Open the client in the Pocket ID admin and either toggle **Restricted** off, or assign your user's group under **Allowed user groups**.

**oauth2-proxy keeps restarting**
Expected before OIDC setup is complete. Run `setup.sh` or follow the manual steps above.

**Certificate errors**
Ensure ports 80/443 are open and DNS records point to your server for every app + auth domain. Caddy uses the HTTP-01 challenge.

**"502 Bad Gateway" after login**
The upstream service isn't running or isn't on the port declared in `Caddyfile`. Check the `import protected <PORT>` line for that app.

**Can't reach host service from Docker**
On Linux, requires Docker 20.10+. The `host.docker.internal` alias is set via `extra_hosts` in the compose file.

**Migrating from a single-app install**
In Pocket ID, change the OIDC client's callback URL from `https://<app>/oauth2/callback` to `https://<auth>/oauth2/callback`, then re-run `setup.sh` (accept overwrite) to regenerate `Caddyfile` and `.env`.

## Uninstall

Everything this project creates — containers, images, TLS certs, Pocket ID database, generated `.env` and `Caddyfile` — lives under the project folder or inside Docker; nothing is written elsewhere on the host.

```bash
docker compose down -v --rmi all
rm -rf ../passkey-proxy
```

Deleting `./data/pocket-id` destroys your passkey credentials — back it up if you plan to reinstall.

Docker and the `git` / `curl` / `openssl` packages installed by `setup.sh` are left on the host (you almost certainly want to keep them).

## License

This project is released by [Valentin Sene](https://valentinsene.me) under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/) — public domain. No attribution required.
