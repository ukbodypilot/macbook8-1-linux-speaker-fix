# MacBook8,1 Speaker Fix — Investigation Log

Chronological notes. Most recent at the bottom.

---

## Session 1 (2026-03-11): Initial Investigation

**Hardware confirmed:**
- MacBook8,1 (12-inch Early 2015, A1534)
- Codec: Cirrus Logic CS4208, SSID `0x106b6400`
- Kernel: 6.17.0-14-generic (Ubuntu)
- Windows partition accidentally erased during this session — Linux only from now on

**Findings:**
- Headphones work (pin 0x10, analog, node 0x02 DAC)
- EFI boot chime plays through speakers — hardware 100% functional
- HDA controller reset wipes EFI state before Linux driver loads
- `cs4208_mac_fixup_tbl` does not contain SSID `0x106b6400` — no MacBook8,1 entry
- `model=mbp11` was set in `/etc/modprobe.d/snd-hda-macbook.conf`
- With `model=mbp11`: pins 0x11–0x14 appear as Speaker Fixed Int outputs
  (we later discovered this was the model override fabricating those nodes — they
  are actually Not Connected)

**Things tried (all silent):**
- model=mbp11, mba6, mbp101, gpio0, auto
- GPIO[0]=1 via hda-verb (already set by driver via cs_automute)
- `cs4208_coef_init_verbs` manually: coeff[0x33]=0x0001, coeff[0x34]=0x1C01
- VPW: SET_PROC_STATE=1 (enable DSP) — no effect
- Unmuting all mixer channels
- ACPI _PS0 via acpi_call
- speaker-test -c2 and -c6

**Working hypothesis at end of session:**
DSP on node 0x24 is uninitialised — Linux driver applies 2 coefficients
(0x33/0x34) but macOS/Windows likely programs many more. The uninitialised DSP
blocks the speaker path. Plan: kernel patch to disable VPW for this SSID.

---

## Session 2 (2026-03-12, early): Architecture Discovery

**Critical correction to session 1 findings:**

Removed `model=mbp11` from modprobe.d. With the model override gone, `autoconfig`
now reports correctly:

```
autoconfig: line_outs=1 (0x1d) type:speaker
speaker_outs=0
hp_outs=1 (0x10)
```

Pins 0x11–0x14 are **Not Connected** (pin default `0x400000f0`). They were only
appearing active because `model=mbp11` was running its own fixup that overrode
the SSID-based selection. All session 1 work involving those nodes was based on
a false premise.

**Real speaker signal path discovered:**
```
Node 0x0a  (8-channel DIGITAL output, wcaps=0x406301, AC_WCAP_DIGITAL set)
    │
    └─▶  Pin 0x1d  (Fixed/Int Speaker, pin-ctl=0x40 OUT, DefAssoc=1 Seq=0)
             │
             └─▶  I²C amp at address 0x44 on i2c-0 (SMBus I801)
                      │
                      └─▶  Physical speakers
```

Pin 0x1d details:
- Pin Default: `0x90100110` = [Fixed] Speaker at Int
- wcaps: `0x406301` (8-channel, digital)
- Connected to node 0x0a (digital output converter)
- pin-ctl: `0x40` (OUT enabled)

Node 0x0a details:
- AC_WCAP_DIGITAL is set
- HDA generic layer uses it as the "DAC" for pin 0x1d (correctly identified)
- BUT: `snd_hda_codec_setup_stream()` only writes stream tag + format for digital
  nodes. It does NOT set `AC_DIG1_ENABLE` unless the node is in an explicit SPDIF
  path. So node 0x0a receives a stream assignment but the digital enable bit is
  never set → output is dead.

**Why AC_DIG1_ENABLE matters:**
The bit enables the digital converter to actually clock out data. Without it, the
converter sits idle regardless of what stream is assigned. The HDA spec requires
this bit for any digital converter to produce output.

