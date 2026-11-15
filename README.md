# rocky9-selkies

A Rocky Linux 9 GNOME desktop with native NVIDIA OpenGL, running in a rootless
Podman container and streamed to a browser with [Selkies](https://github.com/selkies-project/selkies).

It gives you a real X11 session on Rocky 9 from a newer host distro, without a
virtual machine and without GPU passthrough. Applications inside the container
render on the host's NVIDIA GPU, and the desktop is encoded with NVENC.

The original motivation was running VFX software that targets RHEL 9 and X11
on a Fedora workstation.

## Status

Working, but young. It was built and tested on one machine:

| Component | Version tested |
|---|---|
| Host | Fedora 45, rootless Podman |
| NVIDIA driver (host) | 620.70.06 |
| NVIDIA Container Toolkit | 1.20.2 (CDI) |
| GPU | GeForce RTX 3060 Ti |
| Container | Rocky Linux 9 |
| Selkies | 2.2.1 (from PyPI) |
| X server | XLibre Xvfb 25.2.2 (built from source) |

Other hosts, drivers and GPUs may need changes. Reports are welcome.

## What you get

- Rocky 9 with systemd as init and a GNOME X11 session registered with logind
- OpenGL from the NVIDIA driver (`glxinfo` reports `NVIDIA Corporation`), no `vglrun` wrapper
- H.264 encoding on NVENC with zero-copy capture from the X server
- A desktop that resizes to the browser window
- A persistent home directory in a named volume

## How it works

Three problems had to be solved to get a GPU desktop on Rocky 9 this way.

**1. Rocky 9's Xvfb cannot use the GPU.**
The stock `xorg-x11-server-Xvfb` is from the 1.20 series and has no glamor
support. The official Selkies desktop images solve this by shipping an Xvfb
built from [XLibre](https://github.com/X11Libre/xserver), which accepts
`-glamor -dri /dev/dri/renderDxxx`. This repo builds the same Xvfb on Rocky 9
in a build stage and installs it under `/opt/xlibre`. It builds against stock
el9 `-devel` packages.

**2. The host's NVIDIA helper libraries do not load on el9.**
CDI mounts the host's NVIDIA userspace into the container. NVIDIA's own
binaries run fine on old systems, but the small open-source helpers
(`libnvidia-egl-gbm`, `libnvidia-egl-wayland`, and friends) are compiled by the
host distro against its own glibc. On a Fedora host they need a newer glibc
than Rocky 9 has, so EGL on GBM fails with `Failed to create EGL display`.
The fix is to unpack EPEL 9's `egl-gbm` under `/opt/nvidia-el9` and point
NVIDIA's EGL at it with `__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES`.

**3. Rootless Podman maps the container user to a sub-uid.**
That uid cannot open the GPU device nodes. Running with
`--userns=keep-id:uid=1000,gid=1000` makes uid 1000 in the container your real
host user.

Two smaller details:

- GLX clients pick Mesa by default on this X server, so the session exports
  `__GLX_VENDOR_LIBRARY_NAME=nvidia`.
- Xvfb treats its startup screen size as the maximum, so it is started with
  `-screen 0 7680x4320x24` and Selkies sizes the real screen to the browser.

## Layout

```
.
├── Containerfile        stage 1: Rocky 9 + systemd + XLibre Xvfb + Selkies + openbox
├── gpu.env              environment shared by the services
├── tmpfiles.conf
├── start-xvfb           starts Xvfb on the first render node it finds
├── wait-x               waits until the X display answers
├── start-session        stage 1 session (openbox + xterm)
├── xvfb.service
├── selkies.service
├── session.service
├── selkies.env.example  web login for Selkies; copy to selkies.env
└── gnome/               stage 2: GNOME session on top of the stage 1 image
```

Stage 2 is a separate image built `FROM` stage 1, so the base stays small and
can be tested alone.

## Requirements

- An NVIDIA GPU with the proprietary driver on the host
- Podman (rootless)
- NVIDIA Container Toolkit with a CDI specification:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

- Your host user must be uid 1000, or you need to adjust the `keep-id` mapping
  and the `useradd -u 1000` line in the Containerfile.

## Build

```bash
git clone https://github.com/ilbozo/rocky9-selkies.git rocky9-selkies && cd rocky9-selkies
cp selkies.env.example selkies.env      # then set your own password

podman build -t rocky9-selkies:stage1 .
podman build -t rocky9-selkies:stage2 -f gnome/Containerfile gnome/
```

The first build compiles Xvfb and takes a few minutes.

## Run

```bash
podman run -d --name rocky9 \
  --systemd=always \
  --userns=keep-id:uid=1000,gid=1000 --user 0:0 \
  --device nvidia.com/gpu=0 \
  --security-opt label=disable \
  --shm-size=2g \
  -v rocky9-home:/home/rocky \
  -v "$PWD/selkies.env":/etc/selkies/selkies.env:ro \
  -p 127.0.0.1:8080:8080 \
  rocky9-selkies:stage2
```

Open <http://localhost:8080> and log in with the user and password from
`selkies.env`.

To run the minimal stage 1 desktop instead, use the `rocky9-selkies:stage1`
image with the same command.

### Options

| What | Where |
|---|---|
| Web login | `selkies.env` (`SELKIES_BASIC_AUTH_USER`, `SELKIES_BASIC_AUTH_PASSWORD`) |
| Which GPU | `--device nvidia.com/gpu=0`; list names with `nvidia-ctk cdi list`, or use `all` |
| Home directory | `-v rocky9-home:/home/rocky` (named volume); a host folder also works |
| Port | `-p 127.0.0.1:8080:8080` |
| Other Selkies settings | add `SELKIES_*` variables to `selkies.env`; see `selkies --help` |

`--security-opt label=disable` is there because SELinux otherwise blocks access
to the GPU devices from the container.

## Checking that it works

```bash
podman exec rocky9 systemctl --no-pager --failed
podman exec rocky9 systemctl --no-pager status xvfb selkies session | grep -E "●|Active:"
podman exec rocky9 journalctl --no-pager -u xvfb -n 20
podman exec rocky9 journalctl --no-pager -u selkies -n 40
```

Good signs:

- Xvfb log: `DRI3 X acceleration enabled on NVIDIA ...`
- Selkies log: `Encoder: NVENC H264 ...` and `Zero-copy capture (DRI3)`
- In a terminal inside the desktop:

```bash
glxinfo -B | grep -E "vendor string|renderer string"
```

should print `NVIDIA Corporation` and your GPU.

## Troubleshooting

**"Waiting for stream…" in the browser.**
Look at the Selkies journal. If it cannot create a display mode, check that
`cvt`, `gtf` and `xrandr` exist in the image (on el9, `cvt` and `gtf` come from
`xorg-x11-server-Xorg`).

**The desktop stays small in the middle of the window.**
Xvfb's maximum screen size is too small. Check the `-screen` option in
`start-xvfb`.

**`glxinfo` shows `llvmpipe`.**
`__GLX_VENDOR_LIBRARY_NAME=nvidia` is not set for that process, or Xvfb did not
start with `-glamor`. Check the Xvfb journal.

**`Failed to create EGL display` from `selkies gpu-probe`.**
The el9 `egl-gbm` override is not in effect. Check that
`__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES` points to
`/opt/nvidia-el9/15_nvidia_gbm.json`.

**GNOME asks for a password to "create a color managed device".**
The polkit rule in `gnome/polkit-colord.rules` allows this for the session
user. Check that it was copied into the image.

**The container stops seeing the GPU after a host driver update.**
Regenerate the CDI specification on the host, then recreate the container.

## Known limitations

- Applications that use EGL directly on X11 (instead of GLX) render in
  software, because the `egl-xcb` and `egl-xlib` helpers have no el9 package.
- Audio is switched off (`SELKIES_AUDIO_ENABLED=false`). PipeWire is installed
  in the GNOME image but not wired up yet.
- The web client is served over plain HTTP and published on `127.0.0.1` only.
  Put TLS in front of it before exposing it to a network.
- The session user has no password. Screen locking, idle blanking and suspend
  are disabled through dconf defaults.
- GNOME logs warnings about hardware it cannot find in a container (rfkill,
  EDID, USB guard). They are harmless.
- The Xvfb build and the `egl-gbm` override are loosely tied to the host
  driver. A large driver jump may need a retest.
- No software from third-party vendors is included. Application stages (for
  example a DCC installed from your own licensed installer) are meant to live
  in their own folders, built `FROM` the stage 2 image.

## Credits

- [Selkies](https://github.com/selkies-project/selkies) for the streaming
  server and for the container design this follows
- [XLibre](https://github.com/X11Libre/xserver) for an Xvfb with glamor and DRI3
- [NVIDIA egl-gbm](https://github.com/NVIDIA/egl-gbm), packaged for el9 by EPEL
