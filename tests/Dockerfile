FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl openssl python3 python3-venv iproute2 \
    kmod util-linux shellcheck systemd procps && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8
WORKDIR /src
COPY . /src
CMD ["bash", "tests/integration.sh"]