**Two-stage fixup selection (confirmed expected):**
Kernel log shows "picked fixup" twice for hdaudioC0D0:
1. Vendor match `106b:0000` → CS4208_MAC_AUTO → cs4208_fixup_mac
2. SSID match `106b:6400` → CS4208_MACBOOK8_1 → our custom fixup

This is normal. The first match happens before the codec fully probes (vendor ID
`0000`); the second after the SSID is resolved.

**SMBus I²C amp (address 0x44):**
```
i2cget -y 0 0x44 0x00  → 0x00  (page select)
i2cget -y 0 0x44 0x03  → 0x04
i2cget -y 0 0x44 0x09  → (changing — live voltage/status monitor)
i2cget -y 0 0x44 0x0a  → (changing)
i2cget -y 0 0x44 0x0c  → 0x04
i2cget -y 0 0x44 0x0d  → 0x12
i2cget -y 0 0x44 0x0e  → 0x03
i2cget -y 0 0x44 0x0f  → 0x26
```
Chip identity unconfirmed. Possibly TAS5766M.
`i2cset -y 0 0x44 0x01 0x01` (software reset) — amp still responds after reset.
EFI boot chime proves amp is in functional state; may not need Linux-side init.

---

## Session 2 (2026-03-12, mid): First Patch — Simple AC_DIG1_ENABLE

**Patch approach:**
Add `CS4208_MACBOOK8_1` fixup that runs at `HDA_FIXUP_ACT_INIT`:
1. Disable VPW (`SET_PROC_STATE=0x00` on node 0x24) — removes uninitialised DSP
2. Set `AC_DIG1_ENABLE` on node 0x0a (`AC_VERB_SET_DIGI_CONVERT_1 = 0x01`)
3. Chain to `CS4208_GPIO0` (sets GPIO[0]=1 for speaker EAPD)

**Result: No sound.**

The enable bit approach is correct in principle but insufficient. At `ACT_INIT`
time the HDA generic layer has not yet assigned a stream to node 0x0a. The node
gets `AC_DIG1_ENABLE` set but stream tag = 0 (no DMA stream). Without a real DMA
stream, node 0x0a generates no I²S clocks and the amp at 0x44 receives nothing.

Also tested at this stage:
- VPW-disable only (without AC_DIG1_ENABLE) → no sound
- `i2cset 0x44 0x01 0x01` (amp software reset) → amp still responds, still silent

---

## Session 2 (2026-03-12, late): macOS Reverse Engineering — PCM Hook

**Approach: Reverse-engineer macOS `play_a1534()` and reproduce in a PCM hook.**

Key insight from macOS driver analysis:
- macOS assigns HDA stream tag 1 to **both** node 0x02 (analog DAC) and node 0x0a
  (I²S digital output). Both share the same DMA stream.
- On Linux, the HDA core assigns a dynamic stream tag to node 0x02. We read it
  back and mirror it onto node 0x0a — exactly what macOS does.
- Without a real stream tag on 0x0a, there is no PCM data and no I²S clocks.

**macOS sequence reconstructed (play_a1534 / headphones_a1534):**
1. AFG + node 0x0a → D0
2. Toggle DIGI_CONVERT_1 0x01→0x00 (reset converter)
3. SET_STREAM_FORMAT = 0x4013 (44.1kHz, 16-bit, 4ch)
4. DIGI_CONVERT_1 = 0x01 (AC_DIG1_ENABLE)
5. DIGI_CONVERT_2 = 0x01
6. DIGI_CONVERT_1 = 0x11 (AC_DIG1_ENABLE | AC_DIG1_COPYRIGHT)
   - NOTE: `AC_DIG1_NONAUDIO` is bit5=0x20; macOS uses bit4=0x10 (COPYRIGHT)
