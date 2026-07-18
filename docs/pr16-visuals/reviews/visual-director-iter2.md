# Visual Director review — iteration 2

**Reviewer:** Visual Director, GPT-5.6 Luna substitution (Claude Opus unavailable)
**Review date:** 2026-07-18
**Scope:** Actual iteration-2 intrinsic PNGs in `docs/pr16-visuals/rendered/`, and actual rendered review PNGs at 320, 768, 1024, and 1280 pixels in `docs/pr16-visuals/reviews/renders-iter2/`.
**Source policy:** This is a rendered-artifact review. The generator and storyboards were consulted to identify wording and layout provenance, but source intent does not override what the PNGs communicate. `PROJECT_FUTURE_PLAN.md` was not read or used.

## Verdict

# ITERATE

Iteration 2 is a substantial improvement over iteration 1. The architecture now separates active monitoring, app-data/presentation paths, foundations, and demo content; the provenance aid no longer uses the earlier universal-label or HealthKit-bridge wording; the demo boundary is explicit; and the montage is much more useful at intrinsic and desktop review widths.

However, I do **not** approve publication yet. The current assets still fail the storyboard’s narrow-width acceptance criterion because they are uniformly downscaled desktop layouts, and one material technical qualifier remains visibly inaccurate/too broad in the architecture. Dedicated mobile variants are required, not optional, for this publication.

## Rendered inventory and method

| Asset | Intrinsic PNG | 320 review | 768 review | 1024 review | 1280 review |
|---|---:|---:|---:|---:|---:|
| Architecture | 1600×980 | 320×196 | 768×470 | 1024×627 | 1280×784 |
| Provenance | 1600×960 | 320×192 | 768×461 | 1024×614 | 1280×768 |
| UI montage | 1470×1570 | 320×342 | 768×820 | 1024×1094 | 1280×1367 |

I inspected the PNGs directly at intrinsic size and each supplied review size, checked the actual raster dimensions, and used OCR on the raster outputs as a legibility cross-check. The 320-pixel outputs produced effectively no usable text OCR for the architecture and provenance aids; the 768 outputs retain headings and some labels but lose substantial detail. This is consistent with scaled raster output, not responsive reflow.

## Findings

### [BLOCKER] VD2-1 — Narrow/mobile renders remain unreadable; dedicated mobile variants are required

**Artifacts:** all three aids, especially `reviews/renders-iter2/320/*.png`; also the 768 versions.

Iteration 2 still scales the 1600/1470-pixel desktop compositions into narrow review images. At 320px, the architecture and provenance text is not functionally inspectable; OCR returns no useful body text. The montage preserves its overall title/footer but its screenshot UI and small captions are thumbnail-scale. At 768px, the architecture and provenance headings survive, but many cards, qualifiers, and foundation labels are too small for a newcomer to read comfortably; the montage’s surrounding captions are readable, while the embedded app screenshots remain too small to inspect as UI evidence.

This directly violates the storyboards’ requirement to stack rather than shrink to illegibility and repeats the iteration-1 blocking failure. The positive newcomer iteration-2 report is not sufficient to close this finding: the supplied pixels show scaled desktop layouts, not stacked layouts, and the 320 OCR/render evidence contradicts the report’s claim of narrow-width legibility.

**Required closure:** create dedicated narrow/mobile SVG and PNG layouts for architecture, provenance, and montage. They should use a narrow viewBox, stack the architecture lanes in reading order, stack provenance sources → visible-label examples → isolated demonstrations, and use a one-column montage with screenshot crops wide enough to inspect. Keep body text at a genuinely legible mobile size. If publication uses responsive `<picture>` markup, the mobile asset must be the actual narrow source—not merely a smaller copy of the desktop PNG. Re-render both the mobile assets and the final desktop assets at 320 and 768-equivalent widths before approval.

### [HIGH] VD2-2 — Architecture still uses unsupported package-stage terminology

**Artifact:** intrinsic and scaled `architecture.png`.

The CNS card visibly says `quality → severity → fusion → monitoring state`. The iteration-1 technical review specifically identified this as inaccurate for the package path, whose evidenced sequence is `PipelineStep.step → fusion → applyFusion / tier state`. The iteration-2 generator still contains the same wording in `architecture_v2()`.

This is a factual continuity defect, not merely a stylistic simplification: a newcomer may infer named quality-gate and severity-scorer stages that are not the package pipeline represented by this visual.

**Required closure:** use an evidence-neutral label such as `event step → fusion → monitoring state`, or name only the actual package stages. Re-render and verify the replacement at narrow size.

### [HIGH] VD2-3 — Oura BLE limitation is still not sufficiently explicit

**Artifacts:** architecture foundation card and provenance visible-label panel/footer.

