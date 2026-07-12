---
sidebar_position: 3
title: appctl
---

# appctl — Deployment Guide

A step-by-step guide to deploying many Docker projects behind a single
host-installed nginx, with HTTPS terminated per-domain by **certbot / Let's
Encrypt** (or one shared origin cert) — and without ever tracking ports by hand.

---

## What this solves

You run nginx **directly on the host** (not in a container) and proxy to apps
that run in Docker. Each app publishes a port on the host's loopback interface,
and nginx forwards traffic to it. This works great for a few projects — but at
10, 50, or 100 projects, three things become painful:

1. **Picking a free port every time** ("is 3001 taken? what about 3002?").
2. **Repeating the same boilerplate** — a compose edit, an nginx server block
   (now with HTTP **and** HTTPS), a symlink, a cert, and a reload — for every
   project.
3. **Keeping the TLS config identical** across every block.

`appctl` removes all three. A registry file is the **single source of truth**
for which port belongs to which project. One command allocates the next free
port, writes and validates the nginx config (HTTP + HTTPS), obtains a TLS cert,
enables it with a `sites-enabled` symlink, reloads, and prints the exact
`docker-compose` line to paste in. Project 101 is the same one command as
project 1.

---

## How it works (the model)

```
                    ┌──────────────────────────────────────────┐
   Internet ───────▶│            nginx (on the host)           │
   (DNS A record    │  reads /etc/nginx/sites-enabled/*        │
    per app ->      │  TLS terminated per-domain by certbot    │
    this server)    │  (Let's Encrypt), or one shared cert     │
                    └──────┬────────────┬────────────┬─────────┘
                           │            │            │  proxy_pass
            proxy_pass     │            │            │  127.0.0.1:10002
         127.0.0.1:10000   │            │            │
                           ▼            ▼            ▼
                    ┌───────────┐ ┌───────────┐ ┌───────────┐
                    │ container │ │ container │ │ container │
                    │   blog    │ │   api     │ │    app    │
                    │  :3000    │ │  :8080    │ │  :3000    │
                    └───────────┘ └───────────┘ └───────────┘
                      published     published     published
                    127.0.0.1:     127.0.0.1:    127.0.0.1:
                      10000          10001         10002
```

Key properties:

- **One nginx, many projects.** Each project is independent — separate compose
  file, separate folder, separate lifecycle. The host is the only shared point.
- **TLS per domain by default.** `appctl` obtains a Let's Encrypt certificate
  for each domain via certbot on `add`. If you'd rather use **one shared origin
  cert** for every project (e.g. a Cloudflare Origin cert), set
  `TLS_MODE=shared` — the choice is recorded per project.
- **Loopback-only publishing.** Containers publish to `127.0.0.1:<port>`, so
  nginx can reach them but the public internet **cannot** bypass nginx by
  hitting `your-server-ip:10000` directly.
