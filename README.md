# MacBook8,1 Linux Internal Speaker Fix

**Hardware:** Apple MacBook8,1 (12-inch Early 2015, model A1534)
**Codec:** Cirrus Logic CS4208 (SSID `0x106b6400`)
**Kernel:** 6.17.0-14-generic (Ubuntu)
**Status:** Work in progress — kernel crashes observed during testing. Not yet confirmed working.

---

## The Problem

Internal speakers are completely silent on Linux. Headphones work. The EFI boot
chime plays correctly through the speakers at every boot, confirming the hardware
itself is functional — the problem is entirely in how the Linux kernel initialises
(or fails to initialise) the CS4208 codec.

---

## Critical Architecture Discovery

**This was wrong in earlier versions of this README.** The speaker path on
MacBook8,1 is NOT what you expect from a normal HDA codec.

### The real speaker signal path

```
Node 0x0a  (8-channel DIGITAL output converter, wcaps=0x406301)
    │
    └─▶  Pin 0x1d  (Fixed/Int Speaker, pin-ctl=0x40 OUT)
             │
             └─▶  I²C amplifier at address 0x44 on i2c-0 (SMBus I801)
                      │
                      └─▶  Physical speaker drivers
```

### Why 0x11–0x14 are irrelevant

Earlier investigation (conducted while `model=mbp11` was set in modprobe.d) saw
pins 0x11–0x14 as "Speaker Fixed Int" outputs and assumed they drove the speakers.
**This is wrong.** Those nodes have pin defaults `0x400000f0` which decode to
`[N/A] Not Connected`. They only appeared active because `model=mbp11` was
overriding the SSID-based fixup selection and running a different fixup that
enabled them. Once `model=mbp11` was removed, autoconfig correctly reports:

```
autoconfig: line_outs=1 (0x1d) type:speaker
speaker_outs=0
hp_outs=1 (0x10)
```

### Node 0x0a is digital, not analog

Node 0x0a has `AC_WCAP_DIGITAL` set (wcaps `0x406301`). The HDA generic layer
correctly identifies it as the DAC for pin 0x1d (speaker) but treats it as an
analog output converter. Critically:

- `snd_hda_codec_setup_stream()` writes stream tag and format to it, but **does
  not set `AC_DIG1_ENABLE`** — it only sets the digital enable bit for nodes in
  explicit SPDIF paths.
- Without `AC_DIG1_ENABLE`, node 0x0a generates no I²S output regardless of
  stream assignment.

### The I²C amplifier at 0x44

- Bus: i2c-0 (SMBus I801 adapter)
- Address 0x08: Apple SMC (do not touch)
- Address 0x44: Speaker amplifier — chip identity unconfirmed, possibly TAS5766M
- Register reads captured (2026-03-12):
  - reg 0x00: `0x00` (page select)
  - reg 0x03: `0x04`
  - reg 0x09–0x0a: changing on each read (live voltage/status monitor)
  - reg 0x0c: `0x04`, 0x0d: `0x12`, 0x0e: `0x03`, 0x0f: `0x26`
  - All other regs: `0x00`
- The amp appears to be in a functioning idle state after EFI init — the EFI boot
  chime proves it can produce audio. Whether it needs re-initialisation after
  Linux cold-boots (without prior EFI audio) is unknown.

### Two-stage fixup selection (expected, not a bug)

The kernel log shows "picked fixup" twice for the same codec. This is normal:

1. **Vendor match** (`106b:0000`) → `CS4208_MAC_AUTO` → `cs4208_fixup_mac` runs
2. **SSID match** (`106b:6400`) → `CS4208_MACBOOK8_1` → our fixup runs

Both log lines reference `hdaudioC0D0`, both are CS4208. The two-stage selection
is how the driver handles the initial probe (vendor ID `0000`) vs final SSID
identification (`6400`).

---

## What the Patch Does (Current Version)

The patch adds `CS4208_MACBOOK8_1` to `cs4208_mac_fixup_tbl` for SSID
`0x106b6400`. The fixup registers a **PCM playback hook** (`cs4208_mb8_pcm_hook`)
that fires at `HDA_GEN_PCM_ACT_PREPARE` time (after the HDA generic layer has set
the stream format) and executes a sequence reverse-engineered from macOS's
`play_a1534()` function:

