# PR #16 visual aids

**Status:** Rendered package for the merged [PR #16](https://github.com/chenders/AnxietyWatch/pull/16).
**Director substitution:** GPT-5.6 Luna served as Visual Director because Claude Opus was unavailable.

## Minimum sufficient set

The package contains three static aids. Each has a desktop and a dedicated stacked mobile variant; the mobile files are reflowed compositions, not reduced desktop copies.

| Aid | Desktop | Mobile | Purpose |
|---|---|---|---|
| Architecture/data flow | `rendered/architecture.svg` / `.png` (1600×1280) | `rendered/architecture-mobile.svg` / `.png` (720×2338) | Separates the active iPhone package pipeline, watch HealthKit-only runtime, app-data paths, storage/sync foundations, and phased transport migration. |
| Source provenance and demo safety | `rendered/provenance.svg` / `.png` (1600×960) | `rendered/provenance-mobile.svg` / `.png` (720×1815) | Distinguishes Oura Cloud, Apple Health, Polar, EMAY, CPAP, Oura BLE, simulated device observations, seeded fixtures, and the scripted CNS UI demo. |
| Representative redesign surfaces | `rendered/ui-montage.svg` / `.png` (1470×1570) | `rendered/ui-montage-mobile.svg` / `.png` (720×4955) | Shows four readable fictional simulator surfaces: Dashboard, Oura, Trends, and Journal, without implying the comprehensive walkthrough is complete. |

Video, GIF, carousel, and a full gallery were rejected: these relationships benefit from reader-controlled inspection, and motion would increase accessibility cost and risk overstating unfinished walkthrough or production-alert behavior.

## Reproduction

From the repository root:

```bash
python3 docs/pr16-visuals/source/generate_assets.py
```

Requirements: Python 3, Pillow, and `rsvg-convert`. The generator embeds the reviewed WebP screenshot inputs into self-contained SVG montage outputs and renders all six PNGs.

The generator is the canonical editable source. Final SVG and PNG files under `rendered/` are publication assets. Multi-width review copies under `reviews/renders-iter*/` are local review evidence and are intentionally not published.

## Publication pattern

Use a `<picture>` element for each aid, selecting the `-mobile.png` source at narrow widths and the desktop PNG otherwise. Place a concise Markdown caption immediately beside each image. The adjacent text is intentional: at approximately 320 CSS pixels, the image is an overview and the caption remains the readable carrier of safety-critical qualifiers. Each image links to its full-resolution durable URL for inspection.

## Accessibility and data handling

- Meaning is carried by text, borders, arrows, symbols, and section headings—not color alone.
- SVG files provide `<title>` and `<desc>` metadata; publication supplies descriptive `alt` text and adjacent captions.
- Dedicated mobile compositions stack content in reading order.
- All montage values are deterministic fictional simulator content.
- Reviewed screenshot inputs contain no personal names, contact details, credentials, tokens, or device identifiers.
- The scripted CNS progression is demo-only: no production monitoring, real notification, diagnosis, or clinical certainty.
- Simulated Polar/EMAY observations start no production BLE/session, write no HealthKit data, and are not saved as readings. Seeded application fixtures are separately acknowledged as demo-store writes.
- Oura BLE is a feature-gated foundation requiring a 16-byte shared key; physical Ring 5 protocol, decryption, and key validation are not completed.

## Text alternatives

### Architecture

Three configured iPhone sources—Polar H10, EMAY Oximeter, and Apple Health—feed `SensorRouter`, then package event processing, fusion, tier state, and iPhone presentation. A separate watch HealthKit-only router drives the complication feed/cache. Oura Cloud, CPAP, deterministic fixtures, GRDB/HLC, existing server sync, WatchConnectivity, and Oura BLE are separate paths or foundations. Existing WatchConnectivity remains active while package watch migration is incomplete. HealthKit remains the physiological source of truth; the personal server is a push-oriented mirror.

### Provenance and safety

Oura Cloud, Apple Health, Polar H10, EMAY, and CPAP are distinct production/import sources. Oura BLE is separate and incomplete. Simulated Polar/EMAY observations do not activate production BLE or sessions, write HealthKit, or persist as readings. Seeded deterministic fixtures may be written to the demo store. The scripted CNS UI demonstration neither arms production monitoring nor sends a real notification and does not diagnose a condition.

### UI montage

Four large fictional simulator screenshots show Dashboard daily context, the Oura Cloud/demo summary surface, Trends, and Journal. They are representative redesign surfaces, not evidence of hardware validation or a completed comprehensive walkthrough.