7. SET_CHANNEL_STREAMID = (stream tag of node 0x02)
8. SET_PROC_STATE = 0x01 twice (VPW enable — two back-to-back writes as macOS does)
9. SET_POWER_STATE = D3
10. DIGI_CONVERT_1 = 0x10 (AC_DIG1_COPYRIGHT only — ENABLE cleared before vendor verb)
11. Vendor verb 0x7f0 = 0x03 (triggers I²S master clock generator)
12. SET_POWER_STATE = D0
13. DIGI_CONVERT_1 = 0x11 (restore ENABLE|COPYRIGHT)
14. SET_CHANNEL_STREAMID = (stream tag again)
15. Enable sibling digital nodes 0x0b/0x0c/0x0d (ENABLE, zero stream tag, park D3)
16. SET_CONNECT_SEL on pin 0x1d = 0x00
17. DIGI_CONVERT_2 on 0x0a = 0x01
18. DIGI_CONVERT_1 on 0x0a = 0x11
19. SET_PIN_WIDGET_CONTROL on 0x1d = PIN_OUT (0x40)
20. GPIO: direction=0x31, data=0x01, mask=0x37

**Implementation:** PCM hook `cs4208_mb8_pcm_hook` registered at
`HDA_FIXUP_ACT_PRE_PROBE` via `spec->gen.pcm_playback_hook`. Hook fires at
`HDA_GEN_PCM_ACT_PREPARE` (after HDA generic layer sets stream format on node
0x02). Hook also logs node 0x0a state at END and CLEANUP for debugging.

**Module built, installed, loaded.** Kernel log confirms:
```
snd_hda_intel: picked fixup for codec SSID 106b:6400
```

**Test result: MACHINE CRASHED.**

The machine crashed during or immediately after `speaker-test`. The crash occurred
before we could determine whether sound was produced. Root cause unknown.

Possible crash causes:
- `cs4208_mb8_pcm_hook` accessing codec internals at an unsafe time or with wrong
  locking (codec mutex not held when it should be, or held when it shouldn't be)
- Race condition between hook and HDA generic layer PCM operations
- Unrelated kernel/hardware issue (coincidental crash)

**We stopped here.** 24 hours of investigation, machine is unstable. Suspending
work to resume later.

---

## What Needs to Be Done Next

In priority order:

1. **Check crash logs** — `journalctl -k -b -1` or `/var/log/kern.log` from the
   crashed session. If there is a kernel oops/BUG trace, it will point directly to
   what went wrong in the hook.

2. **Fix any locking issues in the PCM hook** — The hook receives a `struct
   hda_codec *codec` but does not hold the codec mutex. `snd_hda_codec_write()`
   acquires it internally so that should be fine, but verify no double-lock or
   use-after-free is possible at PREPARE time.

3. **Validate stream tag mirroring** — Before re-testing with speakers, add a
   `dmesg` check: confirm node 0x0a `GET_CONV` after the hook matches node 0x02
   `GET_CONV` before the hook. If they match, stream tag mirroring is working.

4. **Identify the I²C amp definitively** — Try:
   ```bash
   i2cget -y 0 0x44 0x60   # TAS5766M device ID register (page 0)
   ```
   If it returns a non-0xFF value, this is TAS5766M. Knowing the chip tells us
   whether it needs an I²S enable sequence from Linux.

5. **Check digital output format compatibility** — The hook hardcodes format
   `0x4013` (44.1kHz, 16-bit, 4ch). If the amp expects something different
   (e.g., 48kHz, or a different BCK ratio), it will be silent even if I²S clocks
   are present. macOS may use a different format — worth checking `play_a1534()`
   more carefully.

6. **Consider whether VPW should be enabled or disabled** — The hook currently
   enables VPW (SET_PROC_STATE=0x01, twice, matching macOS). The earlier ACT_INIT
   approach disabled it. macOS enables VPW, so the hook approach is more faithful.
   But if VPW with uninitialised coefficients is the crash trigger, try disabling
   it in the hook instead.
