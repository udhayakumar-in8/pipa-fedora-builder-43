# Reproducible build environment for the Ubuntu Router image.
#
#   docker build -t ubuntu-router-builder ubuntu-router/
#   docker run --rm --privileged -v /dev:/dev \
#       -v "$PWD/ubuntu-router:/build" ubuntu-router-builder [build.sh options]
FROM ubuntu:22.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        debootstrap gdisk util-linux e2fsprogs dosfstools rsync zstd xz-utils \
        ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENTRYPOINT ["/build/build.sh"]
