# Building the Photoframe Image (Lite or Desktop)

This branch produces a Raspberry Pi OS Bookworm Lite image with the photoframe application pre-installed.

## Prerequisites

- Docker Desktop (Windows/Mac) **or** Docker Engine (Linux), with the ability to run privileged containers
- WSL 2 backend enabled (Windows only)
- Git

That's it. You do **not** need `qemu-user-static`, `binfmt_misc`, `quilt`,
`debootstrap`, or any other build dependency installed on the host. The
pi-gen Docker image carries everything the build needs, and registers
binfmt_misc handlers from inside the container under `--privileged`.

If you prefer a native (non-Docker) build, use `./build.sh` instead — that
pathway has its own host dependency requirements documented in `depends`.

## Build Steps

### 1. Clone this repository

```bash
git clone -b bookworm-photoframe https://github.com/dev-brewery/pi-gen.git
cd pi-gen
```

### 2. Create the config file

Copy the example config:

```bash
cp config.example config
```

Edit `config` if you need to build against a different photoframe ref:

```
IMG_NAME='PHOTOFRAME'
RELEASE=bookworm
PHOTOFRAME_BRANCH=v3.0.0-rc1
ENABLE_SSH=1
PHOTOFRAME_TARGET=lite
```

`PHOTOFRAME_BRANCH` names the photoframe ref (a release tag, or any branch/SHA git accepts) that gets cloned into the image at build time. The default is the photoframe release tag paired with this pi-gen tag — so `git clone --branch vX.Y.Z pi-gen && cp config.example config && ./build-docker.sh` reproduces the matching release image with zero overrides. Override to build against a feature branch or unreleased commit.

See [`RELEASE.md`](RELEASE.md) for the release-cadence contract between photoframe and pi-gen.

`PHOTOFRAME_TARGET` selects the build target. Valid values:

- `lite` (default) — Raspberry Pi OS Lite + photoframe. The framebuffer
  is owned by photoframe end-to-end (no display manager). Single ~810 MB
  image, ~50 min build.
- `desktop` — Raspberry Pi OS Desktop (stage4) + photoframe. lightdm is
  installed but frame.service stops it at boot, so photoframe still owns
  the screen by default. The desktop is reachable as a fallback by
  stopping frame.service. Produces both the Desktop image (~1.7 GB) and
  the Lite image (~810 MB), as pi-gen naturally exports an image at the
  end of each stage that has an `EXPORT_IMAGE` file. ~80-100 min build.

To build a desktop image, pass `desktop` to `build-docker.sh`:

```bash
./build-docker.sh desktop
```

### 3. Skip desktop stages

The photoframe image is based on Raspbian Lite (stage 2 only). Create empty SKIP files to exclude the desktop and extras stages:

```bash
touch stage3/SKIP stage4/SKIP stage5/SKIP
```

> **Note (v3.0.0+):** The SKIP files for stages 3-5 are now committed in
> the repository by default, so this manual step is no longer required for
> Lite builds. For Desktop builds, `build-docker.sh` removes the stage3/4
> SKIP files automatically when `desktop` is passed as an argument, and
> restores them on exit. You should not need to touch SKIP files manually
> unless you have deleted them from your working tree.

### 4. Build with Docker

```bash
./build-docker.sh
```

The build takes 30-60 minutes depending on your machine. The finished image will be in the `deploy/` directory.
A `lite` build takes ~50 minutes; a `desktop` build takes ~80-100 minutes.

### 5. Flash the image

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash the image from `deploy/` to an SD card. In the Imager settings dialog, configure:

- WiFi network name and password
- Hostname (e.g., `photoframe`)
- Username and password

These settings are applied automatically on first boot.

### 6. Boot

Insert the SD card into the Pi and power on. The photoframe service starts automatically. The web configuration interface is available at `http://<hostname>:7777` with default credentials `photoframe` / `password`.

## Build on Windows (PowerShell)

```powershell
git clone -b bookworm-photoframe https://github.com/dev-brewery/pi-gen.git
cd pi-gen
Copy-Item config.example config
New-Item -ItemType File stage3/SKIP, stage4/SKIP, stage5/SKIP
bash ./build-docker.sh
```

> **Note (v3.0.0+):** The SKIP files are now committed in the repository,
> so the `New-Item` line above is no longer required. For Desktop builds,
> pass `desktop` to the build script: `bash ./build-docker.sh desktop`

## Rebuilding after changes

To rebuild after modifying the photoframe stage:

```bash
PRESERVE_CONTAINER=1 CONTINUE=1 ./build-docker.sh
```

To do a clean rebuild:

```bash
docker rm -v pigen_work
./build-docker.sh
```