1. Bring AFG and node 0x0a to D0 (power up)
2. Toggle `DIGI_CONVERT_1` `0x01→0x00` to reset converter state
3. Set stream format on node 0x0a (`0x4013` = 44.1 kHz, 16-bit, 4-channel)
4. Set digital control bits in the macOS sequence:
   `AC_DIG1_ENABLE` → `DIGI_CONVERT_2=0x01` → `AC_DIG1_ENABLE|AC_DIG1_COPYRIGHT`
5. **Mirror the analog DAC (node 0x02) stream tag onto node 0x0a** — macOS
   assigns the same HDA DMA stream to both nodes; without a real stream tag, node
   0x0a has no PCM data and generates no I²S clocks
6. Enable VPW twice (macOS does two back-to-back `SET_PROC_STATE=0x01` writes)
7. Go to D3, clear `AC_DIG1_ENABLE` (keep only `AC_DIG1_COPYRIGHT=0x10`), issue
   vendor verb `0x7f0=0x03` (triggers I²S master clock generator)
8. Wake to D0, restore `DIGI_CONVERT` bits and stream tag
9. Enable sibling digital nodes 0x0b/0x0c/0x0d (set ENABLE, zero stream tag, park
   in D3)
10. Enable speaker pin 0x1d (`SET_PIN_WIDGET_CONTROL = PIN_OUT`)
11. GPIO: direction=`0x31`, data=`0x01` (GPIO[0]=1, EAPD), mask=`0x37`

The fixup chains to `CS4208_GPIO0` (standard EAPD GPIO setup).

### Key insight: stream tag mirroring

macOS assigns HDA stream tag 1 to **both** node 0x02 (analog DAC) and node 0x0a
(I²S digital output). Both nodes share the same DMA stream. On Linux, the HDA
core assigns a different (dynamic) stream tag to node 0x02. The hook reads it back
via `AC_VERB_GET_CONV` and mirrors it onto node 0x0a. Without this, node 0x0a
has tag 0 (no stream) and generates no I²S clocks to the amplifier at 0x44.

### Earlier approach (committed, superseded)

A simpler approach was tried first: just set `AC_DIG1_ENABLE` on node 0x0a at
`HDA_FIXUP_ACT_INIT` time (once, statically). This correctly identifies the
missing enable bit but does not solve the stream tag problem — node 0x0a never
gets a real DMA stream assigned. Result: no sound.

---

## Testing Status

| Approach | Result |
|----------|--------|
| All ALSA model strings (`mbp11`, `mba6`, `mbp101`, `gpio0`, `auto`) | Silent |
| GPIO[0]=1 via hda-verb / systemd service | No effect (already set) |
| `cs4208_coef_init_verbs` manually (coeff 0x33/0x34) | No effect |
| VPW enable (`SET_PROC_STATE=1`) | No effect |
| VPW disable only (`SET_PROC_STATE=0`, no ENABLE bit) | No sound |
| Unmuting all mixer channels | No effect |
| ACPI `_PS0` call | No effect |
| `i2cset 0x44 0x01 0x01` (software reset amp) | Amp still responds |
| Simple `AC_DIG1_ENABLE` at `ACT_INIT` | No sound (stream tag still missing) |
| Full PCM hook mirroring macOS `play_a1534()` | **Kernel crashed during test — result unknown** |

---

## Current State of System Files

| File | Purpose | Status |
|------|---------|--------|
| `/etc/modprobe.d/snd-hda-macbook.conf` | `options snd-hda-intel power_save=0` | `model=mbp11` **removed** 2026-03-12 — was overriding SSID fixup |
| `/lib/firmware/hda-macbook8.fw` | ALSA patch firmware (GPIO verbs) | Ineffective, can be removed |
| `/etc/systemd/system/macbook-speaker-gpio.service` | GPIO[0]=1 on boot | Redundant — driver sets this |
| `/lib/modules/6.17.0-14-generic/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst` | Patched module | Backups at `.bak` and `.bak2` |

---

## Repository Contents

```
kernel-patch/
  cs420x.c                    Patched kernel source (authoritative)
  snd-hda-codec-cs420x.ko     Pre-built module (kernel 6.17.0-14-generic)
  cs4208-macbook8-1.patch     Patch description file
notes/
  investigation-log.md        Full chronological investigation notes
build-cs4208-patch.sh         Build script
README.md                     This file
```

---

## Rebuilding the Module

