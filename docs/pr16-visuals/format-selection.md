# Format selection — minimum sufficient set

**Decision:** implement exactly three static SVG aids. Do not implement video, GIF, or a full screenshot gallery in this phase.

## Selection matrix

| Aid | Selected format | Why it earns a place | Rejected alternatives |
|---|---|---|---|
| Architecture/data flow | Accessible static SVG | Relationships, boundaries, and arrow direction must remain inspectable at the reader’s pace. SVG supports crisp labels, responsive scaling, semantic `<title>`/`<desc>`, and a text alternative. | Video: forces a sequence onto a structural explanation. HTML-only: can express hierarchy but is less effective for one glance of a many-node flow. Interactive canvas: adds discovery cost and inaccessible state. |
| Source/provenance + safety boundary | Accessible static SVG | A single comparison map can keep production sources, imported/Cloud data, hardware-dependent paths, and isolated demos visible simultaneously. SVG supports grouping and non-color labels. | Video: risks making the CNS demo feel like a real alert. Table alone: accurate but weak at showing boundaries and “does not flow into” exclusions. Animation: unnecessary motion and higher safety-review burden. |
| Redesign surface | Static SVG contact sheet using reviewed fictional screenshots as source material | A labeled montage gives breadth and visual grammar without asking a newcomer to watch several recordings. Captions can bound the claim to representative surfaces. | Long video: sequential and hard to inspect; may imply complete walkthrough. Raw screenshot gallery: repetitive and lacks hierarchy. Animated carousel: motion adds no explanatory value. |

## Global visual grammar

- Dark neutral background; one accent per semantic lane, never color alone.
- Solid arrows mean data/control flow; dashed containers mean boundaries; barred or explicitly labeled “does not” paths mean exclusions.
- Every card includes a text label and, where relevant, a source/status badge.
- Use a restrained hierarchy: title → one-sentence thesis → diagram/montage → compact safety caption.
- Do not use alarm-red styling as the dominant treatment. CNS “highest tier” is a demo state, not a production notification.
- Keep captions clinically cautious: “wellness summary,” “demo tier,” “simulated,” and “hardware-dependent,” never “diagnoses,” “validated alarm,” or “clinical certainty.”

## Publication decision

This package is **approved for implementation but not publication**. The eventual assets require a separate factual/render review and a durable GitHub-hosting decision because PR #16 is already merged. No local path may be placed in the PR body. The Conductor owns publication and any PR-body edit.
