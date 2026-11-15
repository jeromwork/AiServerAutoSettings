# Format reference only. deployment.method=docker is deliberately rejected.
# Build context: repository root. This image does NOT run the host network manager.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY server/ /opt/remoteagents/server/
WORKDIR /opt/remoteagents/server
CMD ["python3", "-c", "raise SystemExit('Docker deployment is not supported yet; use deployment.method=host')"]