Iteration 2 improves the wording to `feature-gated · key required · hardware-dependent` and states that physical Ring 5 protocol/decryption validation remains hardware-dependent. That is directionally correct, but it still omits the required precision that a **16-byte shared key** is required and that physical Ring 5 protocol/decryption/**key validation** has not been completed. In the architecture, Oura BLE remains visually adjacent to the active/source story, so the short qualifier carries extra weight at reduced sizes.

**Required closure:** use a bounded qualifier such as: `Feature-gated foundation; 16-byte shared key required; physical Ring 5 protocol/decryption/key validation not completed.` Keep it visibly in the foundations/non-active lane. Preserve enough space in the mobile layout for the entire qualifier, rather than truncating it.

### [HIGH] VD2-4 — Watch/cache portrayal remains potentially over-integrated

**Artifact:** architecture.

The active lane flows from CNS processing to `Monitoring view model` and then to `Complication cache — watch-facing snapshot output`, while the foundation row separately says `Phone ↔ Watch — legacy path + package transport foundation`. The iteration-2 composition is much safer than iteration 1, but it can still be read as the iPhone active pipeline directly driving the watch-facing cache. The evidence ledger and iteration-1 technical review require the watch-side HealthKit router/complication-feed path and phased coexistence to remain distinct from the iPhone `KitPipelineService` path.

The small `Phased coexistence` note helps at intrinsic size, but at 768 and below it becomes secondary to the solid active-lane arrows. This is therefore both a continuity and mobile hierarchy issue.

**Required closure:** either label the active output explicitly `iPhone complication-cache writer / package output (platform-specific)` and separately show `watch HealthKit router → complication feed`, or remove the cache from the active iPhone chain and present it as a distinct platform-specific output/foundation. Make the phased coexistence qualifier part of the primary geometry, not a small side note.

### [MEDIUM] VD2-5 — Mobile hierarchy makes the most important safety qualifiers subordinate

**Artifacts:** architecture and provenance at 768 and below.

The iteration-2 copy is materially safer: `Selected surfaces label source or mode`, `No HealthKit writes`, `Simulated observations are not saved as readings`, and `separate from production tier naming` are all good guardrails. At intrinsic/1280 they are inspectable. At 768 they are small, and at 320 they are effectively unavailable. The CNS demo qualification and Oura BLE caveat are especially vulnerable because they sit in compact cards or footer lines.

**Required closure:** mobile layouts must place the isolation and qualification text adjacent to the relevant card, with short high-priority statements visible without zoom. Do not rely on the page caption or SVG `<desc>` to rescue text that the raster image does not show.

### [MEDIUM] VD2-6 — Montage is improved but still not a readable mobile UI aid

**Artifact:** `ui-montage.png` and scaled review renders.

Reducing from six panels to four larger panels was the correct iteration-2 decision. At intrinsic and 1280, the composition has a clear title, four-panel rhythm, precise Oura Cloud/demo wording, and an intact scope footer. At 768, the panel captions and broad structure survive, but the embedded screenshots are still too small to inspect comfortably. At 320, it is an overview thumbnail rather than a newcomer-readable montage.

**Required closure:** a one-column mobile montage with each screenshot spanning most of the available width, followed by its caption and explicit fictional/demo label. Preserve `Representative surfaces — the comprehensive walkthrough is not complete.` Do not substitute a narrow crop that loses provenance or turns the screenshot into an ambiguous decorative fragment.

### [PASS WITH CONDITIONS] VD2-7 — Narrative continuity, color independence, and demo guardrails improved

The three-artifact sequence now has a coherent narrative:

1. architecture distinguishes active monitoring from separate app data, foundations, and demos;
2. provenance explains selected source/mode labels and isolates simulations;
3. montage shows representative dark-mode surfaces and bounds scope.

Text labels, symbols, borders, and arrows carry meaning in addition to color. The provenance legend’s distinct symbols are a good accessibility choice. The CNS box is calm rather than alarmist and does not claim diagnosis or a delivered production alarm. The montage’s fictional/deterministic and incomplete-walkthrough disclosures are appropriately prominent at intrinsic size.

These passes remain conditional on mobile re-layout and on closing VD2-2 through VD2-4. They do not justify publication of the current scaled assets.

## Factual guardrail check

- **Distinct sources:** Pass in iteration-2 narrative and labels. Oura Cloud, Apple Health, Polar, EMAY, CPAP, Oura BLE, and demo content are no longer presented as one undifferentiated input stream.
- **HealthKit:** Pass in provenance wording (`separate HealthKit read/import source`) and demo exclusion (`No HealthKit writes`).
- **Server mirror / foundations:** Improved and no longer drawn as one obvious WatchConnectivity-to-server chain; still needs watch/cache qualification as noted above.
- **Demo Polar/EMAY:** Pass for no production BLE/sensor session, no HealthKit writes, and no real-reading persistence. The separate deterministic fixture footer correctly acknowledges seeded app fixtures.
- **CNS demo:** Pass for isolation, no production monitoring/real notification, no diagnosis, and distinction from production tier naming; mobile prominence remains unresolved.
- **Oura BLE:** **Not yet pass** until the 16-byte shared-key and incomplete physical protocol/decryption/key-validation qualifier is explicit.
- **Montage:** Pass for fictional/deterministic scope and representative—not-complete—walkthrough language, subject to mobile legibility.
- **Privacy:** No new PII or secret is apparent from the rendered review evidence supplied here; retain the separate artifact-level privacy clearance before publication.

## Required next iteration acceptance criteria

1. Dedicated mobile SVG/PNG variants exist for all three aids; they are stacked/reflowed rather than scaled desktop copies.
2. The 320 and 768 rendered mobile candidates retain readable headings, labels, exclusions, provenance qualifiers, and montage captions/screenshots.
3. Architecture says `event step → fusion → monitoring state` (or an equivalently evidenced package sequence), not `quality → severity → fusion`.
4. Oura BLE explicitly states the 16-byte shared-key requirement and incomplete physical Ring 5 protocol/decryption/key validation.
5. Watch/iPhone/cache geometry cannot be read as one completed direct runtime chain; platform-specific and phased status is primary, not a footnote.
6. Intrinsic-size and 320/768/1024/1280 renders are re-inspected, including OCR or an equivalent legibility check.
7. Independent newcomer and technical reviews are repeated against the new pixels.

## Final decision

**ITERATE — do not publish or embed the current iteration-2 assets.** The visual direction is retained and most iteration-1 factual/compositional blockers are resolved, but narrow-width accessibility is still blocking and the architecture retains a material pipeline terminology error plus qualification/continuity issues that should be closed before durable publication.
