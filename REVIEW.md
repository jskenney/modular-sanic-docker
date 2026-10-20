# modular-sanic-docker: Repository Review

Reviewed at `2ac81d7` ("Initial Commit"), 2026-10-20, against modular-sanic `main` at `b200d4e` (after the three review fix batches). No files in this repo were changed. This file is the only addition.

**How it was reviewed:**
- I read every file: `docker-compose.yml`, `config/sanic/Dockerfile`, `config/nginx/default.conf`, `config/mariadb/init.sql`, `setup.sh`, `env-example`, `.gitignore` and `html/`.
- I compared the copied files with modular-sanic `main`.
- I ran `setup.sh`, then brought the stack up with Docker 29.9.1 and tested it over HTTPS through nginx, with `curl` and headless Chromium.

**What the sandbox could not run.** These substitutions affect what was tested:

| Blocked | Effect on this review |
|---|---|
| `dhi.io` (the nginx image) is denied by this sandbox's network policy | nginx was tested with Docker Hub's `nginx:1` running this repo's `default.conf`, through a compose override. Behaviour specific to the hardened image (non-root uid 65532, its config layout, whether pulling needs a login) is **unverified** and marked as such. |
| `deb.debian.org` is denied, so the Dockerfile's `apt-get` step cannot run | The API image was built from the same `python:3.14-slim` base with modular-sanic `main` copied in instead of `git clone`, the same `requirements.txt` from PyPI, and no `mysqlclient` (which needs the apt build tools and is unused). Dockerfile findings come from reading it, and are marked as reasoned rather than verified. |

Findings marked **[verified]** were reproduced on the running stack.

---

## 1. How the stack fits together

```
browser ──HTTP :80──► nginx ── 302 ──► HTTPS :443
browser ──HTTPS :443─► nginx ─┬─ /            → static files from ./html
                              ├─ /auth /api /docs → http://api:8000  (modular-sanic)
                              └─ /ram          → shared tmpfs volume (autoindex)
api (modular-sanic, uid 1000) ─┬─ mariadb:3306   (init.sql on first start)
                               ├─ memcached:11211 (sessions, rate limits)
                               └─ host /etc/passwd, /etc/shadow, /etc/group (read-only, for PAM)
```

- **`setup.sh`** sets file modes across the whole tree, creates `data/mariadb/{db,audit}` (owned by 999) and `config/ssl`, and generates a 10-year self-signed `bundle.crt`/`bundle.key` (owned by 65532, the hardened-nginx user).
- **The `api` image** clones modular-sanic at build time and installs its requirements. Compose mounts `./api` → `/app/external`, `./html` → `/app/html` and `./.env` → `/app/.env`, then runs `python -m sanic server --reload --debug --host=0.0.0.0 -R /app/external`.
- **`env-example`** enables only `api/auth/general`, `api/auth/pam` and `external`, so PAM is the only way to log on.

### What works
Verified, once the H-1 and H-4 fixes below are applied:
- `init.sql` matches modular-sanic `main`'s `setup/auth_tables.sql` exactly. It creates the three tables in `app`, with case-sensitive user names and the API key index.
- MariaDB 12.3.3 starts healthy, including the `server_audit` plugin, writing its log to `data/mariadb/audit`. The container's `mysql` user is uid 999, matching `setup.sh`.
- Python 3.14 has wheels for every dependency. sanic 25.12.1, sanic-ext, aiomysql, aiomcache, python-pam, ujson, orjson, pydantic and cryptography all install.
- The app connects to memcached and MariaDB, loads its blueprints plus files dropped into `./api`, and reads `.env` through environs.
- HTTP redirects to HTTPS. The `__Host-session` cookie is kept over nginx's TLS.
- Logon, Generate new API key and logoff all work in Chromium.
- The HTML copied into this repo is byte-identical to modular-sanic `main`.
- `/ram` has no path-traversal hole: `/ram../etc/passwd` returns 404.

---

## 2. Findings

### HIGH

#### H-1. PAM logon cannot work, and it is the only logon method enabled **[verified]**
`docker-compose.yml:77,83-85`. The API runs as `1000:1000` with no supplementary groups. The mounted host `/etc/shadow` is `640 root:shadow`, so inside the container `cat /etc/shadow` fails. `pam_unix`'s helper (`unix_chkpwd`) only verifies the calling user's own password. A `POST /auth/pam` with a **correct** password returned 401.

