# PR #16 visual aids — Visual Director package

**Status:** Director-approved local package; publication intentionally deferred.
**PR:** [#16](https://github.com/chenders/AnxietyWatch/pull/16), already merged.
**Director substitution:** GPT-5.6 Luna is the documented Visual Director substitution because Claude Opus was unavailable.

## Minimum sufficient set

1. **Architecture/data flow (`architecture.svg`)** — static SVG. The newcomer needs to understand boundaries and direction of data before interpreting feature screenshots. Static is preferable to motion because the relationships need inspection and accessible text.
2. **Source/provenance and demo boundary (`provenance.svg`)** — static SVG. This prevents the most consequential misunderstanding: treating Oura Cloud, Apple Health, BLE, production monitoring, and deterministic demos as interchangeable.
3. **Redesign surface (`ui-montage.svg`)** — static SVG contact sheet. A concise montage communicates breadth and visual coherence better than four long recordings. The local verified screenshot set is the factual source material; this montage is a reviewable specification artifact and is not yet a GitHub-published copy of those screenshots.

A video is rejected as the primary aid: it is sequential, harder to inspect, and risks implying that the unfinished comprehensive walkthrough is complete. A video may be a later optional supplement after durable hosting and frame-by-frame review.

## Accessibility and data rules

- Every SVG has a title, description, visible labels, and a text-only summary in this README.
- Status is expressed by labels and shape, not color alone.
- All example health values are deterministic fictional demo values; no person or credential is shown.
- The CNS artifact says **demo only**, **no production monitoring**, and **no real notification**.
- The Oura artifact distinguishes Cloud, HealthKit, feature-gated BLE, and demo data, and states that physical Ring 5 validation remains hardware-dependent.

## Reproduction

```bash
# From repository root
rsvg-convert docs/pr16-visuals/source/architecture.svg -o docs/pr16-visuals/rendered/architecture.png
rsvg-convert docs/pr16-visuals/source/provenance.svg -o docs/pr16-visuals/rendered/provenance.png
rsvg-convert docs/pr16-visuals/source/ui-montage.svg -o docs/pr16-visuals/rendered/ui-montage.png
```

The SVG sources are the canonical editable artifacts. PNGs are local render-review outputs, not publication URLs.

## Text alternatives

- **Architecture:** A sensor/source layer feeds the shared `AnxietyWatchKit` router and CNS pipeline. The iPhone app consumes the monitoring view model and complication cache; local GRDB storage and WatchConnectivity/server sync are separate persistence/transport paths. Oura Cloud and HealthKit are distinct from feature-gated Oura BLE.
- **Provenance:** Production inputs are Oura Cloud, Apple Health, Polar H10, EMAY, and CPAP. Demo fixtures and simulated Polar/EMAY sessions are isolated, labeled, hardware-free, persistence-free, and do not write HealthKit or emit real alerts. The CNS demo is a demonstration of tier progression, not a clinical alarm.
- **Montage:** Six labeled dark-mode surfaces show Dashboard, Oura data, Trends, Journal, Settings, and the CNS demo boundary. The montage is an orientation aid, not a claim that every planned walkthrough route is complete.
