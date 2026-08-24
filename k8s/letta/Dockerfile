ARG LETTA_CODE_IMAGE=ghcr.io/letta-ai/letta-code:latest
FROM ${LETTA_CODE_IMAGE}

COPY --chmod=0755 start-app-server.sh /usr/local/bin/start-app-server

ENV PORT=4500 \
    LETTA_BACKEND=local \
    LETTA_OPENAI_API=false

EXPOSE 4500

ENTRYPOINT ["/usr/local/bin/start-app-server"]
