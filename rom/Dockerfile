FROM debian:trixie

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential uuid-dev nasm acpica-tools python3 python-is-python3 git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
