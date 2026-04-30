#!/bin/bash -e

# Lite-target hardening: when photoframe owns the framebuffer end-to-end
# (no display manager installed), the tty1 getty and the plymouth boot
# splash are pure visual noise that briefly fight for /dev/fb0 before
# frame.service comes up. Disable both for a clean Lite boot.
#
# On the desktop target (stage4 installs lightdm), keep both enabled:
# - getty@tty1 is the recovery VT (Ctrl+Alt+F1) when the graphical stack
#   is broken; lightdm uses its own VT so there's no conflict.
# - plymouth-start drives the boot splash before lightdm and
#   frame.service come up; masking it would leave a black screen for the
#   first ~5 seconds of every boot.
#
# PHOTOFRAME_TARGET is exported by config.example (see HISTORY bug #2 for
# the export-vs-shell-local subtlety; the same fix applies here).
if [ "${PHOTOFRAME_TARGET:-lite}" = "lite" ]; then
	on_chroot << EOF
systemctl disable getty@tty1.service
systemctl mask plymouth-start.service
EOF
fi

# Create config folder
mkdir -p ${ROOTFS_DIR}/root/photoframe_config

# Add info files
install -m 644 files/colortemp_info.txt ${ROOTFS_DIR}/root/photoframe_config/colortemp_info.txt

# Add default authentication
install -m 644 files/http-auth.json ${ROOTFS_DIR}/boot/http-auth.json

# Remove wait on network (may not exist on newer OS)
rm -f ${ROOTFS_DIR}/etc/systemd/system/dhcpcd.service.d/wait.conf

# Clone photoframe repo
if [ "${PHOTOFRAME_SRC}" = "" ]; then
  git clone -v -b ${PHOTOFRAME_BRANCH} https://github.com/dev-brewery/photoframe.git ${ROOTFS_DIR}/root/photoframe
else
  echo "Using ${PHOTOFRAME_SRC} as the basis for the photoframe software"
  mkdir -p ${ROOTFS_DIR}/root/photoframe
  for X in $(ls -A1 ${PHOTOFRAME_SRC}) ; do
    if [[ "$X" != *pi-gen ]]; then
      cp -dprv "${PHOTOFRAME_SRC}/$X" ${ROOTFS_DIR}/root/photoframe/
    fi
  done
  pushd ${ROOTFS_DIR}/root/photoframe/
  git checkout ${PHOTOFRAME_BRANCH}
  popd
fi

# --- Track 2: headless WiFi setup, persistent journal ---

# Ship the user-editable WiFi template on the boot partition.
install -m 644 files/wifi-config.txt "${ROOTFS_DIR}/boot/wifi-config.txt"

# Install the firstboot setup script and its systemd unit.
install -D -m 755 files/photoframe-wifi-setup.sh \
    "${ROOTFS_DIR}/usr/local/sbin/photoframe-wifi-setup"
install -D -m 644 files/photoframe-wifi-setup.service \
    "${ROOTFS_DIR}/etc/systemd/system/photoframe-wifi-setup.service"

# State directory for the idempotency marker.
install -d -m 755 "${ROOTFS_DIR}/var/lib/photoframe"

# Enable persistent journald (volatile by default; loses first-boot logs).
install -d -m 2755 "${ROOTFS_DIR}/var/log/journal"

on_chroot << EOF
systemctl enable photoframe-wifi-setup.service
EOF

# --- end Track 2 additions ---

on_chroot << EOF
cd /root/photoframe

# Install Python dependencies
pip3 install --break-system-packages -r requirements.txt

cp frame.service /etc/systemd/system/
systemctl enable /etc/systemd/system/frame.service

# Enable auto update
echo >>/etc/crontab "15 3    * * *   root    /root/photoframe/update.sh"

# Add missing i2c-dev modules for color sensor
if ! grep -q "i2c-dev" /etc/modules 2>/dev/null; then
  echo >>/etc/modules "i2c-dev"
fi
EOF
