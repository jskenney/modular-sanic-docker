#!/bin/bash

sudo find . -type d               -exec chmod 755 {} \;
sudo find . -type f               -exec chmod 644 {} \;
sudo find . -type f -iname '*.sh' -exec chmod 755 {} \;

mkdir -p data data/mariadb data/mariadb/audit data/mariadb/db config config/ssl
sudo chown -R 999:999 data/mariadb/db data/mariadb/audit

if [ ! -f "config/ssl/bundle.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "config/ssl/bundle.key" \
        -out "config/ssl/bundle.crt" \
        -subj "/C=US/ST=State/L=City/O=Development/CN=localhost"
fi

sudo chmod 600 config/ssl/*.key
sudo chmod 644 config/ssl/*.crt
sudo chown 65532:65532 config/ssl/*.key config/ssl/*.crt

