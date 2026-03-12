#!/bin/bash
# Build and install patched snd-hda-codec-cs420x for MacBook8,1 speaker fix
set -e

KVER=$(uname -r)
BUILD_DIR="/tmp/cs4208-macbook8-build"
TARBALL="/usr/src/linux-source-${KVER%%-*}/linux-source-${KVER%%-*}.tar.bz2"
HEADERS="/usr/src/linux-headers-${KVER}"
KMOD_DEST="/lib/modules/${KVER}/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst"

echo "==> Kernel: $KVER"
echo "==> Tarball: $TARBALL"

if [ ! -f "$TARBALL" ]; then
    echo "ERROR: Kernel source tarball not found at $TARBALL"
    exit 1
fi

if [ ! -d "$HEADERS" ]; then
    echo "ERROR: Kernel headers not found at $HEADERS"
    exit 1
fi

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Extracting Cirrus codec source (this takes 2-5 minutes, decompressing full tarball)..."
KVER_BASE="${KVER%%-*}"
tar -xjf "$TARBALL" \
    "linux-source-${KVER_BASE}/sound/hda/codecs/cirrus/" \
    -C "$BUILD_DIR" 2>/dev/null || {
    # Fallback: try old kernel path
    echo "    Trying alternate path..."
    tar -xjf "$TARBALL" \
        "linux-source-${KVER_BASE}/sound/pci/hda/patch_cirrus.c" \
        "linux-source-${KVER_BASE}/sound/pci/hda/patch_cirrus.h" \
        -C "$BUILD_DIR" 2>/dev/null || true
}

# Find the cs420x.c source file
SRC=$(find "$BUILD_DIR" -name "cs420x.c" 2>/dev/null | head -1)
if [ -z "$SRC" ]; then
    SRC=$(find "$BUILD_DIR" -name "patch_cirrus.c" 2>/dev/null | head -1)
fi
if [ -z "$SRC" ]; then
    echo "ERROR: Could not find cs420x.c or patch_cirrus.c in extracted source."
    echo "Files extracted:"
    find "$BUILD_DIR" -type f | head -20
    exit 1
fi

SRCDIR=$(dirname "$SRC")
echo "==> Found source: $SRC"

# Apply the patch
echo "==> Applying MacBook8,1 speaker fixup patch..."

# 1. Add CS4208_MACBOOK8_1 to enum (insert before CS4208_GPIO0)
sed -i 's/^\(\s*\)CS4208_GPIO0,/\1CS4208_MACBOOK8_1,\n\1CS4208_GPIO0,/' "$SRC"

# 2. Add SSID to cs4208_mac_fixup_tbl (insert before terminator)
sed -i '/SND_PCI_QUIRK(0x106b, 0x7b00.*MacBookPro 12,1/a\\tSND_PCI_QUIRK(0x106b, 0x6400, "MacBook8,1", CS4208_MACBOOK8_1),' "$SRC"

# 3. Add fixup function + array entry
# Find the cs4208_fixups array and insert before it
python3 - "$SRC" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

new_func = '''
static void cs4208_fixup_macbook8_1(struct hda_codec *codec,
\t\t\t\t    const struct hda_fixup *fix, int action)
{
\tif (action == HDA_FIXUP_ACT_INIT) {
\t\t/*
\t\t * MacBook8,1 (12" Early 2015): cs4208_coef_init_verbs enables
\t\t * VPW/DSP processing (node 0x24 SET_PROC_STATE=1) but the DSP
\t\t * coefficients are not initialised for this model, which appears
\t\t * to block the internal speaker output path entirely. Disabling
\t\t * VPW makes audio bypass the DSP and reach the speaker pins.
\t\t */
\t\tsnd_hda_codec_write(codec, 0x24, 0,
\t\t\t\t    AC_VERB_SET_PROC_STATE, 0x00);
\t}
}

'''

new_entry = '''\t[CS4208_MACBOOK8_1] = {
\t\t.type = HDA_FIXUP_FUNC,
\t\t.v.func = cs4208_fixup_macbook8_1,
\t\t.chained = true,
\t\t.chain_id = CS4208_GPIO0,
\t},
'''

# Insert function before cs4208_fixups array
src = re.sub(
    r'(static const struct hda_fixup cs4208_fixups\[\])',
    new_func + r'\1',
    src
)

# Insert array entry before CS4208_GPIO0
src = re.sub(
    r'(\t\[CS4208_GPIO0\] =)',
    new_entry + r'\1',
    src
)

with open(path, 'w') as f:
    f.write(src)

print("Patch applied successfully")
PYEOF

echo "==> Patched source written. Verifying key strings..."
grep -n "CS4208_MACBOOK8_1\|MacBook8,1\|fixup_macbook8_1" "$SRC"

# Create out-of-tree build directory
OUTTREE="$BUILD_DIR/outtree"
mkdir -p "$OUTTREE"
cp -r "$SRCDIR"/* "$OUTTREE/"

# Check for common/ includes needed by cs420x.c
COMMON_SRC=$(find "$BUILD_DIR" -path "*/sound/hda/common" -type d 2>/dev/null | head -1)
if [ -n "$COMMON_SRC" ]; then
    mkdir -p "$OUTTREE/../common"
    cp -r "$COMMON_SRC"/* "$OUTTREE/../common/" 2>/dev/null || true
fi

# Write Makefile for out-of-tree build
cat > "$OUTTREE/Makefile" <<EOF
# SPDX-License-Identifier: GPL-2.0
KDIR ?= $HEADERS
obj-m := snd-hda-codec-cs420x.o
snd-hda-codec-cs420x-y := cs420x.o
ccflags-y += -I\$(src)/../common

all:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) CONFIG_SND_HDA_CODEC_CS420X=m modules

clean:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) clean
EOF

echo "==> Building module..."
cd "$OUTTREE"
make 2>&1

if [ ! -f "$OUTTREE/snd-hda-codec-cs420x.ko" ]; then
    echo "ERROR: Build failed — .ko not found"
    exit 1
fi

echo "==> Build successful!"
echo ""
echo "==> Backing up original module..."
sudo cp "$KMOD_DEST" "${KMOD_DEST}.bak" 2>/dev/null || true

echo "==> Installing patched module..."
sudo zstd -f "$OUTTREE/snd-hda-codec-cs420x.ko" -o "$KMOD_DEST"
sudo depmod -a

echo ""
echo "==> Done! To test without rebooting:"
echo "    sudo rmmod snd-hda-codec-cs420x snd-hda-intel snd-hda-core"
echo "    sudo modprobe snd-hda-codec-cs420x"
echo "    sudo modprobe snd-hda-intel"
echo ""
echo "==> To revert if this doesn't work:"
echo "    sudo cp ${KMOD_DEST}.bak $KMOD_DEST"
echo "    sudo depmod -a"
