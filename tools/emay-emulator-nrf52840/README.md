# EMAY SleepO2 emulator (nRF52840 dongle) — CNS-klaxon test rig

A self-contained fake EMAY SleepO2 for the **Raytac MDBT50Q-CX (nRF52840)**
USB-C dongle. It advertises the EMAY GATT (`FF12`/`FF01`/`FF02`) and streams a
**scripted desaturation** so the AnxietyWatch CNS-depression detection pipeline
can be driven end-to-end — a hypoxia trajectory no real device could (or should)
produce on a person.

> **What this tests:** the *detection* escalating `clear → watch → confirm →
> klaxon`. It does **not** make a sound — the audible/haptic klaxon is Phase 3
> (`CNSMonitoringCoordinator` currently only sets the tier state and persists
> the edge: *"tier-edge is the hook point for klaxon/haptic escalation … Phase 2
> triggers no alerting itself"*). You verify the **Tier** field, not your ears.

No host is needed at run time — the dongle only needs **USB power** (a Mac port
or any USB charger near the phone).

---

## 1. Build & flash (one time, needs a Mac/Linux with the toolchain)

Prereqs: the **nRF Connect SDK** (provides `west` + a Zephyr toolchain) and
**`nrfutil`** with the `nrf5sdk-tools` command. (Install nRF Connect SDK per
Nordic's docs; `nrfutil install nrf5sdk-tools`.)

```bash
cd tools/emay-emulator-nrf52840

# Build for the Raytac dongle (upstream Zephyr board target)
west build -b raytac_mdbt50q_cx_40_dongle/nrf52840

# Package for the pre-loaded Open DFU bootloader
nrfutil nrf5sdk-tools pkg generate \
  --hw-version 52 --sd-req 0x00 \
  --application build/zephyr/zephyr.hex \
  --application-version 1 emay-emu.zip

# Put the dongle in DFU: hold the side button while plugging it into USB.
# The button is on the far side from the USB connector and faces sideways —
# push it *toward* the connector. The red LED starts a slow fade = bootloader.

# Flash (macOS port looks like /dev/tty.usbmodemXXXX — `ls /dev/tty.usbmodem*`)
nrfutil nrf5sdk-tools dfu usb-serial -pkg emay-emu.zip -p /dev/tty.usbmodemXXXX
```

After flashing, replug the dongle normally (no button). It boots the emulator
and starts advertising as **`SleepO2-SIM`**.

> If `west build` errors on `BT_LE_ADV_CONN` (removed on very new NCS), change
> that one symbol in `src/main.c` to `BT_LE_ADV_CONN_FAST_1`.

## 2. Run the test (on the iPhone — **wait for the go-ahead**)

1. Keep your **real EMAY oximeter off / out of range** during the test — the app
   connects to the first `FF12` peripheral it sees, so two would collide.
2. Power the dongle (any USB port/charger near the phone).
3. Open **AnxietyWatch → Settings → CNS Monitoring**.
4. Tap **"Monitor me now."** Arming calls `emayService.start()`, which scans for
   `FF12` and auto-connects to the dongle. (Approve the Bluetooth prompt if asked.)
5. Watch the **Tier** field. Expected timeline (~5.5 min/loop):

| Time | SpO₂ streamed | Expected Tier |
|------|---------------|---------------|
| 0:00–0:45 | 97 | **clear** (status leaves "can't assess" once the 30 s quality gate fills) |
| 0:45–1:05 | 97 → 80 | clear → **watch** |
| 1:05–3:05 | ~80 | watch → **confirm** → **klaxon** |
| 3:05–5:40 | 97 | back to **clear** (120 s clear-sustain) |

Then it loops. `Status`/`Reporting sources` should show the EMAY oximeter as
reporting throughout.

## 3. Troubleshooting

- **App won't find the dongle:** it must advertise `FF12` (it does) and a name
  starting with `SleepO2` (it's `SleepO2-SIM`). Confirm with Apple's *nRF
  Connect* or *LightBlue* app — you should see `SleepO2-SIM` exposing `FF12`.
- **Reflashed a changed GATT and the app misbehaves:** iOS caches service
  discovery per-peripheral. Toggle iPhone Bluetooth off/on (or "Forget" it) to
  clear the cache.
- **Tier never leaves clear:** the quality gate needs ~30 s of contiguous ≤3 s-gap
  samples before it can assess; make sure notifications are flowing (the LED
  toggles once per frame) and give it the first minute.
- **Logs:** if the board's console is on USB-CDC, `LOG_INF` lines appear on the
  serial port; not required — the iPhone UI is the source of truth.

## Editing the scenario

`SCENARIO[]` in `src/main.c` is a list of `{second, SpO₂, pulse}` keyframes,
linearly interpolated and looped. Change the values (keep SpO₂ in 1–100; `0x00`
and `0xFF` are the "no-finger" sentinels the app treats as no-data), rebuild,
reflash. Ideas: a benzo-style shallow-but-not-terminal plateau, an artifact
dropout (stream `0xFF` for SpO₂ for a few seconds to prove "invalid contributes
nothing"), or a gap that must *not* satisfy a sustain window.

## Protocol reference (mirrored from `EMAYRealtimeService.swift`)

- Service `FF12`; write `FF01` (with response); notify `FF02`.
- Data frame (8 bytes): `EB 01 05 [PR] [SpO2] 7F 00 [cks]`, `cks = sum(first 7) & 0x7F`.
- e.g. SpO₂ 80, PR 52 → `EB 01 05 34 50 7F 00 74`.
- The app writes a start sequence + ~1.5 s heartbeat to `FF01`; the emulator
  accepts all writes and streams once the app subscribes to `FF02`.