`env-example:4` enables only `general`, `pam` and `external`, so out of the box **nobody can log on**.

**Fix.** Add the host's shadow group to the API service:

```yaml
api:
  group_add:
    - "${SHADOW_GID:-42}"   # host shadow group (42 on Debian/Ubuntu); check: getent group shadow
```

Verified: with `group_add: ["42"]`, the same logon returned 200 and a working session. Because this widens H-2, document it, or also enable `api/auth/apikey` and bootstrap an admin (L-7).

#### H-2. The host's password hashes are mounted into the application container
`docker-compose.yml:83-85` mounts the host's `/etc/passwd`, `/etc/shadow` and `/etc/group`. Endpoint files in `./api` are arbitrary code by design. With the H-1 fix applied, any endpoint can read the **host's** password hashes, and any code-execution bug in an endpoint exposes every host account.

**Fix.** Prefer a non-host password source for container logons:
- a dedicated PAM service with `pam_succeed_if` limiting logons to one group;
- a container-local `passwd`/`shadow` holding only application users, mounted from `./config/pam/`;
- SSSD/LDAP;
- or API-key and email logons.

If host PAM is kept, make it opt-in (a compose profile or override file) and document the risk next to it.

#### H-3. nginx isn't trusted as a proxy, so all clients share one rate limit, HSTS is off, and the logs mislead **[verified]**
`config/nginx/default.conf:30-55` sends `X-Forwarded-For`/`X-Forwarded-Proto`, but the API isn't told to trust them. Every request therefore appears to come from nginx (`ip=172.18.0.5` in the logs) over plain HTTP.

- **Lockout:** 10 bad logons from one client made the **real user's correct logon return 429**. One person can lock everyone out indefinitely.
- **HSTS never sent:** with `HSTS=86400`, no `Strict-Transport-Security` header appeared.
- **Misleading warnings:** the app logs "Forwarded headers received but no proxy is configured", and, for a real hostname, "Plain HTTP request … logons will not stick", even though the browser used HTTPS.

**The `.env` route does not work. This is a modular-sanic bug.** Adding `SANIC_PROXIES_COUNT=1` to `.env`, as modular-sanic's README and `env-example` suggest, has **no effect**. environs 15 loads `.env` into its own `Env` object, not `os.environ`, and Sanic reads `SANIC_*` settings only from the real environment. (The settings modular-sanic reads itself, such as `HSTS`, do work from `.env`.) This needs fixing in modular-sanic too; see section 4.

**Fix for this repo.** Set it in compose, where nginx is always the single proxy:

```yaml
api:
  environment:
    SANIC_PROXIES_COUNT: "1"
```

Verified: with this setting, an attacker container (172.18.0.6) got 429 on its 11th attempt while the real user from another address logged on (200). HSTS was sent, and neither warning appeared. Client-supplied `X-Forwarded-For` values were correctly ignored, because nginx appends the real address and the last hop is used.

#### H-4. A first run without `.env` breaks in ways that are hard to undo **[verified]**
- `setup.sh` doesn't create `.env`, and compose bind-mounts `./.env:/app/.env:ro` (`docker-compose.yml:81`). On `docker compose up`, Docker created **`.env` and `api/` as root-owned directories** on the host.
- The API then ran on its built-in defaults: memcached and MySQL on 127.0.0.1, both unreachable. It fell back to in-memory sessions, and the containers still showed as "running".
- The natural next step, `cp env-example .env`, silently copied the file **into** the `.env` directory.
- MariaDB had meanwhile initialised `data/mariadb/db` with the compose defaults (`DB_PASS` `apppassword`, `docker-compose.yml:35`). `env-example:21` uses a different password, `apppasswd`. After `.env` was fixed, the app got **`Access denied for user 'app'`**. MariaDB applies credentials only on first initialisation, so the only remedy was deleting the database directory.

