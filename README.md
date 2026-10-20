# modular-sanic-docker

Docker Compose deployment of [Modular Sanic](https://github.com/jskenney/modular-sanic) for easy deployment and testing:

| Service | Image | Role |
|---|---|---|
| `nginx` | `dhi.io/nginx:1` | TLS on 443 (HTTP 80 redirects), serves `./html`, proxies `/auth`, `/api` and `/docs` to the api, serves the shared RAM disk at `/ram` |
| `api` | built from `config/sanic/Dockerfile` | Modular Sanic (cloned from GitHub at build time), runs as uid/gid 1000 |
| `mariadb` | `mariadb:12-ubi10` | Authentication tables (`config/mariadb/init.sql`) and application data, with server audit logging |
| `memcached` | `memcached:latest` | Sessions and logon rate limits |

Only nginx is published on the host. MariaDB, memcached and the api are reachable only on the compose network.

## Requirements

- Docker with the Compose plugin (`docker compose`), and `sudo` (for the ownership changes in `setup.sh`).
- **The nginx image is a Docker Hardened Image.** Pulling it needs a Docker account: run `docker login dhi.io` once. To use the Docker Hub image instead, change `image: dhi.io/nginx:1` to `image: nginx:1` in `docker-compose.yml`.

## Quick start

```bash
./setup.sh                 # creates .env, ./api, data directories and a self-signed certificate
nano .env                  # set DB_PASS, DB_ROOT_PASSWORD, TZ and SHADOW_GID (see below)
docker compose up -d --build
```

Then browse to `https://localhost` (accept the self-signed certificate) and log on at `https://localhost/logon/logon.html`.

Notes:

- **Set the passwords before the first start.** MariaDB only applies `DB_USER`/`DB_PASS`/`DB_ROOT_PASSWORD` when it creates `data/mariadb/db`. Changing them later means changing them inside MariaDB too, or starting over (see [Resetting](#resetting)). `docker compose` refuses to start while `DB_PASS` or `DB_ROOT_PASSWORD` is unset.
- **Re-running `./setup.sh` is safe.** It keeps an existing `.env` and certificate, and it doesn't change the database files' permissions.
- **The certificate** covers `localhost` and `127.0.0.1`. For other names, delete `config/ssl/bundle.*` and run, for example, `SSL_NAMES="DNS:app.example.com,DNS:localhost" ./setup.sh`. Use a real certificate (copied to `config/ssl/bundle.crt` and `bundle.key`) for anything public.

## Logging on (PAM)

`env-example` enables `api/auth/general` and `api/auth/pam`, so users log on with an account on the **host** (username and password checked by PAM):

- The api container mounts the host's `/etc/passwd`, `/etc/group` and `/etc/shadow` (read-only).
- It runs with the host's `shadow` group (`SHADOW_GID`, 42 on Debian/Ubuntu; check with `getent group shadow`) so PAM can read `/etc/shadow`.

> **Security:** this lets the api container, *and every endpoint file it loads from `./api`*, read the host's password hashes. Keep `./api` writable only by trusted users. For anything beyond testing, prefer another logon method: remove `api/auth/pam` from `API_LOCATIONS`, remove the `/etc/shadow` mount and `group_add` from `docker-compose.yml`, and enable `api/auth/apikey` and/or `api/auth/email` instead (see the commented `API_LOCATIONS` line in `env-example`).

### Creating the first administrator

Log on once (this creates your `sanic_info` row), then grant yourself the admin rights:

```bash
docker compose exec mariadb sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' <<'SQL'
INSERT INTO sanic_access (user, access, value) VALUES
  ('alice', 'admin', 'permissions'),
  ('alice', 'admin', 'become');
SQL
```

User names are case-sensitive. Access changes apply immediately. See the Modular Sanic README for what each right allows.

## Adding endpoints

Put endpoint files (Python files defining `sub_bp = Blueprint(...)`) in `./api`. It is mounted at `/app/external`, which `API_LOCATIONS` includes. See the [Modular Sanic README](https://github.com/jskenney/modular-sanic#writing-an-endpoint) for how to write one.

- **Use a `url_prefix` that starts with `/api`.** nginx only forwards `/auth`, `/api` and `/docs` to the api container; any other path is looked up in `./html`.
- **Restart after adding a file.** Edits to existing files reload automatically, but new files are picked up when the api restarts: `docker compose restart api`.

## Configuration

Settings live in `.env` (created from `env-example`). Compose reads it for the values below, and the api container reads it for Modular Sanic's own settings (see the [Modular Sanic configuration table](https://github.com/jskenney/modular-sanic#configuration)).

| Variable | Used by | Purpose |
|---|---|---|
| `DB_NAME`, `DB_USER`, `DB_PASS`, `DB_ROOT_PASSWORD` | mariadb, api | Database name and credentials. The two passwords are required. |
| `DB_HOST`, `MEMCACHED_HOST` | api | Service names on the compose network (`mariadb`, `memcached`) |
| `API_LOCATIONS` | api | Endpoint directories (`external` is `./api`) |
| `WEB_UNSECURE`, `WEB_SECURE` | nginx | Host ports for HTTP and HTTPS (the HTTP redirect assumes HTTPS is on 443) |
| `TZ` | all | Time zone for every container |
| `SHADOW_GID` | api | Host group that can read `/etc/shadow` (PAM logons) |
| `RAMDISK` | volume | Size of the shared RAM disk |
| `DOCUMENTATION` | api | Serve the generated API documentation at `/docs` (public through nginx) |

`docker-compose.yml` sets `SANIC_PROXIES_COUNT=1` for the api, because nginx is always the one proxy in front of it. That way the logon rate limits see each client's own address, and HTTPS is detected for HSTS. Set `HSTS` in `.env` to send the header.

nginx adds security headers (Content-Security-Policy, X-Frame-Options, X-Content-Type-Options, Referrer-Policy) to the pages it serves, from `config/nginx/security-headers.conf`. Responses from the api carry Modular Sanic's own headers.

> **`/ram`** (the shared RAM disk, mounted at `/ram` in nginx and the api) is served to anyone, with a directory listing and no logon. Do not put private files there.

## Debug mode

The api runs with `--debug --reload`, which suits testing: detailed errors, and code reloads when files in `./api` change. For production, change the `command` in `docker-compose.yml` to drop those options, for example:

```yaml
command: ["python", "-m", "sanic", "server", "--host=0.0.0.0", "--workers=2"]
```

## Upgrading Modular Sanic

The api image clones Modular Sanic when it is built, and Docker caches that step, so `docker compose build` alone keeps the old copy. To pick up a newer version:

```bash
docker compose build --no-cache api && docker compose up -d
```

`config/mariadb/init.sql` (a copy of Modular Sanic's `setup/auth_tables.sql`) only runs when MariaDB creates an empty data directory. When a Modular Sanic release adds a `setup/migrate_*.sql` script, run it against the existing database, for example:

```bash
curl -fsSL https://raw.githubusercontent.com/jskenney/modular-sanic/main/setup/migrate_user_collation.sql |
  docker compose exec -T mariadb sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"'
```

The logon pages in `./html/logon` are copies of Modular Sanic's `html/logon`, so update them with the same release.

## Files

| Path | Contents |
|---|---|
| `setup.sh` | One-time (and safe to repeat) preparation |
| `env-example` → `.env` | Settings and passwords (`.env` is mode 640, readable by you and group 1000, the api container's group) |
| `config/nginx/` | nginx site configuration and security headers |
| `config/mariadb/init.sql` | Authentication tables, created on first start |
| `config/sanic/Dockerfile` | The api image |
| `config/ssl/` | `bundle.crt` and `bundle.key` (created by `setup.sh`, not committed) |
| `html/` | Static site served by nginx (and readable by the api) |
| `api/` | Your endpoint files |
| `data/mariadb/` | Database files (`db/`) and audit logs (`audit/`), not committed |

## Resetting

To start over with an empty database (**this deletes all data**):

```bash
docker compose down
sudo rm -rf data/mariadb/db && ./setup.sh
docker compose up -d
```
