FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y systemd systemd-sysv openssh-server python3 curl ca-certificates jq iproute2 nftables openssl openvpn sudo && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
