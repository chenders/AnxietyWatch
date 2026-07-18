# Storyboard C — representative redesign surface montage

**Format:** Static SVG contact sheet composed from reviewed, fictional, deterministic simulator screenshots; responsive layout with preserved crops and text captions. Target viewBox 1800×1200.
**Purpose:** Let a newcomer see the breadth and coherence of the dark-mode redesign without implying a finished full-app walkthrough.
**Thesis:** “The redesign is a coherent set of source-aware, dark-mode surfaces—not a claim that every planned route is complete.”

## Included panels (four-panel)

1. Dashboard — orientation and daily overview.
2. Oura data — source/provenance header visible where possible.
3. Trends — chart and metric presentation.
4. Journal — journal anchor and contextual relationship.

## Layout

- Header with title, one-line thesis, and “representative surfaces” badge.
- 2×2 grid at desktop; single column at narrow widths.
- Each panel has a caption below the crop, not overlaid on health data.
- A small footer says: “Fictional/deterministic simulator content. Comprehensive walkthrough coordinator and remaining route choreography remain follow-up work.”
- Do not include raw video playback, a carousel, or an undifferentiated gallery.

## Source handling

- Before implementation, inspect each selected local screenshot for personal data, secrets, accidental real names, real device identifiers, overscroll/rubber-band artifacts, and illegible crops.
- If a source image cannot be cleared, replace it with a redrawn schematic panel or omit it. Do not blur and assume that is sufficient.
- Preserve visible provenance labels such as “Demo Data” and “Simulated” when present.
- Do not include song lyrics, external image URLs, or other content unless separately reviewed; they are not needed to establish redesign breadth.

## Accessibility

- `<title>`: “Representative AnxietyWatch v3 dark-mode surfaces”.
- `<desc>` names each panel and the montage’s scope boundary.
- Each panel has a visible caption and an accessible label; text alternative lists the four surfaces in order.
- Captions must be understandable without color or screenshot detail.

## Factual constraints

- The montage is not evidence of hardware validation.
- Do not present any screen as a production CNS notification.
- Do not say “full app walkthrough complete.” Use “representative surfaces” and retain follow-up scope.
- All data must be clearly fictional/deterministic and contain no personal data.

## Render acceptance

- Desktop: panel labels and source badges readable without zooming.
- Narrow: panels stack; no crop loses its caption or provenance badge.
- 200% zoom: captions remain usable and no information depends on hover.
- Review intrinsic-size and GitHub-rendered-size candidates before publication.
