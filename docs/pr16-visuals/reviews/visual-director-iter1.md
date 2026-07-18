# Visual Director review — implementation iteration 1

**Reviewer:** Visual Director, GPT-5.6 Luna substitution (Claude Opus unavailable)
**Review date:** 2026-07-18
**Inputs inspected:** actual rendered PNGs, rendered dimensions and pixel statistics, OCR at intrinsic size and GitHub-like downscaled widths, SVG-generation source, and all three storyboards. Source files were not edited.

## Verdict

# ITERATE

The three selected formats remain correct and the artifacts are substantially more useful than the text-only PR. However, iteration 1 is not approved for publication or PR embedding. There are two blocking classes of problems:

1. **Architecture/provenance visuals overstate implementation wiring in exactly the areas the storyboard guardrails warned against.** The rendered claims visually imply a single integrated path and universal provenance coverage.
2. **The montage does not remain sufficiently legible at GitHub-like widths.** At 768px and especially 320px, it is an orientation thumbnail rather than a useful newcomer aid; screenshot text and several captions become too small to inspect.

## Rendered artifact inventory

| Artifact | Actual PNG size | Rendered observation |
|---|---:|---|
| `rendered/architecture.png` | 1600×940 | Strong overall left-to-right hierarchy, but the central integration container and right-side storage/transport stack compete. OCR confirms the labels are present at intrinsic size. |
| `rendered/provenance.png` | 1600×940 | Clear three-zone composition and strong isolation boundary, but several exclusion statements are cramped at intrinsic size and become difficult to read when scaled. |
| `rendered/ui-montage.png` | 1800×1360 | Cohesive dark-mode contact sheet with six panels and scope footer. At intrinsic size it reads as a review board; at 768px/320px-equivalent widths it loses screenshot legibility and becomes a decorative overview. |

The PNGs were inspected directly rather than relying on SVG source alone. OCR was also run against the intrinsic PNGs and downscaled copies at 320, 768, 1024, and 1280px-equivalent widths. This review therefore treats rasterized text size and crop behavior as actual artifact behavior, not source intent.

## Continuity findings

### C1 — Architecture has a misleading source-to-pipeline continuity (HIGH, blocking)

The left input cards visually establish one “INPUTS” group, while the central `Adapters and sensor actors → SensorRouter → CNS processing` chain establishes a single receiving pipeline. The rendered `observations` arrow enters that chain from the left, and the visual grammar does not distinguish the three actually wired inputs (Polar, EMAY, HealthKit) from Oura Cloud, Oura BLE, CPAP, or fixtures.

This contradicts the implementation boundary:

- `KitPipelineService` constructs Polar, EMAY, and HealthKit actors for `SensorRouter`.
- Oura Cloud, CPAP/imported records, and deterministic fixtures are separate app data/UI paths.
- Oura BLE is a feature-gated foundation, not shown as a fully wired production input in this service.
- Demo fixtures must not appear to flow into production processing.

**Required correction:** Recompose the architecture into explicitly labeled lanes:

- **Integrated live pipeline:** Polar + EMAY + Apple Health/HealthKit → router → CNS processing.
- **Separate app data/import paths:** Oura Cloud, CPAP/imported records, fixtures, with arrows to relevant UI/data presentation rather than the live sensor router.
- **Foundation / hardware-dependent:** Oura BLE, labeled as foundation and not a confirmed completed live path.
- **Isolated demo lane:** no arrow into production router, storage, HealthKit, or production sessions.

### C2 — Architecture asserts an unsupported router-to-GRDB persistence path (HIGH, blocking)

The rendered `persist` arrow runs from the integrated container toward “Local GRDB storage.” The implementation evidence reviewed for the storyboard does not establish that `KitPipelineService` writes its monitoring snapshots to `SamplesStore`/GRDB. The package GRDB/HLC, REST, and transport foundations also have distinct lifecycle/maturity boundaries.

**Required correction:** Remove the direct `persist` arrow unless a concrete writer is evidenced. Render separate labeled blocks for:

- monitoring view-model and complication-cache output;
- package GRDB/HLC local foundation;
- current legacy phone/watch transfer path;
- package WatchConnectivity foundation and phased migration status;
- existing app `SyncService` → personal server mirror;
- package REST/HLC delta-sync foundation, separately and with maturity qualification.

### C3 — Architecture collapses current and foundation transport paths (HIGH, blocking)

The right stack visually reads as one completed chain: local storage → UI/cache → WatchConnectivity → server mirror. The storyboard’s “separate paths” thesis is not enough to counter the geometry. The current app’s legacy WatchConnectivity path and package transport foundation are not interchangeable, and the server mirror claim belongs specifically to the existing app sync path.

