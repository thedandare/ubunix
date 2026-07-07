#!/usr/bin/env bash
set -euo pipefail

systemctl status sshd --no-pager || true
systemctl status bootstrap-leonix-v3 --no-pager || true
systemctl status incus --no-pager || true
systemctl status incus-preseed --no-pager || true
systemctl status init-incus-leonk8s --no-pager || true
ss -lntp | grep -E ':(22|2409)' || true
incus list || true
