#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Build one gstreamer1.0-openaptx .deb: buildx the per-arch native builder
# image, export the plugin, run nfpm on it.
#
# Usage:
#   build-deb.sh --arch <amd64|arm64|armhf> --version <1.26.2>
#                [--gst-version 1.26.2] [--out ./dist]
#
# --gst-version is the upstream GStreamer version the distribution's source
# must have; it defaults to --version minus any ~prerelease or +suffix, so
# 1.26.2~rc1 and 1.26.2+odio1 both build 1.26.2. CI branch builds pass it
# explicitly because their version is 0.0.0+ci.<sha>.
#
# Needs docker with buildx and nfpm on the host, plus binfmt for any arch the
# host cannot run natively (docker/setup-qemu-action in CI, or
# `docker run --privileged --rm tonistiigi/binfmt --install all` locally).
#
# armhf maps to linux/arm/v6 in a Raspberry Pi OS rootfs; the package arch stays
# `armhf` because that is what dpkg reports on Pi OS armhf.

set -euo pipefail

ARCH="" VERSION="" GST_VERSION="" OUT="./dist"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)        ARCH="$2"; shift 2 ;;
    --version)     VERSION="$2"; shift 2 ;;
    --gst-version) GST_VERSION="$2"; shift 2 ;;
    --out)         OUT="$2"; shift 2 ;;
    -h|--help) sed -n '4,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "${ARCH}" ]    || die "--arch is required"
[ -n "${VERSION}" ] || die "--version is required"
[ -n "${GST_VERSION}" ] || GST_VERSION="$(echo "${VERSION}" | sed -E 's/[~+].*$//')"

case "${ARCH}" in
  amd64) PLATFORM="linux/amd64";  MULTIARCH="x86_64-linux-gnu"    ;;
  arm64) PLATFORM="linux/arm64";  MULTIARCH="aarch64-linux-gnu"   ;;
  armhf) PLATFORM="linux/arm/v6"; MULTIARCH="arm-linux-gnueabihf" ;;
  *) die "unsupported arch: ${ARCH} (expected amd64, arm64 or armhf)" ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

command -v nfpm >/dev/null || die "nfpm not found in PATH"

mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
STAGE="${OUT}/stage-${ARCH}"
# Created here: the local exporter's mkdir can be denied on SELinux hosts.
rm -rf "${STAGE}"
mkdir -p "${STAGE}"

echo "=== gstreamer1.0-openaptx ${VERSION} (GStreamer ${GST_VERSION}) → ${ARCH} (${PLATFORM}) ==="

# The context is docker/ alone: the builder takes its source from apt, not
# from this repo.
# shellcheck disable=SC2086  # BUILDX_CACHE_ARGS must be word-split
docker buildx build \
  --platform "${PLATFORM}" \
  --file docker/builder.Dockerfile \
  --build-arg "GST_VERSION=${GST_VERSION}" \
  --build-arg "PKG_VERSION=${VERSION}" \
  --target export \
  --output "type=local,dest=${STAGE}" \
  --progress plain \
  ${BUILDX_CACHE_ARGS:-} \
  docker

[ -f "${STAGE}/libgstopenaptx.so" ] || die "builder produced no libgstopenaptx.so at ${STAGE}"
cp packaging/copyright "${STAGE}/copyright"

echo "--- exported payload"
find "${STAGE}" -type f -printf '%10s  %P\n' | sort -k2

echo "--- nfpm"
DEB="${OUT}/gstreamer1.0-openaptx_${VERSION}_${ARCH}.deb"
# nfpm resolves contents[].src relative to the CWD.
( cd "${STAGE}" \
  && OPENAPTX_ARCH="${ARCH}" OPENAPTX_VERSION="${VERSION}" OPENAPTX_MULTIARCH="${MULTIARCH}" \
     nfpm package -f "${REPO_ROOT}/packaging/nfpm.yaml" -p deb -t "${DEB}" )

echo "--- package"
dpkg-deb --info "${DEB}"
dpkg-deb --contents "${DEB}"
ls -lh "${DEB}"
echo "=== done: ${DEB} ==="
