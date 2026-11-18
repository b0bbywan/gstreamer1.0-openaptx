# syntax=docker/dockerfile:1
#
# Builds the openaptx GStreamer plugin natively per target, under QEMU binfmt
# where the runner is not already that arch.
#
# Trixie only, unlike odio-ci/images/pins.env (bookworm): a GStreamer plugin is
# tied to the GStreamer of the distribution it is built on, so there is no
# "one glibc floor for both releases" to be had here. Trixie ships 1.26.2 and
# keeps it for its whole lifetime.
#
# The source is not fetched from upstream: `apt-get source` takes the
# gst-plugins-bad1.0 of the target distribution, with whatever Debian (and, on
# armhf, Raspberry Pi) patched into it.
#
# armv6 has no Debian port, hence the pinned Raspberry Pi OS rootfs
# (https://github.com/vascoguita/raspios-docker): Debian's armhf gcc defaults
# to ARMv7 and the result would SIGILL on a Pi 1 / Zero.
FROM --platform=linux/amd64  debian:trixie-slim AS base-amd64
FROM --platform=linux/arm64  debian:trixie-slim AS base-arm64
FROM --platform=linux/arm/v6 vascoguita/raspios:armhf-trixie-2026-06-19@sha256:89416baadb6cdb75c874fa696bcf51ab47d76b217fea9b635c86c61083b84d52 AS base-armv6

# ── Builder ────────────────────────────────────────────────────────────────
ARG TARGETARCH
ARG TARGETVARIANT
FROM base-${TARGETARCH}${TARGETVARIANT} AS builder

# Upstream GStreamer version the package is for (from the repo tag). The build
# fails if the distribution's source is anything else.
ARG GST_VERSION
# Full package version, stamped into the plugin's metadata.
ARG PKG_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# Both images use deb822 .sources files; enabling deb-src is the same edit.
# g++ although the plugin is pure C: plugins-bad's project() declares cpp, and
# meson refuses to configure without a C++ compiler.
# gstreamer1.0-tools and gstreamer1.0-plugins-base are only for the smoke test
# (gst-inspect, audiotestsrc); the export stage leaves them behind.
RUN set -eux; \
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/*.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates dpkg-dev gcc g++ libc6-dev meson ninja-build pkgconf \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libfreeaptx-dev \
      gstreamer1.0-tools gstreamer1.0-plugins-base

WORKDIR /build

RUN set -eux; \
    test -n "${GST_VERSION}" || { echo "ERROR: GST_VERSION build-arg is required" >&2; exit 1; }; \
    apt-get source --only-source gst-plugins-bad1.0; \
    src="gst-plugins-bad1.0-${GST_VERSION}"; \
    if [ ! -d "${src}" ]; then \
      echo "ERROR: the distribution ships gst-plugins-bad1.0 $(ls -d gst-plugins-bad1.0-*/ | sed 's/^gst-plugins-bad1.0-//; s:/$::'), not ${GST_VERSION}" >&2; \
      echo "       tag this repo with the version the distribution actually has" >&2; \
      exit 1; \
    fi; \
    echo "=== source: gst-plugins-bad1.0 $(dpkg-parsechangelog -l "${src}/debian/changelog" -S Version) ==="; \
    mv "${src}" src

# Debian's hardening flags, as dpkg-buildpackage would set them. Everything is
# disabled except openaptx, and only that target is built: plugins-bad also
# builds a dozen internal libraries unconditionally, none of which the plugin
# links (it needs gstaudio and libfreeaptx, nothing from gst-libs/).
RUN set -eux; \
    eval "$(dpkg-buildflags --export=sh)"; \
    meson setup _build src \
      --buildtype=plain --wrap-mode=nodownload \
      -Dauto_features=disabled -Dopenaptx=enabled \
      -Dexamples=disabled -Dtools=disabled -Dtests=disabled \
      -Dintrospection=disabled -Dnls=disabled -Dorc=disabled -Ddoc=disabled \
      -Dpackage-name="gstreamer1.0-openaptx ${PKG_VERSION} (Odio)" \
      -Dpackage-origin="https://apt.odio.love"; \
    ninja -C _build ext/openaptx/libgstopenaptx.so; \
    \
    mkdir -p /out; \
    install -m 0644 _build/ext/openaptx/libgstopenaptx.so /out/libgstopenaptx.so; \
    strip --strip-unneeded --remove-section=.comment --remove-section=.note /out/libgstopenaptx.so; \
    \
    { echo "Built from gst-plugins-bad1.0 $(dpkg-parsechangelog -l src/debian/changelog -S Version)"; \
      echo "($(. /etc/os-release; echo "${PRETTY_NAME}"), $(dpkg --print-architecture))."; \
      echo; \
      echo "Only ext/openaptx/ is compiled; see the copyright file for its licence."; \
    } > /out/README; \
    \
    echo "=== shared libraries required (cross-check packaging/nfpm.yaml) ==="; \
    objdump -p /out/libgstopenaptx.so | sed -n 's/^ *NEEDED *//p' | sort

# Native (or QEMU) execution: does GStreamer actually load it, and do both
# elements work? A private registry so the cached one cannot mask a failure.
RUN set -eux; \
    export GST_PLUGIN_PATH=/out GST_REGISTRY=/tmp/gst-registry.bin; \
    gst-inspect-1.0 openaptx | tee /tmp/inspect; \
    grep -q 'Filename *\/out\/libgstopenaptx.so' /tmp/inspect; \
    gst-launch-1.0 -q audiotestsrc num-buffers=100 \
      ! audio/x-raw,format=S24LE,rate=48000,channels=2 \
      ! openaptxenc ! audio/aptx ! openaptxdec ! fakesink; \
    gst-launch-1.0 -q audiotestsrc num-buffers=100 \
      ! audio/x-raw,format=S24LE,rate=48000,channels=2 \
      ! openaptxenc ! audio/aptx-hd ! openaptxdec ! fakesink; \
    echo "smoke: aptX and aptX HD round-trips ok"

# Export: the relative paths packaging/nfpm.yaml expects.
FROM scratch AS export
COPY --from=builder /out/ /
