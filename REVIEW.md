# modular-sanic-docker: Repository Review (second pass)

Reviewed: `main` at `4dc2350` (2026-10-20). This pass covers fix batch 4 (#1), the build-isolation change (#2), and your commit `4dc2350` ("Removed server tokens - already present in dhi.io version of nginx").

This pass focuses on **performance, bugs, runtime errors, architecture/design, and health**, and on how the stack runs modular-sanic `main` (now on sanic-session v0.9.0).

Tags:
- **[verified]**: reproduced; with `nginx:1` locally, since `dhi.io` is not reachable from the review sandbox.
- **[measured]**: has numbers.
- **[reasoned]**: from reading the code.

No files other than this review were changed.

## 1. The stack today

```
client ──80/443──▶ nginx (dhi.io/nginx:1)
                     ├─ /            → ./html (security-headers.conf)
                     ├─ /ram         → shared tmpfs, autoindex (security-headers.conf)
                     └─ /api /auth /docs → api:8000
api (python:3.14-slim + git clone of modular-sanic main; sanic --debug --reload, 1 process)
  ├─ memcached:latest  (-m 32768 -I 512M -t 16)
  └─ mariadb:12-ubi10  (healthcheck; init.sql; audit plugin)
```

What batch 4 fixed, re-checked here:
- **PAM:** works via `group_add: SHADOW_GID`.
- **Proxy:** `SANIC_PROXIES_COUNT=1` (client IPs and HSTS are correct).
- **First run:** `${VAR:?}` guards on the passwords.
- **`setup.sh` permissions.**
- **nginx-served pages** get the security headers.
- **README, SANs, health checks, TZ, `set -euo pipefail`.**

## 2. Checks run

| Check | Result |
|---|---|
| `nginx -t` with the shipped `default.conf` on `nginx:1` (1.31.7) | OK. |
| `server_tokens` placement, with an `nginx.conf` that already sets `server_tokens off;` in `http {}` (as you describe the dhi image) | A second **http-level** `server_tokens off;` in `conf.d`: **fails** (`"server_tokens" directive is duplicate`). That explains your removal. The **server-level** `server { server_tokens off; … }`: **passes**, on both that config and stock `nginx:1`. |
| `nginx:1` without `server_tokens` (the README's fallback image) | `Server: nginx/1.31.7`, and the version shows on error pages [verified]. |
| Binary wheels for every modular-sanic requirement on CPython 3.14 / manylinux x86_64 | **All 31 resolve as wheels** (`pip download --only-binary=:all:`). `python-pam` and `aiomysql` are pure Python. Nothing needs a compiler now that `mysqlclient` is gone. |
| modular-sanic behaviour behind this stack | See modular-sanic REVIEW.md. H-1 (the rate limiter fails open when memcached fails) and M-2 (cookieless requests create sessions) matter most here. |

## 3. Findings

### HIGH

#### H-1. The API container still runs `sanic --debug --reload`: one process, a file watcher, and restarts on any file change **[verified in the first review; unchanged]**

`docker-compose.yml`, `api.command`:

```
python -m sanic server --reload --debug --host=0.0.0.0 -R /app/external
```

What this means:
- **One worker:** there is no `--workers`, so all requests share one event loop and one CPU. The aiomysql pool and the memcached clients serve that one process.
- **Polling reloader:** it watches the bind-mounted `./api`, and any edit, `git pull`, or editor swap file restarts the server. Each restart gives in-flight requests and nginx 502s, and drops the in-memory rate limits.
- **Debug logging:** verbose, and debug behaviour in Sanic's own error pages for exceptions modular-sanic doesn't catch.

This was M-4 in the first review. It is listed as High now, because with the focus on performance and runtime health it is the largest gap between "deployment" and "dev box".

**Fix:** make production the default and development the opt-in:

```yaml
command: ["python", "-m", "sanic", "server", "--host=0.0.0.0", "--port=8000",
          "--workers=${WORKERS:-2}", "--no-access-logs"]
```

Then provide a `docker-compose.dev.yml` override that adds `--debug --reload -R /app/external`. With more than one worker, memcached must be up at API start (see M-3), or sessions split between workers.

### MEDIUM

#### M-1. The image ships a C toolchain and MySQL headers it no longer needs **[verified]**

`config/sanic/Dockerfile` installs:
- `build-essential`, `gcc`, `pkg-config`, `default-libmysqlclient-dev`;
- `netcat-openbsd`, `unzip`, `zip`, `inotify-tools`.

After `96b1771` (modular-sanic drops `mysqlclient`), every requirement installs from a wheel (checked above). The compiler, the MySQL client headers and the zip tools are dead weight. They make the image larger, the build slower, and the image's attack and CVE surface bigger, and none of them run.

**Fix:** keep only `git` and `ca-certificates`. `git` is needed for `git clone` and the `sanic_session @ git+…` requirement; switching that to `…/archive/refs/tags/v0.9.0.tar.gz` would make git unnecessary at install time. Then drop the rest:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
```

`libpam0g`, which `python-pam` loads, is already in the slim base.

Add `inotify-tools` back only in a development image, if the reloader should use inotify.

#### M-2. Server tokens are back on with the README's `nginx:1` fallback, and the fix that works on both images is server-level **[verified]**

`4dc2350` removed `server_tokens off;` because the dhi image already sets it in `http {}`, where a second copy is a duplicate error. On the documented `nginx:1` fallback (README), nginx now advertises `nginx/1.31.7` in `Server:` and on every error page.

**Fix:** put it back **inside both `server {}` blocks** in `config/nginx/default.conf`. That is a different context, valid next to the dhi image's http-level setting (verified with `nginx -t`), and it covers the fallback image too.

#### M-3. memcached is a single point of failure with no health check, a 32 GB cap, and modular-sanic stores a session for every cookieless request **[verified for the memcached behaviour]**

What I verified, together with modular-sanic:
- **When memcached stops,** every logon gets a 503 and the rate limiter fails open: unlimited guesses, and a 503 for the right one (modular-sanic H-1).
- **When memcached restarts** (`restart: unless-stopped`), all sessions and rate-limit counters are wiped.
- **Every cookieless `/auth/info` request** stores a 7-day session (modular-sanic M-2). That includes probes, crawlers and uptime monitors.

What I reasoned from the compose file:
- **No health check:** `api` depends on `memcached` with `service_started` only. If the API's import-time probe runs before memcached listens, modular-sanic silently uses per-worker in-memory sessions (modular-sanic M-6). That is harmless with one debug worker, and broken with several (H-1).
- **Memory:** `-m 32768 -I 512M` (first review, M-10) lets those sessions grow to 32 GB before any eviction, and allows 512 MB items, where sessions are a few hundred bytes.

**Fix:**
- `-m ${MEMCACHED_MB:-256} -I 1m`, which is ample for sessions.
- A health check for memcached, for example `["CMD-SHELL", "echo stats | nc -q1 127.0.0.1 11211 | grep -q uptime"]` (needs `nc`; the stock image has none, so a tiny `python -c` check from the api side is the alternative), with `depends_on: condition: service_healthy`.
- Pin `memcached:1.6`.
- Follow modular-sanic H-1 and M-2.

#### M-4. Reproducibility: the Dockerfile clones whatever `main` is, and the layer is cached forever (first review M-5, open)

- `RUN git clone https://github.com/jskenney/modular-sanic.git /app` takes `main` at first build, and Docker's layer cache then keeps that commit until `--no-cache`.
- The requirements are unpinned (modular-sanic M-7), so two builds a day apart can differ, or a stale build can silently miss fixes, such as the v0.9.0 move.
- `memcached:latest` is unpinned too.

**Fix:**
- `ARG MODULAR_SANIC_REF=<tag or sha>` and `git clone --depth 1 --branch "$MODULAR_SANIC_REF"`; or `COPY` a git submodule.
- Install from a lock file once modular-sanic ships one.
- Pin `memcached:1.6`.

#### M-5. nginx proxying: no upstream keepalive, only three paths forwarded, and `/ram` is public (first review M-2 and M-3, open)

**Performance [reasoned]:** `proxy_pass http://api:8000/...` without an `upstream { keepalive 16; }`, `proxy_http_version 1.1` and `proxy_set_header Connection ""` opens a new TCP connection to Sanic for every proxied request. That is small on one host, but it is free to fix.

There is also no `gzip` for HTML, CSS and JS: the logon pages are 18–22 KB each [measured], mostly the duplicated `AuthUI` script (modular-sanic L-6).

**Design (open from the first review):**
- Only `/api`, `/auth` and `/docs` are forwarded, so extension routes elsewhere are unreachable (M-3).
- `/ram` is an unauthenticated, world-writable tmpfs with `autoindex on` (M-2).

**Fix:**
- One `upstream api { server api:8000; keepalive 16; }`, used by a shared `proxy.conf` include.
- `gzip on; gzip_types text/css application/javascript application/json;`.
- Decide what `/ram` is for, and protect it (`auth_request /auth/key`) or remove it.

### LOW

| ID | Where | Issue | Fix |
|---|---|---|---|
| L-1 | `docker-compose.yml`, api healthcheck | The health check (`/auth/redirect_if_logged_on` every 10 s) proves Sanic answers, but not that MariaDB or memcached work for it. After a database outage the API stays "healthy" while every logon fails (modular-sanic M-1). It creates no sessions, which is good. | Optionally add a `/health` route in modular-sanic that pings the pool and memcached; keep the check cheap. |
| L-2 | `default.conf:6` | `return 302` to `https://$host$request_uri` still drops a non-443 `WEB_SECURE` port, and is temporary (first review L-2). | `301`, with the port templated or documented. |
| L-3 | `env-example`, compose | `API_PORT` and `DB_PORT` still look configurable but aren't wired through (first review L-4). | Remove them, or wire them through. |
| L-4 | `html/`, `init.sql` | The landing page is still "down for maintenance", the bundled pages link to endpoints that aren't enabled, and there is no way to create the first administrator (first review L-5 to L-7). | As in the first review. |
| L-5 | `docker-compose.yml`, mariadb | `restart: unless-stopped`, but there is no backup or upgrade story for `./data/mariadb` (first review M-6). The audit log rotates at 10 × 100 MB, which is fine. | A `README` section on `mariadb-dump` and schema migrations (modular-sanic ships `migrate_*.sql`). |

## 4. Status of findings from the first review

| Item | Status | Notes |
|---|---|---|
| H-1 PAM | **Fixed** (#1) | |
| H-2 host shadow mounted | **Open, by design** | Documented in compose and the README. |
| H-3 proxy trust | **Fixed** (#1) | |
| H-4 first run without `.env` | **Fixed** (#1) | |
| H-5 `setup.sh` permissions | **Fixed** (#1) | |
| M-1 nginx security headers | **Fixed** (#1) | |
| M-2 `/ram` public | **Open** | M-5. |
| M-3 only three paths proxied | **Open** | M-5. |
| M-4 debug and reload | **Open** | Now H-1. |
| M-5 unpinned clone | **Open** | Now M-4. |
| M-6 drift and DB upgrades | **Open** | L-5. |
| M-7 `dhi.io` image | **Open** | The README documents the `nginx:1` fallback; see M-2 for `server_tokens`. |
| M-8 public docs, weak example secrets | **Partly fixed** | Passwords are now required; `DOCUMENTATION` stays off by default in modular-sanic. |
| M-9 README | **Fixed** (#1) | |
| M-10 memcached memory, unpinned images | **Open** | M-3 and M-4. |
| L-1 SAN | **Fixed** (#1) | |
| L-3 `server_tokens`, restart, health checks | **Partly regressed** | Restart and health checks are fixed; `server_tokens` was removed in `4dc2350` (M-2). |
| L-8 `setup.sh` | **Fixed** (#1) | |
| L-9 TZ | **Fixed** (#1) | |
| L-2, L-4 to L-7 | **Open** | L-2, L-3, L-4. |
| #2 build isolation | **Fixed** | `pip install -r requirements.txt` builds normally. |

## 5. Prioritized top 10

1. **H-1:** run production mode (several workers, no debug or reload) by default, with a dev override file.
2. **M-3, together with modular-sanic H-1:** memcached health check and `service_healthy`, a sane `-m`/`-I`, and a pinned tag. Fix the fail-open limiter in modular-sanic.
3. **M-2:** `server_tokens off;` inside each `server {}`, which works on dhi and `nginx:1`.
4. **M-1:** drop the build toolchain and MySQL headers from the image.
5. **M-4:** pin the modular-sanic ref in the Dockerfile, and pin memcached.
6. **M-5:** decide on `/ram` (protect or remove it).
7. **M-5:** forward extension paths, or document `API_LOCATIONS` prefixes.
8. **M-5:** upstream keepalive and gzip.
9. **L-1:** a health check that covers the DB and memcached.
10. **L-2 to L-5:** redirect port, unused port variables, landing page and first admin, backup notes.