**Required correction:** Add visible labels such as “current legacy phone↔watch path,” “package transport foundation / phased migration,” “existing app sync,” and “package REST/HLC foundation.” Do not make WatchConnectivity a parent step to the server mirror.

### C4 — Provenance card repeats an over-broad universal claim (HIGH, blocking)

The rendered center text says: “Every metric keeps a visible source or demo label.” This is stronger than the implementation evidence. The reviewed code supports source-aware labels on the illustrated Oura/demo surfaces, not a universal invariant across the entire app.

**Required correction:** Change the visual claim to “Selected surfaces show source/mode labels” or “Source-aware labels are supported on these illustrated surfaces.”

### C5 — Apple Health / Oura bridge continuity is ambiguous (HIGH, blocking)

The rendered Apple Health card says “HealthKit import / bridge,” while Oura Cloud is shown as a production/imported source in the same diagram. A newcomer can reasonably infer Oura Cloud → HealthKit writing. The reviewed `OuraHealthKitAdapter` supports read permission for sleep analysis and oxygen saturation; it does not establish a Cloud-to-HealthKit write path.

**Required correction:** Use “Apple Health / HealthKit — separate read/import source” and do not draw a Cloud→HealthKit arrow. If the settings label is referenced, distinguish that UI label from the implemented read-permission behavior.

### C6 — CNS terminology is visually coherent but semantically underqualified (MED/HIGH)

“Clear → Watch → Confirm → Klaxon” is legible and useful as a demo sequence, but the composition places it near production source/pipeline language without sufficiently prominent “isolated demo UI labels” wording. A newcomer could map it directly to package production `normal/advisory/warning/critical` tiers.

**Required correction:** Label it “isolated, scripted demo UI progression” and state that it is separate from production tier naming and monitoring. Do not draw it as output from the production coordinator.

### C7 — Demo persistence language is too broad (HIGH)

The rendered simulated-device card says “does not persist demo readings as real,” which is directionally useful. The storyboard/README wording around “persistence-free” can still be read as the entire full-app demo being persistence-free, while `DemoSeeder` intentionally seeds deterministic fixtures into the demo store.

**Required correction:** Narrow the noun: “Simulated Polar/EMAY observations are not persisted as readings and create no production sensor session.” Add a separate, clearly labeled note that deterministic app fixtures may be seeded for screenshots.

### C8 — Shared visual vocabulary is mostly stable, with one hierarchy drift (MED)

The architecture uses cyan/blue/green/purple/gold as source, processing, output, and boundary accents; provenance uses green/purple/cyan/gold similarly, but the meaning is not fully consistent. In particular, “green” reads as production/imported in provenance and output/storage in architecture, while purple alternates between Oura and transport/foundation.

This does not fail comprehension because labels are present, but it weakens continuity across aids.

**Required correction:** Define semantic tokens independent of source brand:

- blue = processing/foundation;
- green = production/imported source;
- gold = demo/isolation/caution;
- purple = hardware-dependent or transport foundation (only if consistently labeled).

Retain explicit text labels and shapes so color is never load-bearing.

## Composition and newcomer findings

### M1 — Architecture is dense at the right edge (MED)

The “STORAGE, OUTPUTS & TRANSPORT” column is a tall stack of five cards, while the center container is visually dominant. The viewer’s eye can follow the main chain, but the `persist`, `view`, `cache`, and `sync` arrows create a secondary story that reads as more complete than the main story is.

**Fix:** Use separate swimlanes rather than a vertical causal stack. Put outputs under the processing lane and transport foundations in a bounded side lane. Remove arrows that are only organizational decoration.

### M2 — Provenance exclusion copy is too compressed for GitHub display (MED)

The right-hand demo cards contain four and three “does not” lines respectively. At intrinsic size they are present, but they are small relative to the card title and are likely to become difficult to scan at a PR’s displayed width. The footer is readable as a conclusion, but the exclusion lists need more breathing room or fewer words per line.

**Fix:** Keep the four most important negative claims, but shorten and group them into two labeled rows: “No production BLE/session” and “No HealthKit/real-reading persistence,” with a linked text alternative carrying the full precision. For CNS: “No production monitoring/real notification” and “No diagnosis.”

### M3 — Montage is visually coherent but not sufficiently useful at GitHub-like widths (HIGH, blocking)

