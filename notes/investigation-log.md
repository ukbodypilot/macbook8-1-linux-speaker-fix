---
name: MacBook8,1 Speaker Audio Fix - Work in Progress
description: Ongoing investigation to fix internal speakers on MacBook8,1 running Linux
type: project
---

## Hardware
- Machine: Apple MacBook8,1 (12-inch MacBook Early 2015)
- Codec: Cirrus Logic CS4208 (subsystem 0x106b6400, but kernel sees 106b:0000 at initial boot)
- Kernel: 6.17.0-14-generic (Ubuntu)
- Linux only (Windows partition accidentally erased 2026-03-11)

## Files modified/created
- `/etc/modprobe.d/snd-hda-macbook.conf` → `options snd-hda-intel model=mbp11 power_save=0`
- `/lib/firmware/hda-macbook8.fw` → ALSA patch firmware (GPIO verbs — ineffective, can be removed)
- `/etc/systemd/system/macbook-speaker-gpio.service` → sets GPIO[0]=1 on boot (enabled but REDUNDANT — kernel now does this via cs_automute)

## What works
- Headphones (via pin 0x10, HP Out at Ext Left)
- All speaker pins 0x11–0x14 enabled (Pin-ctls: 0x40: OUT) via model=mbp11
- GPIO[0]: enable=1, dir=1, data=1 — set by driver (cs_automute in cs420x kernel module)
- DAC nodes 0x02–0x05 all unmuted (Amp-Out vals: 0x6a), all assigned to stream=5
- 6-channel playback routes all 4 DACs simultaneously

## What does NOT work
- Internal speakers — completely silent in all configurations tried

## What has been exhaustively tried (do NOT retry these)
- model=mbp11 (current), model=mba6, model=mbp101, model=gpio0, model=auto — all silent
- GPIO[0]=1 via hda-verb (systemd service) — already set by driver, no effect
- Manually applying cs4208_coef_init_verbs: coeff[0x33]=0x0001, coeff[0x34]=0x1C01 — no effect
- Enabling VPW processing (node 0x24 SET_PROC_STATE=1) — no effect
- Unmuting all mixer channels (Front/Surround/Center/LFE/Side) — no effect on speakers
- ACPI _PS0 call via acpi_call — no effect
- speaker-test with 2-channel and 6-channel — silent
- amixer unmute + 100% volume on all channels — no effect

## Key findings from kernel source analysis
- Kernel module: `snd-hda-codec-cs420x` at `/lib/modules/6.17.0-14-generic/kernel/sound/hda/codecs/cirrus/`
- model=mbp11 fixup: runs `cs4208_fixup_spdif_switch` + chains to `CS4208_GPIO0`
- CS4208_GPIO0 fixup sets: `gpio_eapd_speaker=1` (GPIO pin 0), `gpio_eapd_hp=0`
- MacBook8,1 SSID 0x106b6400 is NOT in `cs4208_mac_fixup_tbl` → falls to GPIO0 default
- `cs4208_coef_init_verbs` sets only 2 coefficients: coeff[0x33]=0x0001, coeff[0x34]=0x1C01
  - Comment: "A1 ICS" and "A1 Enable, A Thresh = 300mV" — may be the internal speaker amp stage

## Codec pin layout (CS4208 on MacBook8,1)
- Node 0x10: HP Out (Jack, Ext Left, Comb), has Amp-Out, DefAssoc=1 Seq=0xf → HEADPHONES
- Node 0x11: Speaker (Fixed, Int), Balanced, Detect, DefAssoc=1 Seq=0 → SPEAKER, connected to DAC 0x02
- Node 0x12: Speaker (Fixed, Int), DefAssoc=1 Seq=1 → connected to DAC 0x03
- Node 0x13: Speaker (Fixed, Int), DefAssoc=1 Seq=2 → connected to DAC 0x04
- Node 0x14: Speaker (Fixed, Int), DefAssoc=1 Seq=4 → connected to DAC 0x05
- Node 0x24: Vendor Defined Widget, 128 DSP coefficients

## DSP coefficients from node 0x24 (sampled state, may be unreliable to read from userspace)
- Coefficients at 0x24–0x35 range contain DSP filter values (0x9f9f, 0x1f1f, 0xfbaa patterns)
- CAUTION: coefficient reads from userspace are unreliable — kernel accesses same widget simultaneously causing index auto-increment race condition

## Remaining hypothesis: DSP not initialized for MacBook8,1
- macOS/Windows likely programs many MORE coefficients in node 0x24 to enable the speaker output path
- The Linux driver only sets 2 coefficients (0x33/0x34) which may be insufficient
- MacBook8,1 speakers may use BTL (Bridge-Tied Load) configuration requiring specific DSP routing

## SMBus
- Device at 0x08 (likely Apple SMC)
- Device at 0x44 (unknown — could be speaker amp or sensor, not yet identified)

## Card numbering
- PCH / CS4208 card index can be 0 or 1 depending on probe order
- Check: `aplay -l | grep CS4208` or `ls /dev/snd/hwC*`
- hwdep path: hwC{N}D0 where N = card number of CS4208

## New finding (2026-03-11)
- Boot chime plays correctly through speakers — hardware confirmed working
- EFI initializes the codec correctly; Linux driver breaks it during init
- HDA controller reset wipes EFI state before Linux driver can preserve it

## Blocked paths / things that won't work
- Capturing Windows codec state: Windows partition accidentally erased 2026-03-11
- Reading DSP coefficients from userspace while kernel driver is running: unreliable
- Standard ALSA model strings (mbp11/mba6/mbp101/gpio0): all tried, none work for speakers

## Most promising next directions (NOT YET TRIED)
1. Speculative kernel patch: add MacBook8,1 SSID to cs4208_mac_fixup_tbl with a fixup that
   skips cs4208_coef_init_verbs — test if driver's coef_init is what breaks EFI-good state
2. WinPE from USB: boot Windows PE live, Cirrus driver loads, capture coefficient state
3. Extract CS4208 init data from AppleHDA.kext (hackintosh community may have this)
4. Diagnostic kernel patch: dump all 128 node 0x24 coefficients before/after driver init
5. Identify I2C device 0x44 — may be a speaker amp needing separate init
