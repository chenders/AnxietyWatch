# Visual Director review — iteration 3

**Reviewer:** Visual Director, GPT-5.6 Luna substitution (Claude Opus unavailable)
**Review date:** 2026-07-18
**Scope:** Actual PNGs inspected at intrinsic size:

- `docs/pr16-visuals/rendered/architecture.png`
- `docs/pr16-visuals/rendered/provenance.png`
- `docs/pr16-visuals/rendered/ui-montage.png`
- `docs/pr16-visuals/rendered/architecture-mobile.png`
- `docs/pr16-visuals/rendered/provenance-mobile.png`
- `docs/pr16-visuals/rendered/ui-montage-mobile.png`

Also inspected the actual iteration-3 review PNGs under `reviews/renders-iter3/{320,768,1024,1280}/`. No assets or source files were edited. `PROJECT_FUTURE_PLAN.md` was not read or used.

## Decision

# ITERATE

Iteration 3 closes the substantive architecture and terminology findings from iteration 2, and the dedicated mobile layouts are a major improvement. It is not yet approved for publication because the 320-pixel rendered mobile candidates still shrink the mobile source to a size where important explanatory text and safety qualifiers are not reliably readable. The acceptance criterion must be judged at the actual supplied narrow render, not only at the 720-pixel intrinsic mobile PNG or the 768-pixel review.

## Iteration-2 finding closure

### [CLOSED] Narrow/mobile layout architecture

Dedicated mobile assets now exist for all three aids and are genuinely stacked rather than desktop landscapes scaled into a narrow canvas:

- architecture: one-column iPhone pipeline, separate watch runtime, app data, and foundations;
- provenance: source list, Oura BLE qualifier, isolated demos, and seeded-fixture distinction in reading order;
- montage: one-column, large screenshot panels with captions and scope footer.

At 768, 1024, and 1280 review widths, the mobile assets are substantially more legible and preserve the intended hierarchy. The 320 render is structurally correct and unclipped, but the remaining legibility defect is recorded below as a blocking finding rather than treated as closed.

### [CLOSED] Actual package sequence

The architecture now visibly says:

`event step → fusion → tier state`

This is materially better aligned with the package implementation than the iteration-2 `quality → severity → fusion` wording. It appears in both desktop and mobile architecture renders and remains readable at 768 and above.

### [CLOSED] Explicit Oura BLE qualifier

The architecture and provenance mobile renders explicitly show:

- feature-gated foundation;
- 16-byte shared key required;
- physical Ring 5 protocol and decryption not completed;
- key validation not completed.

The desktop architecture and provenance renders also contain the same limitation, and the provenance footer repeats the incomplete physical-validation statement. This closes the requested precision finding. The qualifier remains outside the active iPhone monitoring pipeline.

### [CLOSED] Watch/runtime geometry

The desktop architecture now has a distinct `Separate watch runtime` card and a separate `Phased coexistence` card. The mobile architecture makes this separation even clearer:

- Apple Health / HealthKit-only watch router;
- complication feed and cache;
- explicit `Not an iPhone-view-model continuation`;
- active legacy WatchConnectivity path;
- package peer transport as foundation;
- incomplete watch migration.

This no longer reads as a single completed iPhone-to-watch-to-server chain. The personal server appears under `Existing app sync`, separately from the watch runtime.

### [CLOSED] Three live connectors

The desktop architecture shows three distinct source cards—Polar H10, EMAY Oximeter, and Apple Health—with separate visible connector paths into the shared `SensorRouter`. The mobile architecture makes the connectors explicit in each card’s detail line:

- `Polar H10 — BLE actor → router`;
- `EMAY Oximeter — BLE actor → router`;
- `Apple Health — HealthKit read adapter → router`.

The three are therefore not merely listed as inputs; each is visibly associated with the active iPhone router. Oura Cloud, CPAP, deterministic fixtures, Oura BLE, and watch runtime remain outside that active connector set.

### [CLOSED] Other iteration-2 factual and continuity corrections

- Oura Cloud, CPAP, and deterministic fixtures are separated into app-data/presentation paths.
- GRDB/HLC, existing app sync, and Oura BLE are separated as foundations rather than one completed chain.
- The architecture states that demo-device observations do not enter the production router, HealthKit, or production sensor sessions.
- Provenance wording remains bounded to selected surfaces rather than claiming every metric is labeled.
- Apple Health is correctly described as a separate HealthKit read/import source.
- CNS demo copy distinguishes scripted demo labels from production tier naming and states no production monitoring, real notification, diagnosis, or clinical certainty.
- Seeded application fixtures are distinguished from simulated device observations.
- Montage scope remains `Representative surfaces only`; the comprehensive walkthrough is explicitly incomplete.

