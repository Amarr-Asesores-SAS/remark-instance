# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-only backend for a self-hosted [Remark42](https://remark42.com) comments
instance serving **estrellaswebcam.com**. Runs on a Hetzner VPS behind the host nginx.
No build, no test suite, no linter — the repo is a `compose.yaml`, an `.env` template,
one nginx vhost, and one static moderation panel (`admin/index.html`, vanilla JS, no
build). The frontend (Astro rewrite + widget) lives in a separate repo (the website repo).

`README.md` is the authoritative runbook (written in Spanish) and covers full VPS
deployment, backups, and moderation. Read it before making infra changes.

## Request flow

```
browser ─► estrellaswebcam.com (Astro)
             │  server-side rewrite  /comments/*  ─►  https://comments.ewcam.co/*
             ▼
        VPS host nginx  (server_name comments.ewcam.co, TLS via certbot)
             │  proxy_pass  http://127.0.0.1:9081
             ▼
        container  ewcam-remark42   (SSL_TYPE=none, plain HTTP)
             └─ volume ./var  (BoltDB + avatars + images + daily backups)
```

The browser only ever talks to `estrellaswebcam.com`, so Remark42 cookies are
first-party. `comments.ewcam.co` is public + TLS only because the Astro rewrite
consumes it server-side; the client never calls it directly.

## Common commands

Run from the repo dir on the VPS:

```bash
docker compose up -d                 # start / apply changes
docker compose logs -f remark42      # follow logs
docker compose pull && docker compose up -d   # upgrade after bumping the image tag in compose.yaml

# local smoke test (no nginx/TLS) — expect JSON with "auth_providers":["anonymous"]
curl -s "http://127.0.0.1:9081/api/v1/config?site=ewcam" | head -c 200
# public smoke test
curl -s "https://comments.ewcam.co/api/v1/config?site=ewcam" | head -c 200
```

Moderation runs over the API with HTTP basic auth (`admin` + `ADMIN_PASSWD`); see
the "Moderacion" section of `README.md` for the delete / pin / readonly /
block-user calls. There is also a static web panel at `comments.ewcam.co/admin/`
(`admin/index.html`) — nginx `auth_basic` gates both `/admin/` and
`^~ /api/v1/admin/` against `/etc/nginx/remark-admin.htpasswd`, which must hold
`admin:<ADMIN_PASSWD>` so nginx can forward the same credential to Remark42. See
the "Panel de moderación" section of `README.md`.

## Configuration notes that bite

- **`.env` and `var/` are gitignored and never committed.** `.env` holds `SECRET`
  (JWT signing key, `openssl rand -hex 32`) and `ADMIN_PASSWD`. `.env.example` is the
  template — keep it in sync when adding a var.
- **`REMARK_URL` is the only value coupled to the frontend.** It must be the frontend
  domain + subpath (`https://estrellaswebcam.com/comments`), *not* `comments.ewcam.co`.
  Change it here and `docker compose up -d` if the frontend domain or rewrite prefix
  changes.
- **`TRUSTED_PROXY`** (default `172.16.0.0/12`, the docker bridge) must match the real
  subnet from `docker network inspect ewcam-remark_default`. Wrong value makes
  rate-limiting and `VOTES_IP` ("1 vote per IP") apply to the docker gateway IP instead
  of the user's.
- **Auth is anonymous-only** — no OAuth, no login screen. `POST /api/v1/comment`
  requires `?site=ewcam` in the query and an `X-XSRF-TOKEN` header equal to the JWT
  `jti` claim; the frontend widget handles this.
- **Reply nesting depth is not enforced by the backend.** The "1 level" limit is a
  frontend decision (flattening the `format=tree` response).
- The container binds `127.0.0.1:9081:8080` — loopback only. Public exposure and TLS
  are entirely the host nginx's job (`deploy/comments.ewcam.co.nginx.conf`), which
  certbot edits in place to add the `listen 443 ssl` block.

## Commits

Follow the global convention: `<emoji> <type>: <description>`, imperative, under 72
chars (e.g. `✨ feat:`, `🐛 fix:`, `📝 docs:`, `🔧 chore:`). No signatures. Recent
history uses this format.