**Fix.**
- In `setup.sh`, copy `env-example` to `.env` if it's missing (and `mkdir -p api`), and refuse to continue if `.env` is a directory.
- Make the compose defaults match `env-example`, or drop them and use `${DB_PASS:?set DB_PASS in .env}`, so compose fails fast without `.env`.
- Consider `env_file: .env` on the API service instead of a file bind mount.

#### H-5. Re-running `setup.sh` on a live deployment makes the database world-readable **[verified]**
`setup.sh:3-5` runs `sudo find . -type f -exec chmod 644` (and `chmod 755` for directories) across the whole tree, including `data/`. After a re-run, MariaDB's files went from **660 to 644** and their directories became 755. That includes `mysql/global_priv.MAD`, which holds the account password hashes, the application tables and `server_audit.log`. In a normal install path, any local user can then read them. `.env`, which holds the database passwords, is also left at 644.

**Fix.** Limit the chmod passes to the repo's own files (for example `git ls-files -z | xargs -0 chmod 644`) and never touch `data/`. Set `chmod 600 .env`. Leave MariaDB's datadir modes to MariaDB.

### MEDIUM

#### M-1. Pages served by nginx get none of the app's security headers **[verified]**
nginx serves all HTML itself (`default.conf:23-27`). `/logon/logon.html` came back with only `Server: nginx/1.31.7`: no `Content-Security-Policy`, no `X-Frame-Options`, no `X-Content-Type-Options` and no HSTS. So the logon and su pages can be framed (clickjacking), and modular-sanic's inline-script hashes are never used. Proxied `/auth/*` responses do carry all of them.

**Fix.** Either proxy `/` to Sanic (which already serves `/app/html` and adds the headers), or add the same headers in nginx with `add_header … always`, including a CSP that matches the pages' scripts.

#### M-2. `/ram` publishes a world-writable shared directory to the internet without a logon **[verified]**
`default.conf:58-61` (`alias /ram; autoindex on;`). The directory listing and every file in it are served to anyone, with no logon. Files the API writes there were created `rw-rw-rw-`.

**Fix.** If the files are per-user or sensitive, guard them with `auth_request` to a small Sanic endpoint, or mark the location `internal` and serve files through `X-Accel-Redirect` from an authorised endpoint. Turn off `autoindex`. Set a `umask`, or mount options (`uid=1000,mode=0750`), on the tmpfs.

#### M-3. nginx only forwards `/api`, `/auth` and `/docs`, so most endpoint files are unreachable **[verified]**
modular-sanic lets a blueprint use any `url_prefix`. A file in `./api` with prefix `/reports` loaded fine, and answered 200 inside the container, but was a **404 through nginx**. Only `/api/*` worked. Docker also creates `./api` as a root-owned directory (H-4), so adding endpoint files needs `sudo`.

**Fix.** Document "endpoint prefixes must start with `/api`", or proxy every path that isn't a static file, for example `try_files $uri $uri/ @api;` with `location @api { proxy_pass http://api:8000; … }`. Create `./api` in `setup.sh`.

#### M-4. The API container runs in debug and auto-reload mode **[verified]**
`docker-compose.yml:92` uses `--reload --debug`; the logs show `mode: debug, single worker`. Debug responses are verbose, one worker handles every request, and the reloader watches the mounted code. For "easy deployment" this should not be the default.

**Fix.** Default to `--workers=${WORKERS:-2}` with no debug, and put `--debug --reload` in a `compose.override.yml` or a `dev` profile used for testing.

#### M-5. The Dockerfile builds whatever modular-sanic `HEAD` was at first build, then keeps reusing it (reasoned)
`config/sanic/Dockerfile:22`: `RUN git clone https://github.com/jskenney/modular-sanic.git /app`.
- **Not reproducible:** no tag or commit is pinned, so two machines building on different days get different code.
- **Stale:** Docker caches that layer because the command text never changes. A normal `docker compose build` keeps the first clone forever, so later modular-sanic fixes, migrations and README changes never arrive without `--no-cache`.
- **Large:** the runtime image keeps `build-essential`, `gcc`, `git` and the MySQL headers, which exist only to compile the unused `mysqlclient`. The test image without them was 291 MB.

**Fix.** Add `ARG MODULAR_SANIC_REF=<tag or sha>` and fetch that ref (for example `ADD https://github.com/jskenney/modular-sanic.git#${MODULAR_SANIC_REF} /app`). Use a multi-stage build, or drop `mysqlclient` from modular-sanic's requirements (its review item M-7). Pin `python:3.14-slim` to a digest for repeatable builds.