- **The registry is the source of truth.** "Which port is free?" is answered by
  a file (`/etc/nginx-deploy/registry.tsv`), not by you. Ports are allocated
  from **named tiers** — by default frontends from `10000–10999` and backends
  from `11000–11999` — so an app's class is visible from its port (see
  [Port tiers](#port-tiers-allocating-by-app-class)).
- **Debian-native file layout.** The real server-block file is written to
  `sites-available/`, then symlinked into `sites-enabled/` — exactly like every
  hand-written block on the server. `remove` tears down both.
- **Host ports must be unique; container ports need not be.** Two projects can
  both listen on `:3000` internally — they just get mapped to different host
  ports. `appctl` handles that collision automatically.

---

## Why publish on `127.0.0.1` (not `0.0.0.0`)?

Every mapping `appctl` prints binds the host side to loopback —
`"127.0.0.1:<host_port>:<container_port>"` — and it is deliberate. It is the
security best practice for this "host nginx fronts Docker" architecture, for two
reasons:

1. **nginx is the only front door.** The app is reachable *only* from the host
   itself, so the public internet cannot skip nginx (TLS, headers, timeouts,
   rate limits) by hitting `your-server-ip:<host_port>` directly. With
   `0.0.0.0` — which is what a bare `-p 10000:8080` gives you — the raw app port
   is open to the world.

2. **Docker bypasses your firewall.** This is the part people miss. Docker
   inserts its own `iptables` rules (in `PREROUTING`/`FORWARD`) that are
   evaluated *before* UFW/firewalld. A port published on `0.0.0.0` is therefore
   reachable from the internet **even if you ran `ufw deny 10000`** — the deny
   rule never sees the packet. Binding to `127.0.0.1` sidesteps this entirely:
   the socket simply isn't listening on any public interface, firewall or not.

So loopback isn't just "tidier" here — it's the difference between "nginx is the
only way in" and "every app port is silently internet-facing." Keep the
`127.0.0.1:` prefix on the mapping.

> **When would `0.0.0.0` be right?** Only when a service must be reached
> **directly from another machine** with no same-host proxy in front (e.g. a
> database a remote app connects to) — and even then you should protect it with
> Docker's `DOCKER-USER` iptables chain (or a tool like
> [`ufw-docker`](https://github.com/chaifeng/ufw-docker)), not plain UFW. For
> app-to-app traffic on the same host, use a shared Docker network and don't
> publish a host port at all. None of those apply to apps fronted by this host's
> nginx — hence loopback.
>
> Note this works because nginx runs **on the host**. If nginx were itself in a
> container, `127.0.0.1` on the host publish wouldn't be reachable from it and
> you'd use a Docker network instead.

---

## Prerequisites

- nginx installed on the host (e.g. `sudo apt install nginx`), using the
  standard `sites-available` / `sites-enabled` layout.
- Docker + Docker Compose installed.
- **certbot** installed for the default TLS mode:
  `sudo apt install certbot python3-certbot-nginx`.
- For certbot to issue a cert, each app's **DNS `A`/`AAAA` record must point at
  this server** and **port 80 must be reachable from the internet** (the ACME
  `http-01` challenge is served over the HTTP block appctl writes first).
- `ss` available (part of `iproute2`, present on virtually all Linux). Used to
  double-check that an allocated port isn't already bound.
- `sudo`/root access, because the script writes into `/etc/nginx`.
- _(Optional, only for `TLS_MODE=shared`)_ a **shared origin certificate**
  installed on the host (see
  [TLS with a shared origin cert](#tls-with-a-shared-origin-cert-option)).

---

## Installation

Copy the script (`appctl` in this repo) onto your `PATH` and make it
executable:

```bash
sudo cp appctl /usr/local/bin/appctl
sudo chmod +x /usr/local/bin/appctl
```

Verify it's installed:

```bash
appctl --help
```

The first time you run an `add` (or `list`/`next`), `appctl` **bootstraps
itself** — it creates the registry, a shared proxy-headers snippet, a
WebSocket-upgrade snippet, and a WebSocket map (symlinked into `sites-enabled`).
You don't set anything up manually.

---

## Naming: the file is named exactly like the domain

`appctl` names the server-block file after the domain — with **no `.conf`
extension** — to match the convention used by every other block on this server
(`sites-available/<domain>`). Pass just the domain — the container port is
optional and defaults to `8080`:

```bash
sudo appctl add blog.mutaqorrobin.online          # container port defaults to 8080
sudo appctl add blog.mutaqorrobin.online 3000     # or pass your app's port explicitly
```

This writes `/etc/nginx/sites-available/blog.mutaqorrobin.online` and symlinks it
into `sites-enabled/`.

If you ever want the **file/key to differ from the `server_name`** (a short
internal handle), use the form `add <project> <domain> [container_port]`. With
one argument the domain simply doubles as the project name — which is what makes
appctl files sit naturally beside your hand-written ones.

> **Why is the container port optional?** nginx proxies to the _host_ port
> appctl allocates, never to the container port — so appctl doesn't strictly
> need it. It's recorded purely to fill the printed docker-compose mapping. The
> default `8080` suits apps you can point at any port (e.g. via a `PORT` env
> var); pass an explicit port when your app listens on a fixed one. **Whatever
> appctl prints, your app must actually listen on that container port** — a
> mismatch is the usual cause of a 502. Override the default fleet-wide with
> `DEFAULT_CONTAINER_PORT`.

> **How to tell appctl-managed files apart from hand-written ones.** Since
> nothing in the filename distinguishes them anymore, the markers are: every
> appctl file starts with a `# Managed by appctl` header, and `appctl list`
> shows exactly what it owns. **Never hand-edit a file whose first line says
> "Managed by appctl"** — the next `add` regenerates it from template and your
> edit is lost.

---

## Quick start (deploy a project in 3 steps)

```bash
# 1. Allocate a port + generate the HTTP/HTTPS nginx config + obtain a cert.
sudo appctl add blog.mutaqorrobin.online
```

`appctl` prints something like (container port `8080` here — the default):

```
# ---- docker-compose port mapping for 'blog.mutaqorrobin.online' --------------
# Bind to loopback (127.0.0.1) ONLY: reachable by nginx, NOT the public net.
# Do not change it to 0.0.0.0 — Docker's iptables rules bypass ufw/firewalld, so
# a 0.0.0.0 publish is internet-exposed even behind a firewall "deny" rule.
# (container port 8080 — make sure your app actually listens on it):
    ports:
      - "127.0.0.1:10000:8080"
# ------------------------------------------------------------------------------
```

```yaml
# 2. Paste that ports: mapping into the project's docker-compose.yml. The right
#    side must be the port your app listens on — keep 8080 if your app uses it,
#    or re-run `appctl add blog.mutaqorrobin.online <port>` to record a different one:
services:
  app:
    image: blog:latest
    ports:
      - "127.0.0.1:10000:8080" # host port from appctl : your app's container port
```

```bash
# 3. Start the container.
docker compose up -d
```

Visit `https://blog.mutaqorrobin.online` and it works. That's the entire loop.

---

## Step-by-step: your first project (detailed)

### Step 1 — Run `appctl add`

```bash
sudo appctl add blog.mutaqorrobin.online          # or: appctl add blog.mutaqorrobin.online 3000
```

| Argument                   | Meaning                                                                       | Example                    |
| -------------------------- | ----------------------------------------------------------------------------- | -------------------------- |
| `blog.mutaqorrobin.online` | The domain — also the file written to `sites-available` and the `server_name` | `blog.mutaqorrobin.online` |
| `3000` _(optional)_        | Container port for the compose mapping; defaults to `8080`                    | `3000`                     |

Domain/project names allow lowercase letters, digits, `.` `_` and `-`, and must
start with a letter or digit. (Use `add <project> <domain> [container_port]`
only when you want the filename to differ from the `server_name`.)

Behind the scenes, `appctl` (in the default `certbot` mode):

1. Finds the next free port in the chosen tier's band (default `frontend`,
   10000–10999; skipping anything already in the registry or bound on the host).
2. Records `blog.mutaqorrobin.online → 10000` in the registry.
3. Writes an **HTTP-only** block first, enables it, validates, and reloads — so
   certbot's `http-01` challenge can be served on port 80.
4. Runs certbot (`certonly --nginx`) to obtain a Let's Encrypt cert for the
   domain.
5. **Rewrites** the block with the `:443` HTTPS listener pointing at the new
   cert, validates again, and reloads.
6. Prints the `docker-compose` `ports:` mapping.

> **If certbot can't obtain a cert** (DNS not pointed yet, port 80 unreachable),
> `appctl` leaves the **working HTTP route** in place and tells you to re-run
> once DNS/port 80 are ready. Your other projects are never touched.

> **If `nginx -t` fails, everything rolls back** — the symlink, the
> `sites-available` file, and the registry entry are removed and the running
> nginx is left untouched. A broken config can never take down your other
> projects.

### Step 2 — Add the mapping to your compose file

Copy the printed `ports:` line into the project's `docker-compose.yml` under its
service. **Make sure the container port (right side) is the port your app
actually listens on** — keep the default `8080`, or re-run `add` with an explicit
port to record the right one. The format is always
`"127.0.0.1:<host_port>:<container_port>"`: the **host port** (left) is the
unique one `appctl` allocated; the **container port** (right) is whatever your
app listens on inside the container.

### Step 3 — Bring the container up

```bash
docker compose up -d
```

### Step 4 — Verify

```bash
# Confirm the container is published on the expected loopback port:
docker ps --format '{{.Names}}\t{{.Ports}}'

# Confirm nginx is happy and the block is enabled:
sudo nginx -t
ls -l /etc/nginx/sites-enabled/blog.mutaqorrobin.online   # should be a symlink

# Hit it through https:
curl -H "Host: blog.mutaqorrobin.online" https://blog.mutaqorrobin.online
```

---

## Command reference

### `add <domain> [container_port]` &nbsp;·&nbsp; `add <project> <domain> [container_port]`

Allocate a host port, write the server block into `sites-available`, obtain TLS
(per `TLS_MODE`), enable it via a `sites-enabled` symlink, reload, and print the
compose mapping. The container port is optional (defaults to `8080`, or
`DEFAULT_CONTAINER_PORT`); the domain doubles as the project name unless a
separate one is given.

For a new project, `add` **prompts for the port tier** (default pre-filled);
set `TIER=<name>` to skip the prompt. Set `TLS_MODE=shared` to use the shared
origin cert, or `TLS_MODE=none` (or `ENABLE_SSL=0`) for an HTTP-only block. Set
`ENABLE_WS=0` to skip the WebSocket-upgrade headers. Add
[`FORCE_HTTPS=1`](#forcing-http--https-force_https) for a `:80`→`:443` redirect,
and [`ROUTES=…`](#fronting-several-containers-under-one-domain-routes) to front
extra path-based upstreams (e.g. `/api`) under the same domain. All of these are
recorded per project and preserved across re-`add`.

**Re-running is safe.** If the project already exists, `appctl` keeps its
existing port and just regenerates the config (useful after changing
`PROXY_TIMEOUT`, the TLS mode, etc.). It does **not** allocate a new port. A
re-add keeps the recorded container port unless you pass a new one, which updates
it.

```bash
sudo appctl add api.mutaqorrobin.online              # certbot TLS, port 8080
sudo appctl add api.mutaqorrobin.online 8080         # or explicit
sudo TLS_MODE=shared appctl add api.mutaqorrobin.online   # shared origin cert
```

### `remove <project>` (alias: `rm`)

Delete the project's nginx block — **both** the `sites-enabled` symlink and the
`sites-available` file — free its port for reuse, then reload.

```bash
sudo appctl remove api.mutaqorrobin.online
```

> This does **not** stop the container. Stop it yourself in the project folder:
> `docker compose down`. (Keeping these separate means removing a route never
> unexpectedly kills a running service.)

### `ws <project> on|off`

Turn the HTTP→WebSocket upgrade on or off for an existing project and regenerate
its nginx block (validated + reloaded). Use this when an app starts needing live
reload / chat / SSE upgrades, or when you want to drop the upgrade headers.

```bash
sudo appctl ws api.mutaqorrobin.online on     # enable WebSocket upgrade
sudo appctl ws api.mutaqorrobin.online off    # plain HTTP proxying
```

### `docs [output_file]`

Print a **Markdown handover report** of everything appctl manages — domain, URL,
host port, forwarded container port, container name, and status — by joining the
registry with `docker ps`. Perfect for handing over "what's running where" to a
colleague. Prints to stdout; also writes the file when you pass a path.

```bash
appctl docs                    # print to the terminal
appctl docs handover.md        # also save a file to commit / share
```

```
| Project | Domain | URL | Host Port | Container Port | Container | Status |
| ------- | ------ | --- | --------- | -------------- | --------- | ------ |
| blog.mutaqorrobin.online | blog.mutaqorrobin.online | https://blog.mutaqorrobin.online | 10000 | 8080 | blog-app | Up 2 hours |
| api.mutaqorrobin.online  | api.mutaqorrobin.online  | https://api.mutaqorrobin.online  | 10001 | 8080 | api-app  | Up 5 hours |
```

### `list` (alias: `ls`)

Show all project → port → domain mappings (plus tier, TLS mode, and WebSocket
flag), sorted by port.

```bash
appctl list
```

```
PROJECT                  DOMAIN                         HOST_PORT  CONTAINER_PORT  TIER       TLS      WS
blog.mutaqorrobin.online blog.mutaqorrobin.online       10000      8080            frontend   certbot  on
api.mutaqorrobin.online  api.mutaqorrobin.online        11000      8080            backend    certbot  on
```

### `next [tier]`

Print the next free port in a tier's band **without** allocating it (default
tier: `frontend`). Handy for scripting or a quick sanity check.

```bash
appctl next            # next frontend port, e.g. -> 10001
appctl next backend    # next backend port,  e.g. -> 11000
```

---

## The repeatable recipe (every new project)

Once set up, adding any project — the 2nd or the 102nd — is always:

```bash
sudo appctl add <domain> [container_port]            # 1. allocate + configure + TLS
#   → paste the printed ports: mapping into compose.yml (port defaults to 8080)
docker compose up -d                                  # 2. start it
```

No port hunting, no hand-written nginx blocks, no manual symlink, no manual
reload, no manual cert issuance. Freed ports (from `remove`) are automatically
reused — the lowest free port is always chosen first.

---

## How ports are allocated (and when a collision can happen)

**`appctl list` is not a scan of the server.** It reads one file — the registry
(`/etc/nginx-deploy/registry.tsv`) — and prints only the projects appctl itself
created. Your hand-written blocks and their ports do **not** appear in `list`,
because appctl has no record of them. (It never reads `sites-enabled/`, parses
nginx, or asks Docker.) On a fresh install, `list` says _"No apps registered
yet"_ even with dozens of live apps.

Despite that, allocation is **not** blind. Before handing out a port, `add` /
`next` skip a candidate if **either** check trips:

1. **It's in the registry** — another appctl project already owns it.
2. **It's currently bound on the host** — appctl runs `ss` and skips any port
   something is actively listening on, _including_ services appctl knows nothing
   about (your hand-written apps, anything else).

appctl only ever allocates from its configured tier bands — by default
**10000–11999** — it never picks a port below 10000, so apps on `:3000`,
`:8080`, etc. are never even candidates.

### The one gap

The live-binding check only sees what's **running right now**. So the single
realistic collision is:

> a non-appctl service whose port is **in 10000–10999** and whose container is
> **stopped at the moment you run `add`** — it's invisible to both checks, so
> appctl could reuse its port. When that service restarts: `address already in
> use`.

| Scenario                                         | Will appctl reuse the port?             |
| ------------------------------------------------ | --------------------------------------- |
| Existing app on `:3000` (any state)              | **No** — out of range, never considered |
| A **running** service on `:10005`                | **No** — `ss` sees it, skips it         |
| A **stopped** non-appctl service on `:10005`     | **Possibly** — invisible to both checks |
| An appctl-managed app on `:10005` (even stopped) | **No** — it's in the registry           |

### The rule that keeps this safe

**Reserve the tier bands (10000–11999 by default) exclusively for appctl.** Never
hand-assign a port in those ranges to a non-appctl app. Since every existing app
on this server uses lower-numbered ports, this is already true out of the box —
just keep it that way and appctl can never collide.

---

## Port tiers (allocating by app class)

`appctl` allocates host ports from **named tiers**, so each class of app lives in
its own band and you can tell what something is from its port. The defaults are:

| Tier       | Band          |
| ---------- | ------------- |
| `frontend` | `10000–10999` |
| `backend`  | `11000–11999` |

When you `add` a **new** project, appctl **prompts** for the tier with the
default pre-filled — just press Enter to accept it:

```
$ sudo appctl add blog.mutaqorrobin.online
Port tier? [frontend, backend] (Enter for default: frontend): ⏎
Allocated host port 10000 (tier 'frontend') -> 'blog.mutaqorrobin.online'.
```

To **skip the prompt** — in scripts, CI, or when you just know the tier — set
`TIER=<name>`; it always wins and suppresses the prompt. In any non-interactive
context (piped, no TTY) appctl silently uses `DEFAULT_TIER`. Re-adding an
existing project never prompts (it keeps its port and tier).

```bash
sudo appctl add blog.mutaqorrobin.online              # prompts; Enter -> frontend -> 10000
sudo TIER=backend appctl add api.mutaqorrobin.online  # no prompt -> backend -> 11000
appctl next backend                                    # peek the next backend port
```

The `list` / `docs` output shows each app's tier, derived from its port —
nothing extra is stored.

### Defining your own tiers

Override `PORT_TIERS` with a space-separated list of `name:start-end` bands. They
must not overlap (appctl refuses to start if they do) and must stay **at or above
10000** so they never clash with hand-written apps on lower ports. For example, to
add `worker` and `db` bands:

```bash
export PORT_TIERS="frontend:10000-10999 backend:11000-11999 worker:12000-12499 db:12500-12999"
export DEFAULT_TIER=frontend
```

Put those exports in a wrapper or your shell profile to make them permanent.
Because a project's tier is read back from its allocated port, you can widen or
rename bands later and `list` / `docs` reflect it immediately — existing apps
keep their ports.

---

## TLS with certbot (default)

In the default `TLS_MODE=certbot`, `appctl` obtains a **per-domain Let's Encrypt
certificate** during `add` and points the `:443` block at it. Renewal is handled
by certbot's own systemd timer (`certbot renew`), and because the block
references the stable
`/etc/letsencrypt/live/<domain>/{fullchain,privkey}.pem` paths, renewed certs are
picked up automatically after nginx's next reload.

### What `add` does for TLS

1. Writes an **HTTP-only** block and reloads (so the `http-01` challenge on port
   80 is served).
2. Runs `certbot certonly --nginx -d <domain> --non-interactive --agree-tos
   --keep-until-expiring`. `certonly` means certbot **never edits** your nginx
   file — appctl stays the sole owner of the block.
3. Rewrites the block with the `:443` listener and reloads.

### Requirements for issuance

- The domain's **DNS record points at this server**.
- **Port 80 is reachable** from the internet (open the firewall / security
  group).
- certbot is installed (`sudo apt install certbot python3-certbot-nginx`).

Provide an ACME account email (recommended for expiry notices) with
`CERTBOT_EMAIL`:

```bash
sudo CERTBOT_EMAIL=you@example.com appctl add blog.mutaqorrobin.online
```

Without it, appctl registers with `--register-unsafely-without-email`. Extra
certbot flags can be appended via `CERTBOT_EXTRA_ARGS` (e.g. `--staging` while
testing to avoid rate limits).

> **If certbot fails**, appctl keeps the HTTP-only route up and prints how to
> retry. Fix DNS / port 80, then re-run the same `add` — it reuses the port and
> completes the HTTPS step.

---

## TLS with a shared origin cert (option)

If you'd rather terminate every project with **one shared certificate** — for
example a **Cloudflare Origin cert**, or an internal wildcard — run `add` with
`TLS_MODE=shared`. There is then no per-project certbot issuance.

### Setting up the shared origin cert

Do this **once** on the host, before your first shared-mode `add`. Using a
Cloudflare Origin cert as the example:

1. In the Cloudflare dashboard: **SSL/TLS → Origin Server → Create Certificate**.
   Let it generate the key. Cover your wildcard + apex, e.g.
   `*.mutaqorrobin.online` and `mutaqorrobin.online`. Pick a long validity.
2. Save the two PEM blocks on the host:
   ```bash
   sudo mkdir -p /etc/ssl/origin
   sudo tee /etc/ssl/origin/origin.pem >/dev/null   # paste the certificate
   sudo tee /etc/ssl/origin/origin.key >/dev/null   # paste the private key
   sudo chmod 600 /etc/ssl/origin/origin.key
   ```
3. If using Cloudflare: set **SSL/TLS → Overview → Full (strict)** and make sure
   each app's DNS record is **proxied** (orange cloud).

### Pointing appctl at the cert

The defaults already match the paths above:

```
SSL_CERT=/etc/ssl/origin/origin.pem
SSL_CERT_KEY=/etc/ssl/origin/origin.key
```

If your cert lives elsewhere, set `SSL_CERT` / `SSL_CERT_KEY` (see
[Configuration](#configuration-environment-overrides)). In shared mode `appctl`
checks the cert exists **before** writing a `:443` block and fails early with a
clear message if it's missing — so you never get a cryptic `nginx -t` error.

```bash
sudo TLS_MODE=shared appctl add api.mutaqorrobin.online
```

> **The cert must actually cover the domain.** A `*.mutaqorrobin.online` cert
> covers `api.mutaqorrobin.online` but **not** a bare `mutaqorrobin.online` or a
> deeper label like `a.b.mutaqorrobin.online`. `nginx -t` still passes for an
> uncovered domain (the file is valid), but browsers will throw a name-mismatch.
> `appctl` can only check the cert **file exists**, not what it covers.

### Turning HTTPS off

For a project that should be HTTP-only (rare), run that one `add` with
`TLS_MODE=none` (or `ENABLE_SSL=0`):

```bash
sudo TLS_MODE=none appctl add internal.mutaqorrobin.online
```

---

## WebSockets (per project)

Every server block includes the shared proxy snippet. When a project's
**WebSocket flag is on** (the default), it *also* includes `proxy-ws.conf`, which
sends the `Upgrade`/`Connection` headers so live reload, chat, and SSE upgrades
work. A shared `map` (`00-websocket-map`, namespaced as
`$appctl_connection_upgrade` so it won't clash with a `$connection_upgrade` you
define elsewhere) drives the `Connection` header.

Control it per project:

```bash
sudo ENABLE_WS=0 appctl add static.mutaqorrobin.online   # add without upgrade
sudo appctl ws static.mutaqorrobin.online on             # turn it on later
sudo appctl ws static.mutaqorrobin.online off            # or off again
```

The `WS` column in `appctl list` shows each project's current setting.

---

## Fronting several containers under one domain (`ROUTES`)

By default a project is one domain → one upstream. Some apps front **several
containers by path** — e.g. a frontend at `/` and a backend API at `/api/`.
`ROUTES` adds extra `location` blocks (rendered **before** the catch-all
`location /`) that proxy a path to any upstream you name:

```bash
sudo ROUTES='/api/=http://127.0.0.1:4000/' \
     appctl add book-review.mutaqorrobin.online 3000
```

- Format: pipe-separated `path=upstream` pairs —
  `'/api/=http://127.0.0.1:4000/|/ws=http://127.0.0.1:5000'`.
- The **upstream is emitted verbatim**, so `proxy_pass` trailing-slash semantics
  are yours to control: `.../4000/` (trailing slash) strips the matched `/api/`
  prefix; `.../4000` (no slash) passes the full path through.
- The main app still gets an appctl-allocated tier port for `location /`; the
  extra upstreams are fixed addresses you manage (they can be other appctl apps,
  a container on a known port, anything nginx can reach).
- Routes are recorded per project, so `ws`, re-`add`, and snippet regenerations
  preserve them. Pass `ROUTES=''` on a re-`add` to clear them.

## Forcing HTTP → HTTPS (`FORCE_HTTPS`)

By default an appctl block serves the same content on `:80` and `:443` (the edge —
e.g. Cloudflare — handles the redirect in that model). For a **directly-served**
domain you usually want a hard redirect. `FORCE_HTTPS=1` emits a dedicated `:80`
server that `301`-redirects to `https`, plus the `:443` server:

```bash
sudo FORCE_HTTPS=1 appctl add book-review.mutaqorrobin.online
```

It only takes effect when the project actually has a cert (certbot/shared);
it's ignored for `TLS_MODE=none`. Like routes, it's stored per project.

## TLS hardening (certbot options)

When a `:443` block is written, appctl **includes the certbot hardening files if
they exist** — `SSL_OPTIONS_FILE` (`/etc/letsencrypt/options-ssl-nginx.conf`, the
Mozilla-grade protocols/ciphers) and `SSL_DHPARAM_FILE`
(`/etc/letsencrypt/ssl-dhparams.pem`). So an appctl certbot block ends up with the
same hardening a `certbot --nginx` block would. Both paths are overridable; if the
files are absent they're simply skipped.

## Migrating an existing hand-written block to appctl

You may already have hand-written blocks in `sites-available` (named by domain,
no extension). A domain must be managed by **appctl OR by hand — never both**,
or nginx prints `conflicting server name ... ignored` and picks one
unpredictably.

To hand a domain over to `appctl`:

```bash
# 1. Note the upstream port the old block proxies to.
grep proxy_pass /etc/nginx/sites-available/blog.mutaqorrobin.online

# 2. Disable the old block (remove the symlink; keep the file as a backup).
sudo rm /etc/nginx/sites-enabled/blog.mutaqorrobin.online

# 3. Optional: move the old file aside so appctl's new file is the only one.
sudo mv /etc/nginx/sites-available/blog.mutaqorrobin.online /root/blog.mutaqorrobin.online.bak

# 4. Let appctl take over. Pass the upstream port from step 1 as the container
#    port so the printed compose mapping matches the old setup.
sudo appctl add blog.mutaqorrobin.online 3000
```

`appctl` will assign a loopback host port (e.g. `127.0.0.1:10000`). Update the
container's compose `ports:` to match. If the container previously published on
all interfaces (e.g. `3000:3000`), this also **tightens** it to loopback-only —
a security improvement; just confirm the container comes back up on the new
mapping.

---

## Configuration (environment overrides)

Every default can be overridden with an environment variable. Defaults:

| Variable                | Default                          | Purpose                                             |
| ----------------------- | -------------------------------- | --------------------------------------------------- |
| `APP_REGISTRY`          | `/etc/nginx-deploy/registry.tsv` | The source-of-truth registry file                   |
| `NGINX_SITES_AVAILABLE` | `/etc/nginx/sites-available`     | Where the real server-block files are written       |
| `NGINX_SITES_ENABLED`   | `/etc/nginx/sites-enabled`       | Where the enabling symlinks go                      |
| `NGINX_SNIPPETS_DIR`    | `/etc/nginx/snippets`            | Where the shared proxy snippets live                |
| `PORT_TIERS`            | `frontend:10000-10999 backend:11000-11999` | Named, non-overlapping port bands         |
| `DEFAULT_TIER`          | `frontend`                       | Band used by `add` when `TIER` is unset             |
| `TIER`                  | _(unset)_                        | Tier to allocate from for this `add` / `next`       |
| `BIND_ADDR`             | `127.0.0.1`                      | Loopback publish + proxy target (do **not** use `0.0.0.0`) |
| `DEFAULT_CONTAINER_PORT`| `8080`                           | Container port recorded when none is given          |
| `TLS_MODE`              | `certbot`                        | `certbot` \| `shared` \| `none`                     |
| `CERTBOT_CMD`           | `certbot`                        | certbot binary (certbot mode)                       |
| `CERTBOT_EMAIL`         | _(empty)_                        | ACME account email; empty → register without one    |
| `CERTBOT_EXTRA_ARGS`    | _(empty)_                        | Extra certbot flags (e.g. `--staging`)              |
| `SSL_CERT`              | `/etc/ssl/origin/origin.pem`     | Shared TLS certificate (shared mode)                |
| `SSL_CERT_KEY`          | `/etc/ssl/origin/origin.key`     | Shared TLS private key (shared mode)                |
| `SSL_OPTIONS_FILE`      | `/etc/letsencrypt/options-ssl-nginx.conf` | `include`d in `:443` if the file exists    |
| `SSL_DHPARAM_FILE`      | `/etc/letsencrypt/ssl-dhparams.pem` | `ssl_dhparam` in `:443` if the file exists       |
| `ENABLE_SSL`            | `1`                              | `0` forces `TLS_MODE=none` (back-compat)            |
| `ENABLE_WS`             | `1`                              | `1` = new projects upgrade to WebSocket; `0` = off  |
| `FORCE_HTTPS`           | _(unset)_                        | `1` = per-project `:80`→`:443` 301 redirect         |
| `ROUTES`                | _(unset)_                        | Per-project extra path upstreams (`path=upstream\|…`) |
| `PROXY_TIMEOUT`         | `300s`                           | `proxy_connect_timeout` + `proxy_read_timeout`      |
| `CLIENT_MAX_BODY_SIZE`  | `50M`                            | `client_max_body_size` (max upload)                 |
| `NGINX_TEST_CMD`        | `nginx -t`                       | Command to validate config                          |
| `NGINX_RELOAD_CMD`      | `systemctl reload nginx`         | Command to reload nginx                             |

To make an override permanent, put it in a small wrapper or export it in your
shell profile. (Changing `PROXY_TIMEOUT` / `CLIENT_MAX_BODY_SIZE` then re-running
any `appctl` command regenerates the shared snippet, so the new value applies to
**every** project at once.)

---

## What gets created

On first use, `appctl` creates (and thereafter maintains) these files:

| Path                                          | What it is                                                |
| --------------------------------------------- | --------------------------------------------------------- |
| `/etc/nginx-deploy/registry.tsv`              | The registry — project, domain, ports, TLS mode, WS flag  |
| `/etc/nginx/sites-available/<domain>`         | One server block per project (HTTP + HTTPS), no extension |
| `/etc/nginx/sites-enabled/<domain>`           | Symlink that enables the block above                      |
| `/etc/nginx/sites-available/00-websocket-map` | WebSocket upgrade map (symlinked into `sites-enabled`)    |
| `/etc/nginx/sites-enabled/00-websocket-map`   | Symlink enabling the map (loads first, at `http` context) |
| `/etc/nginx/snippets/proxy.conf`              | Shared proxy headers + tuning, `include`d by every block  |
| `/etc/nginx/snippets/proxy-ws.conf`           | WebSocket upgrade headers, `include`d by WS-on projects   |
| `/etc/letsencrypt/live/<domain>/`             | Per-domain certbot certs (certbot mode)                   |

Putting the proxy headers + tuning in shared snippets means you maintain them in
**one** place, not in 100 copied-and-pasted blocks. Splitting the WebSocket
upgrade into its own snippet is what lets each project opt in or out
independently.

---

## Troubleshooting

**502 Bad Gateway.**
The container isn't reachable on the published port. Check it's running and
published on loopback:

```bash
docker ps --format '{{.Names}}\t{{.Ports}}'   # expect 127.0.0.1:<port>->...
```

Make sure the **container port** in your compose mapping matches what the app
actually listens on, and that the **host port** matches what `appctl list`
shows. The generated config proxies to `127.0.0.1` (IPv4) deliberately — using
`localhost` can resolve to IPv6 `::1` first and cause intermittent 502s.

**certbot couldn't obtain a certificate.**
appctl left the HTTP-only route up. The usual causes: the domain's DNS doesn't
point at this server yet, or **port 80 isn't reachable** from the internet (the
`http-01` challenge fails). Fix those, then re-run the same `appctl add` — it
reuses the port and completes the HTTPS step. While testing, add
`CERTBOT_EXTRA_ARGS=--staging` to avoid Let's Encrypt rate limits.

**`conflicting server name "..." ignored` on reload.**
Two server blocks claim the same `server_name`. Almost always: the domain still
has a hand-written block enabled **and** an appctl-managed one. Pick one — see
[Migrating an existing hand-written block](#migrating-an-existing-hand-written-block-to-appctl).

**`shared ssl cert not found: ...` (shared mode).**
`appctl` refused to write a `:443` block because the cert/key file is missing at
`SSL_CERT` / `SSL_CERT_KEY`. Install the shared origin cert (see above), fix the
path, use `TLS_MODE=certbot`, or run that `add` with `TLS_MODE=none`.

**TLS / cert name mismatch in the browser (shared mode, `nginx -t` passes).**
The shared cert doesn't cover this domain. Confirm the host is under your cert's
wildcard (`*.mutaqorrobin.online`).

**Port conflict / container won't start (`address already in use`).**
Two projects can't publish the same host port. Run `appctl list` to see what's
allocated; let `appctl` assign the port rather than hand-editing the mapping. If
the clashing service is **not** appctl-managed, see
[How ports are allocated](#how-ports-are-allocated-and-when-a-collision-can-happen) —
the usual cause is a non-appctl app holding a port in the 10000–10999 range.

**WebSockets not upgrading.**
Confirm the project's `WS` column in `appctl list` is `on` (turn it on with
`appctl ws <project> on`). Then check `/etc/nginx/sites-enabled/00-websocket-map`
exists (a symlink) and that the block `include`s `proxy-ws.conf`. Finally
`sudo nginx -t && sudo systemctl reload nginx`.

**"must run as root."**
Writing into `/etc/nginx` needs root. Prefix the command with `sudo`.

**Ran out of ports (in a tier).**
Each default tier band holds 1000 ports. Widen the affected band in `PORT_TIERS`
(keeping bands non-overlapping), e.g. give `backend` 2000 ports:

```bash
sudo PORT_TIERS="frontend:10000-10999 backend:11000-12999" appctl add ...
```

---

## Quick reference card

```bash
# Deploy a project (domain doubles as the filename + server_name)
sudo appctl add <domain> [container_port]      # container port defaults to 8080
sudo TIER=backend appctl add <domain>          # allocate from the backend band
#   then paste the printed ports: line into docker-compose.yml
docker compose up -d

# See everything / find next port in a tier / write a handover doc
appctl list
appctl next [tier]
appctl docs handover.md

# Toggle WebSocket upgrade for a project
sudo appctl ws <domain> on|off

# Remove a route (symlink + file), then stop the container yourself
sudo appctl remove <domain>
docker compose down

# Shared-cert or HTTP-only project
sudo TLS_MODE=shared appctl add <domain> [container_port]
sudo TLS_MODE=none   appctl add <domain> [container_port]

# Rare: make the filename/key differ from the server_name
sudo appctl add <project> <domain> [container_port]
```
