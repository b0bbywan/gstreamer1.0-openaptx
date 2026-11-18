# gstreamer1.0-openaptx

Build pipeline that produces multi-arch Debian packages of the GStreamer
**openaptx** plugin — alone, without the rest of `gst-plugins-bad` — for the
[Odio APT repository](https://apt.odio.love).

This is **not a fork** — no source code is vendored here. The builder takes the
`gst-plugins-bad1.0` source package of the target distribution with
`apt-get source`, compiles only `ext/openaptx/`, and the CI publishes the
`.deb` artifacts as a GitHub Release.

## Why

PulseAudio's Bluetooth module (`module-bluez5-device`) encodes aptX and aptX HD
through GStreamer: Debian builds it with `-Dbluez5-gstreamer=enabled` and has
`pulseaudio-module-bluetooth` *recommend* `gstreamer1.0-plugins-bad` for it.
That package is heavy, and aptX needs exactly one file of it.

| | `gstreamer1.0-plugins-bad` | this repo's package |
|---|---|---|
| contents | ~200 plugins + internal libraries | `libgstopenaptx.so` |
| depends | dozens of codec/network/GL libraries | GStreamer core + base, libfreeaptx |
| `.deb` size | several MB | ~10 KB |

### Coexisting with plugins-bad: plugins-bad wins

`gstreamer1.0-plugins-bad` ships the same file (`libgstopenaptx.so`) and has
priority.

- `Conflicts: gstreamer1.0-plugins-bad`: the two packages cannot be installed
  together.
- **No `Replaces`**: this package may never overwrite plugins-bad's file.

Result:

- installing plugins-bad removes this package;
- installing this package while plugins-bad is present would remove
  plugins-bad, so the installer must skip this package when plugins-bad is
  there.

It also depends on `gstreamer1.0-plugins-base`, which nothing links: PulseAudio
builds an `appsrc ! openaptxenc ! appsink` pipeline, and `appsrc`/`appsink` live
in the "app" plugin of plugins-base. Without it aptX silently never shows up.

> **PipeWire** does not need this: its Bluetooth stack (`libspa-0.2-bluetooth`)
> links libfreeaptx directly. This package is for systems running PulseAudio.

## Architectures

| deb arch | docker platform | rootfs |
|---|---|---|
| `amd64` | `linux/amd64` | `debian:trixie-slim` |
| `arm64` | `linux/arm64` | `debian:trixie-slim` |
| `armhf` | `linux/arm/v6` | Raspberry Pi OS armhf (**trixie**) |

`armhf` is **ARMv6** (Pi 1 / Zero), built in a Raspberry Pi OS rootfs whose gcc
defaults to `armv6+fp` — Debian's armhf gcc defaults to ARMv7. CI enforces it
with odio-ci's `check-binary` (`Tag_CPU_arch: v6`).

On armhf, `apt-get source` picks Raspberry Pi's own `gst-plugins-bad1.0`
(`+rpt`) over Raspbian's, since that is what the target runs.

### Trixie only — and why not bookworm like the other odio repos

`odio-ci/images/pins.env` builds on bookworm so one package covers bookworm
*and* trixie through a low glibc floor. That does not work for a GStreamer
plugin: it is built against, and declares a dependency on, the GStreamer of its
distribution (1.22 on bookworm, 1.26 on trixie). So this repo targets trixie
only, and the package says so with `libc6 (>= 2.41)`.

## Releasing

**Tag this repo with the GStreamer version trixie ships** (`apt-cache policy
libgstreamer1.0-0`, currently 1.26.2):

```bash
git tag v1.26.2 && git push origin v1.26.2
```

The builder fails if the distribution's `gst-plugins-bad1.0` source is not that
upstream version, so a tag can never quietly package something else.

| tag | package version | source built |
|---|---|---|
| `v1.26.2` | `1.26.2` | trixie's `gst-plugins-bad1.0 1.26.2-*` |
| `v1.26.2-rc1` | `1.26.2~rc1` (prerelease → `testing`) | same |
| `v1.26.2+odio1` | `1.26.2+odio1` | same — packaging-only respin |
| branch push | `0.0.0+ci.<sha>` | `GST_DEV_VERSION`, nothing published |

There is no `watch-upstream` workflow: upstream GStreamer releases are not what
this tracks, and trixie stays on 1.26.2. A rebuild is worth it only when a
Debian/Raspberry Pi update of `gst-plugins-bad1.0` touches `ext/openaptx/`
(none of the trixie security updates so far did) — respin with a `+odioN` tag.

## Building locally

Needs docker with buildx, [nfpm](https://nfpm.goreleaser.com), and binfmt for
foreign arches (`docker run --privileged --rm tonistiigi/binfmt --install all`):

```bash
./scripts/build-deb.sh --arch arm64 --version 1.26.2
./scripts/build-deb.sh --arch armhf --version 1.26.2   # QEMU, slow
```

The builder runs a smoke test in the target rootfs before exporting anything:
`gst-inspect-1.0` loads the plugin, and an aptX and an aptX HD encode → decode
round-trip go through `gst-launch-1.0`.

## License

Everything in this repo is licensed under the
[GNU LGPL, version 2.1 or later](LICENSE) — the same text gst-plugins-bad
ships. The packaged openaptx plugin itself is LGPL-2.0-or-later, which that
text satisfies.
