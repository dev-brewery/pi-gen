#!/bin/bash
# photoframe-wifi-setup: consume /boot/wifi-config.txt on first boot and
# write /etc/wpa_supplicant/wpa_supplicant.conf so WiFi connects automatically.
#
# Idempotent: a marker at /var/lib/photoframe/wifi-configured prevents re-run.
# Invoked by photoframe-wifi-setup.service before wpa_supplicant starts.

set -u

BOOT_DIR="/boot"
CFG="${BOOT_DIR}/wifi-config.txt"
APPLIED="${BOOT_DIR}/wifi-config.txt.applied"
ERR="${BOOT_DIR}/wifi-config.txt.error"
MARKER_DIR="/var/lib/photoframe"
MARKER="${MARKER_DIR}/wifi-configured"
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"

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

# Escape double quotes and backslashes for wpa_supplicant quoted strings.
SSID=${SSID//\\/\\\\}
SSID=${SSID//\"/\\\"}
PSK=${PSK//\\/\\\\}
PSK=${PSK//\"/\\\"}

umask 077
mkdir -p "$(dirname "${WPA_CONF}")"

cat > "${WPA_CONF}" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${COUNTRY}

network={
    ssid="${SSID}"
    psk="${PSK}"
}
EOF

chown root:root "${WPA_CONF}"
chmod 600 "${WPA_CONF}"

# Redact PSK in the on-disk copy, then rename to .applied so the user
# can see what happened without leaving plaintext on FAT32.
sed -i 's/^[[:space:]]*PSK=.*/PSK=<redacted-after-apply>/' "${CFG}"
mv -f "${CFG}" "${APPLIED}"
rm -f "${ERR}"

touch "${MARKER}"
log "wrote ${WPA_CONF}, renamed config to $(basename "${APPLIED}")"
exit 0
