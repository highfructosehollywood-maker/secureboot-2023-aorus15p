# Build environment for the SREP stick - same base as SREP's upstream CI (ubuntu-22.04).
# Built automatically by Build-SrepUsb.ps1; the edk2 checkout itself lives in a named
# docker volume, not in this image.
FROM ubuntu:22.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      uuid-dev \
      iasl \
      git \
      nasm \
      python3 \
      python3-setuptools \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

CMD ["bash", "/srep/build/build.sh"]