#### M-6. Copied files will drift, and there is no upgrade path for the database
`html/logon/*.html` and `config/mariadb/init.sql` are copies of modular-sanic files. They are identical to `main` today, but every modular-sanic change to those pages or the schema must be copied by hand. Batch 2 already changed which HTTP methods the pages use, for example. `init.sql` runs only when the data directory is empty, so an existing deployment that picks up a newer modular-sanic never gets `migrate_apikey_hash.sql` or `migrate_user_collation.sql`.

**Fix.** Serve the logon pages from the image (`/app/html/logon`) and keep only site-specific pages here. Generate `init.sql` from the pinned modular-sanic ref. Document, or script, running modular-sanic's `setup/migrate_*.sql` on upgrade.

#### M-7. The nginx image comes from `dhi.io` (unverified here)
`docker-compose.yml:3`. Docker Hardened Images are served from `dhi.io`, which normally needs `docker login dhi.io` with a Docker account. A user who hasn't logged in gets a pull failure on the very first `docker compose up`. I could not confirm whether its non-root nginx (uid 65532) loads `/etc/nginx/conf.d/default.conf` and binds 80/443 the way the stock image does, because the host is blocked here.

**Fix.** Document the login step, or default to `nginx:1` (or `nginxinc/nginx-unprivileged`) with the hardened image as an option. Test the hardened image's config path and ports.

#### M-8. API documentation is public, and weak default secrets ship in the example **[verified]**
`env-example:11` sets `DOCUMENTATION=True`, and nginx forwards `/docs` (`default.conf:40-46`). `/docs`, `/docs/swagger` and `/docs/openapi.json` return 200 to anyone. `env-example:21-22` and `docker-compose.yml:35-36` ship `apppasswd`, `apppassword` and `rootpass`.

**Fix.** Default `DOCUMENTATION=False`, or restrict `/docs` (for example `allow`/`deny`, or `auth_request`). Have `setup.sh` generate random `DB_PASS` and `DB_ROOT_PASSWORD` into `.env`.

#### M-9. No README
The repo has no instructions covering:
- the steps (`./setup.sh`, `cp env-example .env`, edit `.env`, `docker compose up -d`);
- the `dhi.io` login (M-7);
- the PAM requirements (H-1, H-2);
- where endpoint files go and which prefixes reach them (M-3);
- how to create the first admin (L-7);
- upgrades and migrations (M-6).

**Fix.** Add a README covering these, and link to modular-sanic's README for the endpoint-authoring guide.

#### M-10. memcached is allowed more memory than the host has, and images are unpinned **[verified]**
`docker-compose.yml:63` uses `-m 32768 -I 512M -t 16`. `stats settings` showed `maxbytes 34359738368` (32 GB) on a 15 GB host, with 512 MB items allowed. Sessions are tiny, but nothing stops memcached growing until the host swaps or the OOM killer acts. `memcached:latest` and `mariadb:12-ubi10` (a short-support rolling release) aren't pinned.

**Fix.** Use something like `-m 256` (or `${MEMCACHED_MB:-256}`), drop `-I 512M` unless large objects are deliberately cached, and pin the image versions. Consider MariaDB 11.8 LTS.

### LOW

