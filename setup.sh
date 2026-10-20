#!/bin/bash
# Prepare a checkout for "docker compose up": .env, directories, permissions
# and a self-signed certificate.  Safe to re-run on a live deployment.
set -euo pipefail
cd "$(dirname "$0")"

# .env holds the settings and passwords.  Docker creates a directory if the
# file is missing when the containers start, so create it first.
if [ -d .env ]; then
    echo ".env is a directory (created by docker compose before .env existed)."
    echo "Remove it with 'sudo rmdir .env' and run ./setup.sh again."
    exit 1
fi
if [ ! -f .env ]; then
    cp env-example .env
    echo "Created .env from env-example: set DB_PASS and DB_ROOT_PASSWORD before starting."
fi

# Repository files only: never touch data/ (MariaDB sets its own modes) or the
# certificate files handled below.
find . \( -path ./data -o -path ./.git -o -path ./config/ssl -o -path ./.env \) -prune -o -type d -exec chmod 755 {} +
find . \( -path ./data -o -path ./.git -o -path ./config/ssl -o -path ./.env \) -prune -o -type f -exec chmod 644 {} +
find . \( -path ./data -o -path ./.git -o -path ./config/ssl -o -path ./.env \) -prune -o -type f -iname '*.sh' -exec chmod 755 {} +

# The api container runs as 1000:1000 and reads .env: readable by you and
# group 1000 only.
sudo chown "$(id -u):1000" .env
chmod 640 .env

# Endpoint files for the api container (mounted at /app/external)
mkdir -p api data/mariadb/audit data/mariadb/db config/ssl
sudo chown 999:999 data/mariadb/db data/mariadb/audit

# Self-signed certificate for nginx.  SSL_NAMES sets the subjectAltName
# entries browsers check; delete config/ssl/bundle.* to make a new one.
SSL_NAMES="${SSL_NAMES:-DNS:localhost,IP:127.0.0.1}"
if [ ! -f "config/ssl/bundle.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "config/ssl/bundle.key" \
        -out "config/ssl/bundle.crt" \
        -subj "/C=US/ST=State/L=City/O=Development/CN=localhost" \
        -addext "subjectAltName=${SSL_NAMES}"
fi

sudo chmod 600 config/ssl/*.key
sudo chmod 644 config/ssl/*.crt
sudo chown 65532:65532 config/ssl/*.key config/ssl/*.crt
