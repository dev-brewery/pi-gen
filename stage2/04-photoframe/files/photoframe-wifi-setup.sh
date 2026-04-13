#!/bin/bash
# photoframe-wifi-setup: consume /boot/firmware/wifi-config.txt on first boot
# and write a NetworkManager keyfile so WiFi connects automatically.
#
# Idempotent: a marker at /var/lib/photoframe/wifi-configured prevents re-run.
# Invoked by photoframe-wifi-setup.service before NetworkManager starts.

set -u

BOOT_DIR="/boot/firmware"
CFG="${BOOT_DIR}/wifi-config.txt"
APPLIED="${BOOT_DIR}/wifi-config.txt.applied"
ERR="${BOOT_DIR}/wifi-config.txt.error"
MARKER_DIR="/var/lib/photoframe"
MARKER="${MARKER_DIR}/wifi-configured"
NM_DIR="/etc/NetworkManager/system-connections"
NM_FILE="${NM_DIR}/photoframe-wifi.nmconnection"

log()  { echo "photoframe-wifi-setup: $*" >&2; }
fail() { echo "$*" > "${ERR}"; log "ERROR: $*"; exit 0; }   # exit 0: don't block boot

mkdir -p "${MARKER_DIR}"

# Idempotency guard
if [ -e "${MARKER}" ]; then
    log "marker present, nothing to do"
    exit 0
fi

# Nothing dropped on the boot partition — silently skip.
if [ ! -f "${CFG}" ]; then
    log "no ${CFG}, skipping"
    exit 0
fi

# Strip CR (Windows line endings), comments, blanks; extract KEY=VALUE
# from inside the [wifi] section. Tolerant of leading/trailing whitespace.
# Also strips matched outer single or double quotes from the value so a
# user who ignores the "no quotes" instruction gets forgiving behavior.
parse() {
    awk -v key="$1" '
        BEGIN { in_section = 0 }
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[wifi\][[:space:]]*$/ { in_section = 1; next }
        /^[[:space:]]*\[/ { in_section = 0; next }
        in_section {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            eq = index(line, "=")
            if (eq == 0) next
            k = substr(line, 1, eq - 1)
            v = substr(line, eq + 1)
            sub(/[[:space:]]+$/, "", k)
            sub(/^[[:space:]]+/, "", v)
            sub(/[[:space:]]+$/, "", v)
            # Strip matched outer single or double quotes (user wrapped value)
            if (length(v) >= 2) {
                first = substr(v, 1, 1)
                last  = substr(v, length(v), 1)
                if ((first == "\"" && last == "\"") || (first == "'"'"'" && last == "'"'"'")) {
                    v = substr(v, 2, length(v) - 2)
                }
            }
            if (k == key) { print v; exit }
        }
    ' "${CFG}"
}

SSID=$(parse SSID)
PSK=$(parse PSK)
COUNTRY=$(parse COUNTRY)
[ -z "${COUNTRY}" ] && COUNTRY="US"

# Placeholder / empty checks
if [ -z "${SSID}" ] || [ "${SSID}" = "YOUR_SSID_HERE" ]; then
    log "SSID is empty or still placeholder, skipping (not an error)"
    exit 0
fi
if [ -z "${PSK}" ] || [ "${PSK}" = "YOUR_PASSWORD_HERE" ]; then
    fail "PSK is empty or still set to YOUR_PASSWORD_HERE"
fi
if [ ${#PSK} -lt 8 ] || [ ${#PSK} -gt 63 ]; then
    fail "PSK must be 8-63 characters (got ${#PSK})"
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
umask 077
mkdir -p "${NM_DIR}"

# Escape backslashes for GLib KeyFile format. A literal `\` in the value
# must be written as `\\` so GLib's key_file_parse_value_as_string does
# not interpret it as an unknown escape sequence (\s, \n, \t, \\ are the
# only recognized escapes). Do this AFTER length validation so the user
# sees the raw length in their error message, but BEFORE the heredoc so
# the written keyfile is GLib-correct.
#
# The 4-and-8 backslash counts below are NOT a typo. Bash parameter
# expansion ${var//pattern/replacement} processes the pattern as a glob,
# and both pattern and replacement go through shell backslash removal
# *twice* (once at the outer shell, once at the glob/replacement layer),
# which consumes 4 source backslashes to produce 1 literal backslash at
# the matching layer. So to match one `\` and replace with two `\\`, we
# need 4 backslashes in the pattern and 8 in the replacement. Verified
# experimentally against bash 5.x in WSL; variable-based forms like
# PAT='\\'; ${v//$PAT/...} do NOT work — bash applies an additional
# round of escape processing that swallows the backslashes.
SSID=${SSID//\\\\/\\\\\\\\}
PSK=${PSK//\\\\/\\\\\\\\}

cat > "${NM_FILE}" <<EOF
[connection]
id=photoframe-wifi
uuid=${UUID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${PSK}

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
EOF

chown root:root "${NM_FILE}"
chmod 600 "${NM_FILE}"

# Best-effort regdom set; harmless if iw is missing or already set.
if command -v iw >/dev/null 2>&1; then
    iw reg set "${COUNTRY}" 2>/dev/null || true
fi

# Redact PSK in the on-disk copy, then rename to .applied so the user
# can see what happened without leaving plaintext on FAT32.
sed -i 's/^[[:space:]]*PSK=.*/PSK=<redacted-after-apply>/' "${CFG}"
mv -f "${CFG}" "${APPLIED}"
rm -f "${ERR}"

touch "${MARKER}"
log "wrote ${NM_FILE}, renamed config to $(basename "${APPLIED}")"
exit 0
