# Building the Photoframe Image

This branch produces a Raspberry Pi OS Bookworm Lite image with the photoframe application pre-installed.

## Prerequisites

- Docker Desktop (Windows/Mac) or Docker Engine (Linux)
- WSL 2 backend enabled (Windows only)
- Git

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

Edit `config` if you need to change the photoframe branch:

```
IMG_NAME='PHOTOFRAME'
RELEASE=bookworm
PHOTOFRAME_BRANCH=clean_ex_display_upgrade
ENABLE_SSH=1
```

`PHOTOFRAME_BRANCH` controls which branch of the [photoframe repository](https://github.com/dev-brewery/photoframe) is cloned into the image.

### 3. Skip desktop stages

The photoframe image is based on Raspbian Lite (stage 2 only). Create empty SKIP files to exclude the desktop and extras stages:

```bash
touch stage3/SKIP stage4/SKIP stage5/SKIP
```

### 4. Build with Docker

```bash
./build-docker.sh
```

The build takes 30-60 minutes depending on your machine. The finished image will be in the `deploy/` directory.

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
