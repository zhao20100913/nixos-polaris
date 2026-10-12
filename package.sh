#!/usr/bin/env bash
# Package NixOS build outputs into a TWRP-flashable zip for Xiaomi MIX 2S (polaris).
# Usage: ./package.sh <rootfs-out> <boot-files-dir> <u-boot-out> <out.zip>
set -euo pipefail

ROOTFS_IN="$1"
BOOT_DIR_IN="$2"
UBOOT_IN="$3"
OUT_ZIP="$4"

# Resolve output to ABSOLUTE path BEFORE WORK gets cleaned up on exit.
# Otherwise zip writes into $WORK (because of the sub-shell cd) and the
# exit trap deletes it.
OUT_ZIP="$(cd "$(dirname "$OUT_ZIP")" && pwd)/$(basename "$OUT_ZIP")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/META-INF/com/google/android" "$WORK/boot"

# --- Resolve nix out-links (they are symlinks into /nix/store) ---
ROOTFS_REAL=$(readlink -f "$ROOTFS_IN")
UBOOT_REAL=$(readlink -f "$UBOOT_IN")
BOOT_REAL=$(readlink -f "$BOOT_DIR_IN")

echo "==> rootfs resolved: $ROOTFS_REAL"
echo "==> boot-files resolved: $BOOT_REAL"
echo "==> u-boot resolved: $UBOOT_REAL"
ls -la "$ROOTFS_REAL" "$BOOT_REAL" "$UBOOT_REAL" || true

# --- Find rootfs image (may be a directory containing system.img / *.ext4) ---
if [ -d "$ROOTFS_REAL" ]; then
  ROOTFS_IMG=$(find "$ROOTFS_REAL" -maxdepth 3 -type f \( -name "*.img" -o -name "*.ext4" -o -name "system" -o -name "*.squashfs" \) | head -1)
else
  ROOTFS_IMG="$ROOTFS_REAL"
fi
echo "==> Using rootfs image: $ROOTFS_IMG"
cp "$ROOTFS_IMG" "$WORK/rootfs.img"

# --- Find U-Boot blob (may be a directory containing u-boot.bin / *.img) ---
if [ -d "$UBOOT_REAL" ]; then
  UBOOT_BIN=$(find "$UBOOT_REAL" -maxdepth 3 -type f \( -name "u-boot*.bin" -o -name "*.img" -o -name "*.bin" \) | head -1)
else
  UBOOT_BIN="$UBOOT_REAL"
fi
echo "==> Using U-Boot: $UBOOT_BIN"
cp "$UBOOT_BIN" "$WORK/u-boot.img"

# --- boot-files: wrap EFI file tree into a FAT32 image ---
echo "==> Building FAT32 /boot image"
BOOT_IMG="$WORK/boot/boot.img"
dd if=/dev/zero of="$BOOT_IMG" bs=1M count=256 status=none
mkfs.vfat -F32 -n "NIXOS_BOOT" "$BOOT_IMG" >/dev/null

(
  cd "$BOOT_REAL"
  find . -type f | while read -r f; do
    rel="${f#./}"
    mcopy -spm -i "$BOOT_IMG" "$rel" "::$rel" >/dev/null 2>&1 || true
  done
)

# --- updater-script (edify) ---
cat > "$WORK/META-INF/com/google/android/updater-script" <<'EOF'
assert(getprop("ro.product.device") == "polaris" ||
       getprop("ro.build.product") == "polaris" ||
       getprop("ro.boot.hardware") == "polaris" ||
       abort("This package is for Xiaomi Mi MIX 2S (polaris) only!"));

ui_print("");
ui_print(" NixOS for Xiaomi Mi MIX 2S (polaris)");
ui_print("---------------------------------------");
ui_print("");

show_progress(0.6, 120);

ui_print(" Writing NixOS rootfs to userdata ...");
package_extract_file("rootfs.img", "/dev/block/bootdevice/by-name/userdata");

ui_print(" Writing EFI /boot to system partition ...");
package_extract_file("boot/boot.img", "/dev/block/bootdevice/by-name/system");

ui_print(" Writing U-Boot to boot partition ...");
package_extract_file("u-boot.img", "/dev/block/bootdevice/by-name/boot");

ui_print(" Resizing rootfs to fill userdata ...");
run_program("/sbin/resize2fs", "/dev/block/bootdevice/by-name/userdata");

set_progress(1.0);
ui_print("");
ui_print(" Done. Reboot to system.");
ui_print(" Default access: USB Ethernet 172.16.42.1, root (empty pw over USB only).");
ui_print("");
EOF

# --- update-binary placeholder (TWRP uses its own) ---
cat > "$WORK/META-INF/com/google/android/update-binary" <<'EOF'
#!/sbin/sh
exit 0
EOF
chmod 0755 "$WORK/META-INF/com/google/android/update-binary"

# --- pack zip ---
echo "==> Writing $OUT_ZIP"
rm -f "$OUT_ZIP"
( cd "$WORK" && zip -r9 "$OUT_ZIP" . -x ".*" )

echo "==> Done:"
ls -lh "$OUT_ZIP"
unzip -l "$OUT_ZIP"