```bash
# Extract kernel source headers we need
cd /tmp
tar -xjf /usr/src/linux-source-6.17.0/linux-source-6.17.0.tar.bz2 \
    'linux-source-6.17.0/sound/hda/common/hda_local.h' \
    'linux-source-6.17.0/sound/hda/common/hda_auto_parser.h' \
    'linux-source-6.17.0/sound/hda/common/hda_jack.h' \
    'linux-source-6.17.0/sound/hda/codecs/generic.h' \
    'linux-source-6.17.0/sound/hda/codecs/cirrus/Makefile' \
    'linux-source-6.17.0/sound/hda/codecs/cirrus/cs420x.c'

# Copy patched source
cp /path/to/repo/kernel-patch/cs420x.c \
   /tmp/linux-source-6.17.0/sound/hda/codecs/cirrus/cs420x.c

# Write out-of-tree Makefile
cat > /tmp/linux-source-6.17.0/sound/hda/codecs/cirrus/Makefile.oot <<'EOF'
KDIR ?= /usr/src/linux-headers-6.17.0-14-generic
obj-m := snd-hda-codec-cs420x.o
snd-hda-codec-cs420x-y := cs420x.o
ccflags-y += -I$(src)/../../common
ccflags-y += -I$(src)/..
all:
	$(MAKE) -C $(KDIR) M=$(PWD) CONFIG_SND_HDA_CODEC_CS420X=m modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

cd /tmp/linux-source-6.17.0/sound/hda/codecs/cirrus
make -f Makefile.oot
```

---

## Installing the Module

```bash
KVER=$(uname -r)
KMOD="/lib/modules/${KVER}/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst"
KO="/path/to/repo/kernel-patch/snd-hda-codec-cs420x.ko"

sudo cp "$KMOD" "${KMOD}.bak"
sudo zstd -f "$KO" -o "$KMOD"
sudo depmod -a
sudo rmmod snd-hda-codec-cs420x && sudo modprobe snd-hda-codec-cs420x
```

## Reverting

```bash
KVER=$(uname -r)
KMOD="/lib/modules/${KVER}/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst"
sudo cp "${KMOD}.bak" "$KMOD"
sudo depmod -a
sudo rmmod snd-hda-codec-cs420x && sudo modprobe snd-hda-codec-cs420x
```

---

## Next Directions to Try

In rough priority order:

1. **Investigate the crash.** The machine crashed during the first test of the PCM
   hook. Check `/var/log/kern.log` or `journalctl -k` for a kernel oops/BUG
   before the crash. The hook may be accessing codec internals at an unsafe time,
   or there may be a locking issue. If the crash is in the hook, it needs to be
   fixed before the approach can be validated.

2. **Check whether `AC_DIG1_ENABLE` needs to be set at stream-open time via a PCM
   hook** rather than at `HDA_FIXUP_ACT_INIT`. The init approach sets it once;
   power management cycles may clear it. The PCM hook is the right architectural
   answer but needs the crash fixed first.

3. **Identify the I²C amplifier definitively.**
   `i2cget -y 0 0x44 0x60` — if it returns something, this is TAS5766M (page 0,
   reg 0x60 is device ID). Knowing the chip family will clarify whether it needs
   Linux-side I²C initialisation or whether EFI state persists across warm boots.

4. **Verify the I²S signal reaches the amp.** If the PCM hook runs without
   crashing but still no sound, use a logic analyser or oscilloscope on the I²S
   lines between the CS4208 and the amp at 0x44 to confirm data is being clocked.
   Without hardware visibility it is hard to know which stage is failing.

5. **Check CS4208 digital output format vs amp expectation.** The hook hardcodes
   format `0x4013` (44.1 kHz, 16-bit, 4-channel). If the amp expects a different
   sample rate, bit depth, or BCK ratio, it will be silent even if I²S clocks are
   present.

6. **Extract CS4208 init data from `AppleHDA.kext`.** Hackintosh community sources
   may have a parsed version of the macOS codec init tables. The `play_a1534()`
   sequence we've reverse-engineered may be incomplete.

---

## Reference: Kernel Log Markers

When testing, look for these in `dmesg`:

```
snd_hda_intel: picked fixup for codec SSID 106b:6400
mb8_pcm_hook: node 0x02 GET_CONV=0x...
mb8_pcm_hook END: 0x0a CONV=0x... DIGI=0x... PWR=0x...
mb8_pcm_hook CLEANUP: 0x0a CONV=0x...
```

If the hook is running but CONV on 0x0a is 0x00 at END, the stream tag mirror
is not taking. If CONV shows the expected tag but still no sound, the problem is
downstream (amp, I²S format, or amp init).
