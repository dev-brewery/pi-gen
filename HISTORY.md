# HISTORY — the Bookworm rebuild

This document captures why the `dev-brewery/pi-gen` fork exists, what it fixes
that upstream `RPi-Distro/pi-gen` does not, and the specific gotchas we hit
producing a working Raspberry Pi OS Bookworm Lite image for the `photoframe`
application. A future maintainer merging new upstream changes needs to read
this before touching the fork-specific stages so they don't accidentally undo
things that look like bugs but are intentional workarounds.

## What this fork is

This is a downstream of [RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen)
that builds a Raspberry Pi OS **Lite** image with the
[dev-brewery/photoframe](https://github.com/dev-brewery/photoframe)
application pre-installed and configured for headless, beginner-friendly first
boot on a Pi Zero W. The build branch is `bookworm-photoframe`.

The fork targets a very specific deployment story: a non-technical user gets a
pre-built `.img.zip` from the photoframe releases page, flashes it with
Raspberry Pi Imager, edits a `wifi-config.txt` file on the boot partition in
Notepad++ on Windows, inserts the SD card into the Pi, and the photoframe comes
up on their display with WiFi connected within ~30 seconds. No SSH required
for initial setup, no Raspberry Pi Imager advanced-settings gear icon, no
manual package install. This is the shape of the product.

The fork does **not** aim to be a general-purpose Pi OS builder. Every change
it makes relative to upstream serves the photoframe-on-Pi-Zero-W target.

## Timeline

- **Pre-2024**: the original `mrworf/photoframe` repo used a pi-gen fork to
  produce images that worked on Raspberry Pi OS Bullseye. The mechanism relied
  on `wpa_supplicant.conf` for WiFi setup and `hdmi_cvt`/`hdmi_group` in
  `config.txt` for display mode forcing. This worked for years.
- **Bookworm release (2023)**: Raspberry Pi OS migrated from `wpa_supplicant`
  to NetworkManager as the default network manager, and deprecated the legacy
  `hdmi_*` options in `config.txt` in favor of KMS (the kernel mode-setting
  driver). Both the WiFi and the display mechanisms that the old fork relied
  on stopped working silently.
- **April 2026 (Track 2 rebuild)**: this commit history, starting with
  `bb8bf67` and culminating in `d7e8291`, rebuilds the fork for Bookworm.
  Validated end-to-end on 2026-04-13: a Pi Zero W driving a Toshiba laptop
  panel via an HDMI-to-LVDS adapter board boots, connects to WiFi from an
  edited `wifi-config.txt`, runs the photoframe service, and is SSH-reachable.

## Bugs we hit and how we fixed them

Each subsection names a root cause, the symptom it produced, and the fix that
landed in the fork. These are all real debugging artifacts — future maintainers
should leave them in place unless they also understand why upstream's defaults
are wrong for this fork's use case.

### 1. `stage2/04-photoframe/00-patches/01-tweak-config.diff` was malformed

**Symptom:** 45 minutes into a fresh build, `quilt push -a` inside the
photoframe patches stage rejected the patch with
`patch: **** malformed patch at line 23: @@ -33,3 +33,9 @@`. The build exited
with `Build failed` and the whole pipeline stopped.

**Root cause:** the patch file had wrong `@@` hunk headers. Multiple hunks had
starting line numbers and span counts that didn't match the upstream
`stage1/00-boot-files/files/config.txt` content they were patching. The patch
must have been authored against an older `config.txt` and never re-validated
when upstream changed.

**Fix:** regenerated the patch cleanly with `diff -u` against the current
upstream `config.txt`. The same four customizations (enable `i2c_arm`, disable
`audio`, add `disable_splash=1`, add `framebuffer_ignore_alpha=1`) now apply
with valid hunk arithmetic. Committed as `45604ea`.

**Why upstream didn't catch it:** upstream doesn't use this patch. It's
fork-specific content that was never exercised by upstream CI.

### 2. `PHOTOFRAME_BRANCH` not exported — subprocess inheritance failure

**Symptom:** after fixing the patch, the build advanced to
`stage2/04-photoframe/01-run.sh` and failed immediately with
`fatal: repository '/pi-gen/work/PHOTOFRAME/stage2/rootfs/root/photoframe' does not exist`.
The git clone in the script was failing to fetch photoframe.

**Root cause:** the script contained:

```bash
git clone -v -b ${PHOTOFRAME_BRANCH} https://github.com/dev-brewery/photoframe.git ${ROOTFS_DIR}/root/photoframe
```

`PHOTOFRAME_BRANCH` was set in `config.example` as a plain shell assignment
(`PHOTOFRAME_BRANCH=clean_ex_display_upgrade`). Upstream `build.sh` sources
the config file, which makes the variable a **shell-local** in `build.sh`'s
process, but `build.sh` only `export`s a fixed list of variables it knows
about (`RELEASE`, `IMG_NAME`, `ENABLE_SSH`, etc.) — the fork-added
`PHOTOFRAME_BRANCH` is not on that list. When `build.sh` spawns `01-run.sh`
as a subprocess, the subprocess inherits **exported** environment variables
only, and `PHOTOFRAME_BRANCH` is not one of them. The subprocess sees it as
unset.

With `${PHOTOFRAME_BRANCH}` expanding to the empty string, bash word-splitting
drops the empty token entirely:

```
git clone -v -b  https://github.com/... /pi-gen/work/...   (after expansion)
↓
git clone -v -b https://github.com/... /pi-gen/work/...
             ↑ -b consumes the URL as the branch name
                          ↑ destination path becomes the source positional arg
                            (no destination given)
```

Git tries to clone from the local path `/pi-gen/work/PHOTOFRAME/stage2/rootfs/root/photoframe`
(treating it as the source), which doesn't exist as a repo, and emits the
exact error message we saw. This latent bug had been in the fork forever —
nobody reached this line because earlier stages failed first.

**Fix:** add `export` to the variable declaration in `config.example`:

```bash
export PHOTOFRAME_BRANCH=clean_ex_display_upgrade
```

Sourced files honor the `export` keyword, so the variable becomes genuinely
exported in build.sh's process and propagates to subprocess scripts. Included
in `d7e8291`.

**Why upstream didn't catch it:** `PHOTOFRAME_BRANCH` is fork-added. Upstream
pi-gen has no knowledge of it and doesn't export it. Future fork-added
variables in `config.example` must likewise use `export` or define their
propagation some other way.

### 3. `DISABLE_FIRST_BOOT_USER_RENAME` defaults to 0, triggers the rename wizard

**Symptom:** the first successful build produced a bootable image, but on
first boot the photoframe panel showed a "Raspberry Pi — please create a user"
wizard from `userconfig.service` instead of going straight to the photoframe
display. Frustratingly, this happened even though `FIRST_USER_NAME=photoframe`
and `FIRST_USER_PASS=photoframe` were already set in `config.example` — so
the baked-in user existed, but upstream pi-gen treated it as a placeholder
to be replaced on first boot.

**Root cause:** `build.sh:207` sets
`DISABLE_FIRST_BOOT_USER_RENAME=${DISABLE_FIRST_BOOT_USER_RENAME:-0}`. The
default is `0`. With that default, `export-image/01-user-rename/01-run.sh`
runs `rename-user -f -s` in the chroot, which schedules
`userconfig.service` to run at first boot and prompt for a new username. For
a photoframe shipped with a known, documented default user, this is
completely wrong — the whole point of baking in credentials is that the user
does **not** have to create an account to get the frame running.

**Fix:** add `DISABLE_FIRST_BOOT_USER_RENAME=1` to `config.example`. This
takes the else branch in `export-image/01-user-rename/01-run.sh`, which
removes `/etc/xdg/autostart/piwiz.desktop` and skips the `rename-user`
invocation, leaving the `photoframe` user as a real first-class account.
Included in `d7e8291`.

**Why upstream didn't catch it:** upstream ships official Raspberry Pi OS
where the first-boot rename wizard is the desired user experience. For a
purpose-built appliance, the default is wrong, but upstream has no reason to
flip it.

### 4. `WPA_COUNTRY` unset — NetworkManager.state disables wireless at build time

**Symptom:** after fixing the rename wizard, the photoframe booted cleanly,
but WiFi never associated. Manual NetworkManager keyfile injection via
mounting the ext4 rootfs from WSL also didn't work: the keyfile was valid,
permissions were correct, NetworkManager was installed and enabled, but the
radio stayed off.

**Root cause:** `stage2/02-net-tweaks/01-run.sh:14-24`:

```bash
if [ -v WPA_COUNTRY ]; then
    on_chroot <<- EOF
        SUDO_USER="${FIRST_USER_NAME}" raspi-config nonint do_wifi_country "${WPA_COUNTRY}"
    EOF
elif [ -d "${ROOTFS_DIR}/var/lib/NetworkManager" ]; then
    # NetworkManager unblocks all WLAN devices by default. Prevent that:
    cat > "${ROOTFS_DIR}/var/lib/NetworkManager/NetworkManager.state" <<- EOF
        [main]
        WirelessEnabled=false
    EOF
fi
```

When `WPA_COUNTRY` is unset, the fallback branch runs and writes
`WirelessEnabled=false` to NetworkManager's persistent state file. At
runtime, NetworkManager reads this on startup and refuses to bring up the
WiFi interface, regardless of how many valid keyfiles are in
`system-connections/`. Upstream's reasoning is that without a regulatory
country set, the kernel won't let the radio transmit anyway — so disable it
at a higher level to avoid confusing error messages.

For the fork, **we always want WiFi to work**. Not setting a regulatory domain
is a symptom of a missing fork decision, not a feature.

**Fix:** add `WPA_COUNTRY=US` to `config.example` as a deliberate project
decision. The first branch of the conditional runs
`raspi-config nonint do_wifi_country US` in the chroot, which:
1. Writes `country=US` to `/etc/wpa_supplicant/wpa_supplicant.conf`
2. Runs `rfkill unblock wifi`
3. Adds `cfg80211.ieee80211_regdom=US` to `cmdline.txt` as a kernel boot
   parameter (belt and braces)

And critically, the fallback branch is NOT taken, so
`NetworkManager.state` is not written with `WirelessEnabled=false`. At
runtime, NetworkManager happily enables the radio and loads our keyfile.

Included in `d7e8291`. See also `HISTORY.md#WPA_COUNTRY-as-project-decision`
below for why US was chosen and when to revisit.

**Why upstream didn't catch it:** upstream ships a general-purpose Pi OS
where users are expected to set their own country code via raspi-config or
the Imager gear icon. For an appliance, a deliberate default is needed.

### 5. Default build produces three images, one of which actively conflicts

**Symptom:** early builds produced three `.zip` artifacts:
`PHOTOFRAME-lite.zip` (~810 MB), `PHOTOFRAME.zip` (~1.7 GB, the "normal"
Raspberry Pi OS Desktop), and `PHOTOFRAME-full.zip` (~4 GB, the Full image
with LibreOffice and friends). Each took a full export-image pass, so the
total build time was ~90 minutes for three images we didn't want.

**Root cause:** upstream pi-gen's `stage*` directory structure with
`EXPORT_IMAGE` files in stage2, stage4, and stage5 causes each of those
stages to emit its own image. Without `SKIP` / `SKIP_IMAGES` marker files,
all three run. The fork inherited this behavior because `SKIP` / `SKIP_IMAGES`
were in upstream's `.gitignore` — they're treated as "local user markers" in
upstream's model, not fork-level identity decisions.

For this fork, the identity decision is absolute: **photoframe is a
framebuffer application that writes directly to `/dev/fb0`**. A Pi OS
Desktop image that starts a display manager (lightdm) and an X session at
boot will grab `/dev/fb0` before photoframe can touch it. Shipping a desktop
stage isn't just wasteful — it's actively wrong. Evidence in
`photoframe/modules/display.py` shows direct `dd if=/dev/zero of=/dev/fb0`
framebuffer takeover, and the fork's own `stage2/04-photoframe/01-run.sh`
masks `plymouth-start.service` and disables `getty@tty1.service` precisely
because they compete for the framebuffer.

**Fix:** `.gitignore` was modified to stop excluding `SKIP` and
`SKIP_IMAGES` (two-line removal), and five empty marker files were
committed:

- `stage3/SKIP` — stage3 (desktop system with X11 and LXDE) does not run
- `stage4/SKIP` — stage4 (normal 4GB-card image) does not run
- `stage4/SKIP_IMAGES` — stage4's `EXPORT_IMAGE` is not executed
- `stage5/SKIP` — stage5 (Full image) does not run
- `stage5/SKIP_IMAGES` — stage5's `EXPORT_IMAGE` is not executed

`stage3` does not need `SKIP_IMAGES` because it has no `EXPORT_IMAGE` file.

Result: build time drops from ~90 min to ~40 min, deploy/ contains a single
810 MB `.zip`, and we never accidentally ship a desktop image that would
fight photoframe for the framebuffer. Included in `d7e8291`.

**Why upstream didn't catch it:** upstream's purpose is producing Raspberry
Pi OS Lite, Normal, and Full from the same source tree. Their `.gitignore`
convention for `SKIP` files assumes downstream users make per-build choices
about which stages to run. The fork's model is different: always Lite,
never the others.

### 6. Bash parameter expansion for backslash doubling needs four-and-eight counts

**Symptom:** initial attempts to escape `\` → `\\` in the PSK before writing
the NetworkManager keyfile used `${PSK//\\/\\\\}` — four backslashes of
source in the `//` replacement syntax. Empirically, this did nothing. A PSK
of `foo\bar` stayed `foo\bar` (3 characters) after the substitution, when we
wanted `foo\\bar` (4 characters).

**Root cause:** bash's parameter-substitution pattern syntax (`${var//pat/rep}`)
uses **glob** matching, and the glob engine interprets `\` as an escape
character. Combined with shell-level backslash removal on the way in, the
effective escape count is **4 source backslashes per 1 literal backslash at
the matching layer**, on both sides of the substitution. The correct form is:

```bash
PSK=${PSK//\\\\/\\\\\\\\}
#        ^^^^  ^^^^^^^^
#        4     8
#        ↑     ↑
#        matches one \  replaces with two \\
```

Verified experimentally in WSL bash 5.x. Variable-based forms like
`PAT='\\'; ${v//$PAT/...}` do NOT work — bash applies an additional round of
escape processing on variable-expanded pattern content that consumes the
backslashes.

**Fix:** use the literal four-and-eight form in `photoframe-wifi-setup.sh`
with an extensive comment explaining the escape count so future readers
don't "simplify" it back to the broken two-and-four form. See the script's
comment block at the call site.

**Why this isn't in upstream:** no upstream pi-gen code needs to escape
GLib keyfile strings. Upstream has no wifi-config.txt mechanism.

### 7. `/var/log/journal/` volatile-by-default loses first-boot logs

**Symptom:** during debugging of earlier boots, we could not read any
post-mortem log from a card that had booted once, because
`/var/log/journal/` was empty on the mounted ext4 rootfs. Every first-boot
attempt that failed was un-investigable after the fact.

**Root cause:** recent Raspberry Pi OS Bookworm images (since ~2025-05-13)
explicitly set `Storage=volatile` in `/etc/systemd/journald.conf`, where
earlier Bookworm defaulted to `Storage=auto`. With volatile storage, logs
live in `/run/log/journal/` (tmpfs) and are lost on any power cycle —
graceful or not.

**Fix:** the fork creates `/var/log/journal/` at build time with mode 2755
during `01-run.sh`. With the directory present, journald's `Storage=auto`
behavior would switch to persistent — but since Bookworm now hardcodes
`Storage=volatile` in the config, we'd need to also patch `journald.conf` to
get full persistence. For now, creating the directory is a first step; the
`Storage=volatile` override in the running image would need to be revisited
if persistent logging is a hard requirement.

**Why upstream didn't catch it:** upstream's goal is a clean Lite image with
small storage footprint. Volatile journal is a deliberate choice for
persistence-conservative appliance images. The fork needs the debuggability
more than the small footprint savings.

### 8. Imager v2.0+ greys out customization for custom images

This isn't a pi-gen bug but it affects how users flash the resulting image.

**Symptom:** when users select "Use custom" in Raspberry Pi Imager and pick
the photoframe `.zip`, the gear icon for advanced settings (WiFi, hostname,
SSH, username) is greyed out.

**Root cause:** Raspberry Pi Imager v2.0+ deliberately disables customization
for custom images because it has no metadata describing what customization
the image supports. Discussed in
[rpi-imager#1377](https://github.com/raspberrypi/rpi-imager/issues/1377) —
the Raspberry Pi team marked it as won't-fix.

**Fix:** the fork handles every customization Imager's gear icon would have
done:
- **Username/password**: baked in via `FIRST_USER_NAME`/`FIRST_USER_PASS` at
  build time, with `DISABLE_FIRST_BOOT_USER_RENAME=1` preventing the rename
  wizard
- **SSH enabled**: `ENABLE_SSH=1` in `config.example`
- **WiFi credentials**: user edits `wifi-config.txt` on the bootfs partition
  in Notepad++ before first boot; `photoframe-wifi-setup.service` consumes
  it and generates a NetworkManager keyfile
- **WiFi country**: baked in via `WPA_COUNTRY=US`
- **Display override for atypical panels**: user edits `cmdline.txt` on the
  bootfs partition

The greyed-out Imager gear icon is a non-issue for our image. Every
legitimate pre-boot customization is achievable by editing files on the
FAT32 boot partition from Windows Explorer.

## Design decisions carried forward

Each of these is documented where it's implemented; this is a cross-reference
so a future maintainer looking at any one of these decisions in the source
can find the rationale.

### `wifi-config.txt` uses INI format with a `[wifi]` section

Over shell `KEY=VALUE` (quoting nightmares with special characters in PSKs)
and over raw `.nmconnection` (too technical for the novice user we're
targeting). INI with a `[wifi]` section header is human-friendly, awk-parseable,
and mirrors NetworkManager's own file format so the conversion from
`wifi-config.txt` to `photoframe-wifi.nmconnection` is minimal.

See `stage2/04-photoframe/files/wifi-config.txt` for the template and
`stage2/04-photoframe/files/photoframe-wifi-setup.sh` for the parser.

### Marker file at `/var/lib/photoframe/wifi-configured` for idempotency

Standard systemd oneshot pattern. `ConditionPathExists=!/var/lib/photoframe/wifi-configured`
in the service unit prevents re-runs after a successful first boot. The
script creates the marker as its last step only on the happy path — failures
(bad PSK, placeholder values) leave the marker absent so the user can edit
and reboot. See `photoframe-wifi-setup.service`.

### systemd unit orders `Before=NetworkManager.service`

The keyfile must be in place before NM's first scan of
`/etc/NetworkManager/system-connections/`, otherwise NM boots without a
WiFi configuration and never notices the keyfile we drop later. `Before=`
gives us that ordering. See `photoframe-wifi-setup.service`.

### `WPA_COUNTRY=US` as the shipped default

Documented inline in `config.example` with a `PROJECT DECISION` comment
block explaining:
1. The maintainers are US-based and this matches the bench test environment
2. A country code MUST be set or the kernel won't transmit
3. Users outside the US should change it in their own builds OR override
   at runtime via the `COUNTRY` field in `wifi-config.txt`
4. If multi-region demand materializes, revisit the default

See `config.example`.

### Direct NetworkManager keyfile write over `nmcli connection add`

`nmcli connection add` requires NetworkManager to be running. Our script
runs `Before=NetworkManager.service`, which means there's no NM daemon
when we execute — nmcli would fail. Writing the keyfile directly is
officially supported per
[upstream NM documentation](https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html):

> "Users can create or modify the _keyfile_ connection files manually,
> even if that is not the recommended way of managing the profiles.
> However, if they choose to do that, they must inform NetworkManager
> about their changes (for example via nmcli con (re)load)."

The "reload" caveat doesn't apply because NM hasn't started yet.
[`RPi-Distro/raspberrypi-sys-mods imager_custom`](https://github.com/RPi-Distro/raspberrypi-sys-mods/blob/bookworm/usr/lib/raspberrypi-sys-mods/imager_custom)
uses the same direct-write approach in production for every Imager-injected
WiFi config. See `photoframe-wifi-setup.sh`.

### SKIP files instead of `STAGE_LIST` in config

Both are documented upstream mechanisms for skipping stages. We chose SKIP
files because they're more discoverable — a maintainer running `ls stage*`
sees the markers immediately. `STAGE_LIST` in `config.example` would be
silently defeated by any user who copied `config.example` to `config`
without noticing the override.

See `stage3/SKIP`, `stage4/SKIP`, `stage4/SKIP_IMAGES`, `stage5/SKIP`,
`stage5/SKIP_IMAGES`.

### `photoframe-wifi-setup` lives at `/usr/local/sbin/`

FHS-correct for local admin scripts. On `root`'s `PATH`. Invoked directly
by the systemd unit's `ExecStart=`. See `01-run.sh`.

## Fork divergence from upstream

If you merge new upstream pi-gen commits into this fork, expect conflicts
in these files:

- `.gitignore` — we removed the `SKIP` / `SKIP_IMAGES` exclusions
- `config.example` — we added six variables (`export PHOTOFRAME_BRANCH`,
  `FIRST_USER_NAME`, `FIRST_USER_PASS`, `DISABLE_FIRST_BOOT_USER_RENAME`,
  `WPA_COUNTRY`, plus the SKIP-mechanism comment)
- `stage2/04-photoframe/` — entire directory is fork-added; will not exist
  on upstream, no conflict expected unless upstream also adds a `stage2/04-`
  substage
- `stage3/`, `stage4/`, `stage5/` — we added SKIP markers that upstream
  treats as local-only. Rebase will touch these if upstream modifies the
  stages themselves (which does happen on occasion for package updates)

When rebasing, verify the bugs in this HISTORY are still not re-introduced
by the rebase:
1. `01-tweak-config.diff` still applies against the current `stage1` config.txt
2. `export PHOTOFRAME_BRANCH` is still in `config.example`
3. `DISABLE_FIRST_BOOT_USER_RENAME=1` is still in `config.example`
4. `WPA_COUNTRY` is still in `config.example`
5. The five SKIP markers are still present
6. `photoframe-wifi-setup.sh` still has the 4-and-8 backslash escape

## Pointers

- **Build instructions**: see the pi-gen README in this repo for
  `./build-docker.sh` invocation. The fork-specific prereqs are
  `DISABLE_FIRST_BOOT_USER_RENAME=1`, `WPA_COUNTRY=US`, and the
  `export PHOTOFRAME_BRANCH` line in `config.example` → `config`.
- **Photoframe application**: https://github.com/dev-brewery/photoframe
- **Upstream pi-gen**: https://github.com/RPi-Distro/pi-gen — base for
  unrelated rebases, always keep in mind that upstream defaults are
  general-purpose and this fork's defaults are appliance-specific.
- **Raspberry Pi OS Bookworm release notes**: useful for understanding why
  NetworkManager replaced wpa_supplicant and why legacy `hdmi_*` options
  don't work under KMS.
- **The photoframe release page**: the `.img.zip` artifact produced by this
  fork is published at https://github.com/dev-brewery/photoframe/releases
  (not on this pi-gen repo — pi-gen is the build utility, photoframe is the
  product).
