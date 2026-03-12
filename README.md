# MacBook8,1 Linux Internal Speaker Fix

**Hardware:** Apple MacBook8,1 (12-inch Early 2015)
**Codec:** Cirrus Logic CS4208
**Kernel:** 6.17.0-14-generic (Ubuntu)
**Status:** Patch built and under test

## Problem

Internal speakers are completely silent on Linux. Headphones work. The EFI boot chime plays correctly through the speakers, confirming the hardware is functional — the problem is in how the Linux kernel initialises the CS4208 codec.

## Root Cause Analysis

The `snd-hda-codec-cs420x` driver's `cs_init()` always enables VPW (DSP processing) on node 0x24 via `SET_PROC_STATE=1`. For MacBook models that **are** in `cs4208_mac_fixup_tbl`, macOS has presumably pre-initialised all 128 DSP coefficients before Linux ever loads. The MacBook8,1 SSID (`0x106b 0x6400`) is **not** in that table, so no machine-specific fixup runs.

With VPW enabled but DSP coefficients at power-on defaults, the uninitialised DSP appears to block the speaker output path entirely.

## The Patch

`kernel-patch/cs420x.c` is a patched version of `sound/hda/codecs/cirrus/cs420x.c` that:

1. Adds `CS4208_MACBOOK8_1` to the fixup enum
2. Adds `SND_PCI_QUIRK(0x106b, 0x6400, "MacBook8,1", CS4208_MACBOOK8_1)` to `cs4208_mac_fixup_tbl`
3. Adds a fixup function `cs4208_fixup_macbook8_1()` that runs at `HDA_FIXUP_ACT_INIT` phase (after `cs4208_coef_init_verbs` are applied) and disables VPW processing (`SET_PROC_STATE=0`), bypassing the uninitialised DSP
4. Chains to `CS4208_GPIO0` for the standard speaker EAPD GPIO setup

## Building the Patch

### Prerequisites

```bash
sudo apt install linux-source-$(uname -r | cut -d- -f1,2) linux-headers-$(uname -r)
```

### Build

```bash
bash build-cs4208-patch.sh
```

The script extracts `cs420x.c` from the kernel source tarball, applies the patch, builds the module out-of-tree, and installs it.

### Manual install (if script not used)

```bash
# Backup original
sudo cp /lib/modules/$(uname -r)/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst \
        /lib/modules/$(uname -r)/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst.bak

# Install patched module
sudo zstd -f snd-hda-codec-cs420x.ko \
           -o /lib/modules/$(uname -r)/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst
sudo depmod -a

# Hot-reload
sudo rmmod snd-hda-codec-cs420x snd-hda-intel snd-hda-core
sudo modprobe snd-hda-codec-cs420x
sudo modprobe snd-hda-intel

# Test
speaker-test -c 2 -t wav
```

### Revert

```bash
sudo cp /lib/modules/$(uname -r)/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst.bak \
        /lib/modules/$(uname -r)/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko.zst
sudo depmod -a
```

## What Has Been Tried (Do Not Retry)

- All ALSA model strings: `mbp11`, `mba6`, `mbp101`, `gpio0`, `auto` — all silent
- GPIO[0]=1 via hda-verb (already set by driver via `cs_automute`)
- Manually applying `cs4208_coef_init_verbs` (coeff 0x33/0x34) — no effect
- Enabling VPW processing manually (`SET_PROC_STATE=1`) — no effect
- Unmuting all mixer channels — no effect on speakers
- ACPI `_PS0` call via `acpi_call` — no effect

## Codec Layout (CS4208 on MacBook8,1)

| Node | Function | Notes |
|------|----------|-------|
| 0x10 | HP Out (Jack, Ext Left) | **Working** — headphones |
| 0x11 | Speaker (Fixed, Int) | → DAC 0x02 |
| 0x12 | Speaker (Fixed, Int) | → DAC 0x03 |
| 0x13 | Speaker (Fixed, Int) | → DAC 0x04 |
| 0x14 | Speaker (Fixed, Int) | → DAC 0x05 |
| 0x24 | Vendor DSP Widget | 128 coefficients |

## Modified Files on System

| File | Purpose |
|------|---------|
| `/etc/modprobe.d/snd-hda-macbook.conf` | `options snd-hda-intel model=mbp11 power_save=0` |
| `/lib/firmware/hda-macbook8.fw` | ALSA patch firmware (GPIO verbs — ineffective, can be removed) |
| `/etc/systemd/system/macbook-speaker-gpio.service` | Sets GPIO[0]=1 on boot (redundant — kernel does this) |

## SMBus

- Device `0x08`: likely Apple SMC
- Device `0x44`: unknown — could be speaker amp, not yet investigated

## Next Steps If Patch Fails

1. Boot a Windows PE USB, let Cirrus driver initialise codec, capture all 128 DSP coefficients from node 0x24, replay in Linux
2. Extract CS4208 init data from `AppleHDA.kext` (hackintosh community sources)
3. Investigate SMBus device `0x44` — may be an external speaker amp requiring separate init
4. Submit patch upstream to linux-sound mailing list if successful

## Kernel Version

Built against: `6.17.0-14-generic`
Source: `/usr/src/linux-source-6.17.0/linux-source-6.17.0.tar.bz2`