## Blocking finding

### [BLOCKER] VD3-1 — 320-pixel mobile renders still do not meet reliable narrow readability

**Artifacts:**

- `reviews/renders-iter3/320/architecture-mobile.png`
- `reviews/renders-iter3/320/provenance-mobile.png`
- `reviews/renders-iter3/320/ui-montage-mobile.png`

The dedicated mobile layouts solve the composition problem, but the supplied 320 renders are still scaled copies of a 720-pixel-wide mobile source. The 320 architecture render preserves the title and section headings, but important body copy—especially the watch migration qualification, Oura BLE limitation, and source-of-truth footer—is visibly tiny and OCR is fragmentary. The provenance 320 render loses or corrupts substantial qualifier/exclusion text in OCR, including parts of the Oura BLE and simulated-session statements. The montage retains the four-panel sequence and scope footer, but its embedded UI is still thumbnail-scale and several screenshot labels/details are not comfortably inspectable at a real 320-pixel display width.

This is not a claim that the assets are clipped: they are not. It is a readability/accessibility finding. The requirement is that narrow review output remain useful to a newcomer, not merely complete and technically present. At 768 and above, the mobile variants are acceptable; at 320, the body text is below a comfortable reading size and the most safety-critical qualifiers are not dependable without opening the image or zooming.

**Required closure:** either:

1. provide a further narrow variant designed specifically for approximately 320 CSS pixels, with shorter high-priority copy and a layout/font scale that remains readable at that width; or
2. publish the mobile PNG as a linked/openable asset while ensuring the in-page 320 presentation has adjacent HTML/Markdown text carrying the full safety and provenance claims, and document that the image is an overview at 320 rather than the sole carrier of those claims.

Do not close this by relying on SVG `<desc>` metadata or by asserting that intrinsic 720-pixel inspection is equivalent to the 320 rendered page.

## Composition and accessibility assessment

### [PASS] Desktop narrative continuity

The sequence is now coherent:

1. active iPhone monitoring and the three live connectors;
2. separate watch runtime and phased migration;
3. separate app data and foundations;
4. source-aware/demo boundaries;
5. representative UI surfaces.

The desktop architecture at 1600×1280 has enough vertical space for the qualifiers and avoids the former dense right-edge transport stack. The desktop provenance aid preserves distinct source labels, a calm isolation boundary, and non-color symbols. The desktop montage is a concise four-surface overview with a clear fictional-data and incomplete-walkthrough footer.

### [PASS WITH CONDITION] Color independence and status meaning

Text, borders, arrows, symbols, and section labels carry the main meaning; color is not the sole carrier. The provenance legend uses distinct symbols for Oura Cloud, Apple Health/import, live sensor, and demo/simulated. The condition is that publication retain adjacent alt text/captions and not depend on a reader opening the 320 image to recover tiny text.

### [PASS] Privacy and factual guardrails visible in rendered pixels

The inspected montage pixels contain deterministic fictional values and no apparent personal identifiers. The visible disclosures correctly avoid claims of hardware validation, clinical diagnosis, production alert delivery, or completed comprehensive walkthrough. This review does not replace the required artifact-level privacy clearance, but no new rendered privacy issue was found.

## Acceptance criteria for iteration 4

1. The 320-pixel presentation of architecture and provenance keeps the Oura BLE qualifier, watch migration status, demo exclusions, and source-of-truth/server-mirror distinction readable without zoom; the montage remains a meaningful UI preview.
2. The same content remains readable at 768 and is rechecked at 1024 and 1280.
3. The three live connector paths remain explicit and distinct after any narrow adjustment.
4. `event step → fusion → tier state`, the 16-byte key requirement, and incomplete physical Ring 5 validation remain unchanged.
5. No new direct iPhone-to-watch or WatchConnectivity-to-server implication is introduced.
6. Independent rendered review is repeated against the revised pixels.

## Final verdict

**ITERATE — do not publish or embed the current iteration-3 assets yet.**

Iteration 3 closes the iteration-2 technical findings, but the 320 rendered mobile outputs still make important content too small to serve as a dependable narrow-width newcomer aid. No assets were edited during this review.
