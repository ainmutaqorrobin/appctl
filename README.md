# appctl

**Port assigner + nginx server-block generator for a host-installed nginx
fronting Docker apps.**

Run nginx directly on the host and proxy to apps running in Docker. `appctl`
makes deploying the 101st project the same single command as the 1st: it
allocates a free host port, writes and validates the nginx config, obtains TLS,
enables the block, reloads nginx, and prints the exact `docker-compose` port
mapping to paste in. A single registry file is the source of truth for which
port belongs to which project — no more hand-tracking ports or copy-pasting
server blocks.

## What it solves

Fronting many Docker apps with one host nginx gets painful fast: picking a free
port every time, repeating the same compose-edit / server-block / symlink /
cert / reload dance for each project, and keeping every TLS block identical.
`appctl` collapses all of that into one command.

## Features

- **Port allocation from named tiers** (frontends `10000–10999`, backends
  `11000–11999` by default; add your own with `PORT_TIERS`), skipping anything
  already in the registry or bound on the host. `add` **prompts** for the tier
  with a default pre-filled; set `TIER=…` to skip the prompt in scripts.
- **Loopback-only publishing by design.** Containers publish on `127.0.0.1`, so
  the internet can't bypass nginx — and because Docker's iptables rules bypass
  UFW/firewalld, a `0.0.0.0` publish would be internet-exposed *even with a
  firewall deny rule*. Loopback avoids that trap.
- **nginx block generation** into `sites-available/`, enabled via a
  `sites-enabled/` symlink, validated with `nginx -t`, and reloaded — with clean
  rollback if the config ever fails to test.
- **TLS, per domain by default** — obtains a Let's Encrypt cert with **certbot**
  on `add`. Or use one **shared origin cert** for every project
  (`TLS_MODE=shared`, works with e.g. a Cloudflare Origin cert), or go HTTP-only
  (`TLS_MODE=none`).
- **Per-app WebSocket upgrade** — on by default; opt out with `ENABLE_WS=0`, or
  flip an existing app with `appctl ws <project> on|off`.
- **Multi-upstream domains** — front several containers under one domain by path
  with `ROUTES='/api/=http://127.0.0.1:4000/'`, force `:80`→`:443` with
  `FORCE_HTTPS=1`, and get certbot SSL-hardening includes automatically.
- **Per-app proxy tuning** — override upload limits per domain with
  `MAX_BODY_SIZE=500M` and inject arbitrary server directives (e.g. streaming for
  an object store) with `PROXY_EXTRA='proxy_request_buffering off;'`.
- **Handover docs** — `appctl docs` prints (and optionally writes) a Markdown
  report of every app: domain, URL, host port, forwarded container port,
  container name, and status.
- **Loopback-only publishing** so the public internet can't bypass nginx.
- **`list` / `next`** to see every mapping or preview the next free port.

## Install

```bash
sudo cp appctl /usr/local/bin/appctl
sudo chmod +x /usr/local/bin/appctl
appctl --help
```

The first command bootstraps everything it needs (registry, shared proxy
snippets, WebSocket map).

**Prerequisites:** nginx (`sites-available`/`sites-enabled` layout), Docker +
Compose, and — for the default TLS mode — certbot
(`sudo apt install certbot python3-certbot-nginx`) with the app's DNS pointed at
the host and port 80 reachable.

## Quick start

```bash
# 1. Allocate a port, generate the nginx config, and obtain a cert.
sudo appctl add blog.mutaqorrobin.online
#    → prints a docker-compose `ports:` mapping like:
#      - "127.0.0.1:10000:8080"

# 2. Paste that mapping into the project's docker-compose.yml, then:
docker compose up -d
```

Visit `https://blog.mutaqorrobin.online` — done.

## Commands

| Command                                   | What it does                                                                 |
| ----------------------------------------- | ---------------------------------------------------------------------------- |
| `add <domain> [container_port]`           | Allocate a port, write + enable the nginx block, obtain TLS, print compose.   |
| `add <project> <domain> [container_port]` | Same, but the filename/key differs from the `server_name`.                    |
| `remove <project>` (`rm`)                 | Delete the block (symlink + file) and free its port. Doesn't stop containers. |
| `ws <project> on\|off`                    | Toggle the HTTP→WebSocket upgrade for an existing app and regenerate.         |
| `docs [output_file]`                      | Markdown handover report of every app; prints, and writes a file if given.    |
| `list` (`ls`)                             | List every project → port → domain mapping, with tier, TLS mode, and WS flag. |
| `next [tier]`                             | Print the next free port in a tier's band without allocating it.              |

Common variants:

```bash
sudo appctl add api.mutaqorrobin.online 3000              # explicit container port
sudo TIER=backend    appctl add api.mutaqorrobin.online   # allocate from backend band
sudo TLS_MODE=shared appctl add api.mutaqorrobin.online   # shared origin cert
sudo TLS_MODE=none   appctl add api.mutaqorrobin.online   # HTTP only
sudo ENABLE_WS=0     appctl add api.mutaqorrobin.online   # no WebSocket upgrade
appctl docs handover.md
```

Every default (ports range, cert paths, certbot email, proxy timeouts, etc.) is
overridable via environment variables — run `appctl --help` for the full list.

## Full guide

See **[appctl.md](appctl.md)** for the complete deployment guide: the model,
prerequisites, per-command reference, TLS setup (certbot and shared cert),
WebSocket details, migrating hand-written blocks, configuration, and
troubleshooting.

## License

Copyright 2026 Ain Mutaqorrobin.

Licensed under the **Apache License, Version 2.0** — see [LICENSE](LICENSE) and
[NOTICE](NOTICE). You may use, modify, and redistribute this software (including
commercially), **provided you retain the copyright and NOTICE and state any
changes you make**. The software is provided "as is", without warranty of any
kind.