| ID | Location | Issue | Fix |
|---|---|---|---|
| L-1 | `setup.sh:10-15` | The self-signed certificate has only `CN=localhost` and no `subjectAltName` **[verified]**. Browsers reject CN-only certificates for any name, and Sanic's own TLS loader refuses them. | Add `-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`, and allow `SSL_NAMES` from `.env`. |
| L-2 | `default.conf:6` | `return 302 https://$host$request_uri` drops the port, so `WEB_SECURE` values other than 443 redirect to the wrong port. A temporary 302 is used for a permanent redirect. | Use `return 301 https://$host:${WEB_SECURE}$request_uri` via an envsubst template, or document that 443 is required. |
| L-3 | `default.conf`, `docker-compose.yml:2-20` | nginx shows its version in headers and error pages (`nginx/1.31.7`) **[verified]**. nginx has no `restart:` policy, so it doesn't come back after a reboot. `api` and `nginx` have no health checks; nginx starts before the API is ready (502s). | `server_tokens off;`, `restart: unless-stopped`, an API health check (`GET /auth/info`) with `depends_on: condition: service_healthy`. |
| L-4 | `env-example:3,23`, `docker-compose.yml:31,87`, `default.conf:31` | `API_PORT` and `DB_PORT` appear configurable but aren't wired through. Sanic always listens on 8000 and nginx hard-codes `api:8000`. MariaDB always listens on 3306 while the app connects to `DB_PORT`. | Pass `--port=${API_PORT}` and template nginx, or remove the variables. |
| L-5 | `html/index.html`, `env-example:6` | After logon, users are sent to `/index.html`, a "down for maintenance" page **[verified]**. | Ship a real landing page, or point `REDIRECT_LOGON_SUCCESSFUL` at `/logon/index.html`. |
| L-6 | `env-example:4`; `html/logon/index.html` | The bundled pages link to the API key, key file, email challenge, su and return pages, but those endpoints aren't enabled by the default `API_LOCATIONS`, so those pages fail. | Enable them, or note in `env-example` which pages need which locations. |
| L-7 | `config/mariadb/init.sql` | There is no way to create the first administrator. | Optionally insert `ADMIN_USER` from `.env` with `admin/permissions` and `admin/become` in an init script. |
| L-8 | `setup.sh` | No `set -e`. Uses `sudo` for every step, including `chmod` of `.git`. Must be run from the repo root. The `chown 65532` only suits the hardened nginx image. | `set -euo pipefail`, `cd "$(dirname "$0")"`, limit `sudo` to the `chown`s. |
| L-9 | `docker-compose.yml:90` | `TZ` is set only on the API container (MariaDB runs in UTC). Not a correctness issue today, because all expiry comparisons happen inside the database, but logs disagree. | Set the same `TZ` on every service, or none. |

---

## 3. Prioritized top 10

1. **H-1, then H-2.** Make logon possible: add the shadow group so PAM works, and decide how much host-password exposure is acceptable. A dedicated PAM service or container-local accounts, or enabling API-key logon, are safer.
2. **H-3.** Set `SANIC_PROXIES_COUNT=1` in the API service's compose `environment:`. Without it, one person can lock every user out and HSTS is never sent.
3. **H-4.** Make the first run foolproof: `setup.sh` creates `.env` and `./api`, and the compose defaults match `env-example`, or compose fails without them.
4. **H-5.** Stop `setup.sh` from chmod-ing `data/`, and lock down `.env`.
5. **M-1.** Get the security headers onto the nginx-served pages, or let Sanic serve them.
6. **M-2.** Put `/ram` behind authentication (or make it `internal`) and turn off `autoindex`.
7. **M-3.** Forward every non-static path to Sanic, or document the `/api` prefix rule; create `./api` in `setup.sh`.
8. **M-4 and M-5.** Production-style default command (workers, no debug), and a pinned, cache-correct modular-sanic ref in the Dockerfile.
9. **M-9 and M-7.** Write a README, including the `dhi.io` login or a fallback nginx image.
10. **M-6, M-8 and M-10.** Plan for drift and migrations, close `/docs` and use generated secrets, and right-size and pin memcached and MariaDB.

---

## 4. Finding for modular-sanic itself

**`SANIC_*` settings in `.env` are ignored [verified].** environs 15 loads `.env` into the `Env` object only. Sanic builds its config from `os.environ` when `Sanic(...)` is created, so `SANIC_PROXIES_COUNT` / `SANIC_REAL_IP_HEADER` / `SANIC_FORWARDED_SECRET` set in `.env` never take effect. modular-sanic's README ("in the environment or `.env`") and `env-example` currently say they do. That instruction came from its batch 3 PR, and only the real environment variable was tested then.

**Fix in modular-sanic `server.py`.** Copy the `SANIC_` keys into the process environment before `Sanic(...)` is created, for example:

```python
for key, value in dotenv_values().items():
    if key.startswith('SANIC_') and value is not None:
        os.environ.setdefault(key, value)
```

Or apply them to `app.config` after creation. Then correct the README.
