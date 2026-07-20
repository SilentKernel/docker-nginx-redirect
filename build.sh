#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")"

docker pull nginx:1.30-alpine

docker build \
  --platform linux/amd64 \
  -t silentk/nginx-redirect:latest \
  --push \
  --no-cache \
  .
