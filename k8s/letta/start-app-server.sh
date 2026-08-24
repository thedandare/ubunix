#!/bin/sh
set -eu

TOKEN_FILE=/tmp/letta-app-server-token

if [ -z "${LETTA_APP_SERVER_TOKEN:-}" ]; then
  echo "LETTA_APP_SERVER_TOKEN must be set for a non-loopback App Server" >&2
  exit 1
fi

umask 077
printf '%s' "$LETTA_APP_SERVER_TOKEN" > "$TOKEN_FILE"
unset LETTA_APP_SERVER_TOKEN

set -- letta server \
  --backend "${LETTA_BACKEND:-local}" \
  --listen "ws://0.0.0.0:${PORT:-4500}" \
  --ws-auth capability-token \
  --ws-token-file "$TOKEN_FILE"

if [ "${LETTA_OPENAI_API:-false}" = "true" ]; then
  set -- "$@" --openai-api
fi

exec "$@"
