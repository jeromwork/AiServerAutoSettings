FROM ubuntu:24.04 AS vps
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv openssh-server && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

FROM vps AS fixture
RUN apt-get update && apt-get install -y python3 curl ca-certificates jq iproute2 nftables openssl openvpn sudo && rm -rf /var/lib/apt/lists/*

# Dedicated offline Happier Web acceptance, no provider/GitHub calls at runtime.
FROM fixture AS happier-web
RUN apt-get update && apt-get install -y --no-install-recommends nodejs git dbus-user-session libpam-systemd python3-cryptography && rm -rf /var/lib/apt/lists/*
