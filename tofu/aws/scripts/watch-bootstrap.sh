#!/usr/bin/env bash
set -euo pipefail

journalctl -u amazon-init -n 80 --no-pager || true
journalctl -u bootstrap-leonix-v3 -f
