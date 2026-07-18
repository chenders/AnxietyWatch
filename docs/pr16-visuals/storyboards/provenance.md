# Storyboard B — source provenance and safe-demo boundary

**Format:** Accessible static SVG, landscape, responsive viewBox (1600×980).
**Purpose:** Prevent the reader from collapsing cloud, HealthKit, BLE, simulated values, and the CNS demo into one production data stream.
**Thesis:** “The UI names where a value came from—and demos stop at the boundary.”

## Composition

- Header: title plus thesis.
- Left half: **Production / imported source lanes**, each a separate labeled card:
  - Oura Cloud — daily summaries and wellness metrics.
  - Apple Health — HealthKit read/import source.
  - Polar H10 — hardware sensor path.
  - EMAY Oximeter — hardware/import path.
  - CPAP — imported/session data.
- Center vertical boundary: “source-aware presentation” with a legend that selected surfaces carry provenance; include “Oura BLE: feature-gated, 16-byte key required, Ring 5 behavior hardware-dependent.”
- Right top: **Full-app demo device session** box: “Polar H10 (Simulated)” and “EMAY Oximeter (Simulated)”; badges: deterministic, hardware-free, persistence-free. An exclusion list says: does not activate production BLE, open a production `SensorSession`, write HealthKit, or persist demo observations as real readings.
- Right bottom: **CNS monitoring demo** box: “Clear → Watch → Confirm → Klaxon (demo tier progression).” Exclusion list says: does not arm production monitoring, send a real notification/alert, or provide diagnosis.
- Bottom footer: “All shown values are fictional/deterministic for review.”

## Visual grammar

- Solid bordered cards = source or mode; dashed boundary = isolation; explicit “does not” rows use a barred icon plus text, never a red-only signal.
- Use source badges with both icon/shape and text. Oura Cloud and Oura BLE must not share an unlabeled “Oura” badge.
- Keep the CNS card visually calm: no alarm animation, siren motif, or clinical guarantee.

## Accessibility

- `<title>`: “AnxietyWatch source provenance and demo boundaries”.
- `<desc>` lists every source and every exclusion in reading order.
- Text alternative repeats all four negative claims for the demo paths.
- Maintain contrast for labels and boundaries; do not rely on tinted cards to communicate production versus demo.

## Factual constraints

- “Oura BLE” is not “Ring 5 validated.”
- “Oura Cloud” is not Apple Health and does not mean the value was observed live by BLE.
- Simulated Polar/EMAY values are not hardware readings.
- CNS escalation is a demonstration-only UI state; avoid “alert delivered” language.
- No clinical diagnosis or medical certainty.

## Render acceptance

- At narrow widths, production and demo columns stack in reading order: sources → source-aware presentation → demo boundaries.
- All exclusion text remains visible; no clipped “does not” wording.
- Grayscale and color-blind review preserve lane identity through labels and borders.