The montage succeeds as a high-level contact sheet at intrinsic size: six panels, consistent card treatment, labels outside screenshots, and a scope footer. However, the artifact is 1800px wide. At a typical GitHub content width around 768px, it scales to roughly 43% of intrinsic width; at 320px it scales to 18%. The screenshots are already fitted into small 210px-wide crops, so their internal UI text becomes thumbnail-scale. OCR on the downscaled copies confirms that the panel titles survive better than the screenshot content and descriptive captions.

This means the montage answers “what kinds of screens exist?” but not “what does the redesign look like?” at GitHub-like widths. It does not yet earn its place as the primary UI aid.

**Required correction:** Choose one of these bounded solutions:

1. **Preferred:** Keep the montage as an overview but make each panel larger and reduce to four highest-value panels (Dashboard, Oura, Trends, Journal), then provide a separate readable two-panel strip only if needed; or
2. Preserve six panels but include larger crops with less explanatory prose inside each card and rely on the adjacent caption/text alternative; or
3. Use a responsive HTML/Markdown layout with individual linked images and captions rather than one raster contact sheet, if durable hosting permits.

For this iteration, the minimum correction is to make the montage useful at 768px: screenshot content must be inspectable without browser zoom or opening a second artifact. The full six-panel breadth can be retained only if this criterion is met.

### M4 — Montage’s “SIMULATOR” badge is repeated but not source-specific (MED)

Each panel has a generic `SIMULATOR` badge, while the storyboard asks for source/provenance visibility. The Oura panel’s source state is especially important and should retain “Oura Cloud”/“Demo Data” where visible. A generic badge can make all surfaces look like the same execution mode.

**Fix:** Use precise badges where supported: “Fictional demo,” “Oura Cloud / demo,” “HealthKit/demo,” or “Settings surface.” Never invent a source label for a crop that does not show one.

### M5 — Montage scope footer is correct and should be preserved (PASS)

The footer explicitly says the surfaces are representative and does not claim the comprehensive walkthrough is complete. This is the strongest continuity safeguard in the montage and must survive any resize or redesign.

### M6 — All three artifacts retain a coherent dark-mode visual language (PASS)

Dark neutral background, rounded cards, restrained accent lines, and explicit headings create a recognizable family. The artifacts do not use alarmist CNS styling. This is worth preserving through iteration.

## Accessibility and render checks

- **Text alternatives:** SVGs include semantic title/description in the generated source, but the PNGs themselves do not carry accessible metadata. If the PNGs are published, adjacent Markdown alt text/captions are mandatory.
- **Color independence:** Labels and card text are present, so the primary message does not rely solely on color. However, the cross-aid accent semantics should be stabilized as noted in C8.
- **Narrow width:** Simple raster downscaling does not provide true responsive reflow. The architecture/provenance PNGs remain complete but become too small to inspect; the montage’s screenshot text is particularly affected. This is a publication concern, not merely a source concern.
- **Clipping:** Intrinsic OCR shows the major footer and card labels are present; no evidence of catastrophic clipping was found in the PNGs. The problem is density and scale, not missing content.
- **200% zoom:** Not closeable from the raster outputs alone. Publication requires a rendered-page check with the final Markdown/HTML embedding and adjacent alt text.
- **Privacy:** The montage source images were not independently cleared by this review from the PNG pixels alone. The Conductor must retain artifact-level privacy clearance before publication; presence in a local “verified” directory is not sufficient evidence.

## Required Iteration 2 checklist

- [ ] Split architecture into active integrated pipeline, separate app/import paths, foundations, and isolated demo.
- [ ] Remove unsupported router→GRDB `persist` implication or add precise evidence and label.
- [ ] Separate legacy/current WatchConnectivity, package transport foundation, existing server mirror sync, and package REST/HLC foundation.
- [ ] Narrow Apple Health wording to read/import; remove Cloud→HealthKit implication.
- [ ] Replace “every metric” with selected-surface/source-aware wording.
- [ ] Label CNS sequence as isolated scripted demo UI, distinct from production tier vocabulary.
- [ ] Narrow simulated persistence claim while acknowledging seeded deterministic fixtures.
- [ ] Make montage screenshot content readable at approximately 768px GitHub content width; preserve scope footer.
- [ ] Replace generic simulator badges with precise, evidence-supported provenance labels.
- [ ] Re-render actual PNGs and repeat intrinsic/768/320 review before requesting approval.

## Closure

**ITERATE.** The visual family and three-aid set are retained. Iteration 1 is not approved for publication because the architecture/provenance narrative is technically over-integrated and the montage is not sufficiently legible at GitHub-like widths. No sources were edited in this review.
