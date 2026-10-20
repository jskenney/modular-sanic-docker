# Modular Sanic Configuration

FROM python:3.14-slim

# ---- OS deps (git + build tooling for common Python wheels) ----
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates \
      build-essential gcc \
      pkg-config default-libmysqlclient-dev \
      netcat-openbsd unzip zip inotify-tools \
 && rm -rf /var/lib/apt/lists/*

# ---- runtime hygiene ----
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Clone the repo at build time
RUN git clone "https://github.com/jskenney/modular-sanic.git" /app

# Install Python deps from the repo
RUN python -m pip install --upgrade pip setuptools \
 && pip install -r requirements.txt --no-build-isolation

