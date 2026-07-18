# Storyboard A — integrated architecture/data flow

**Format:** Accessible static SVG, landscape desktop variant with responsive viewBox (1600×1280) and a dedicated stacked mobile variant.
**Purpose:** Give a newcomer a correct one-glance map of boundaries and direction.
**Thesis:** “Distinct sources converge on a shared processing layer; storage, device transport, and server sync are separate paths.”

## Composition

- Header: title plus one-line thesis.
- Left third: **Inputs** lane with separate cards: Polar H10, EMAY Oximeter, Apple Health / HealthKit, Oura Cloud, Oura BLE (feature-gated), CPAP/imported records, and fictional demo fixtures. Each card has a source label and a short qualifier.
- Center: large **AnxietyWatchKit** container. Inside, top-to-bottom: BLE/HealthKit adapters → `SensorRouter` → CNS pipeline/coordinator → monitoring view models. Use labeled arrows; no source is allowed to visually merge into another source card.
- Bottom center: **Storage and outputs** row: GRDB/local storage, complication cache, and iPhone/watch presentation. The cache/output arrow is distinct from persistence.
- Right: **Transport and mirror** lane: WatchConnectivity transport and server mirror. Use a dashed boundary around transport, and an arrow from app/kit sync to server mirror.
- Small “legacy coexistence during rollout” note is optional and subordinate; if shown, it must say coexistence rather than implying duplication is the final architecture.

## Sequence (reading order, even though static)

1. Read source cards left-to-right/top-to-bottom.
2. Follow solid arrows into the shared router and CNS processing.
3. Follow outputs down to UI/cache and separately right to device transport/server mirror.
4. Read the caption: “Source lanes remain distinct; demo fixtures are not production observations.”

## Text and accessibility

- `<title>`: “AnxietyWatch v3 architecture and data flow”.
- `<desc>` describes the source, processing, storage, transport, and server zones in reading order.
- Every arrow has a visible text label or adjacent label; direction is not conveyed by color alone.
- Add a hidden or adjacent text summary matching `README.md`.
- Use a minimum 16px equivalent label size at intrinsic size; at narrow display, allow vertical stacking rather than shrinking to illegibility.

## Factual constraints

- Do not draw Oura BLE as a confirmed live production path; label it “feature-gated; hardware-dependent.”
- Do not draw demo fixtures into production storage or HealthKit. If included as a source card, route it to a clearly bounded demo lane or annotate “display fixtures only.”
- Show the server as a mirror, not a source-of-truth replacement.
- Do not invent a completed watch-to-phone behavior beyond the package’s WatchConnectivity transport foundation.

## Render acceptance

- At 320/768/1024/1280px equivalent display widths: no clipping, labels remain readable, or cards stack.
- Every arrow remains attributable after reflow.
- Color-blind review: source/status semantics survive grayscale.
- No animated-only information.
