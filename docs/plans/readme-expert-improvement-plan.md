# README & Public Launch Improvement Plan

**Date:** 2026-03-29
**Source:** Synthesis of 11 expert perspectives: Technical Writer, GitHub Popularity Expert, Poet, Writing Instructor, iOS UI/UX Expert, Health App UX Expert, HealthKit Expert, Anxiety & Panic Disorder Expert (psychiatrist), Technical Project Manager, Project Expert, Lived Experience Expert
**Purpose:** Actionable tasks to improve the README and prepare the project for public visibility, sorted by biggest impact then smallest effort. Each task is implementable by Claude Code.

---

## How to Use This Plan

Each task includes:
- **What to do** — specific, implementable instructions
- **Impact** — High/Medium/Low (how much this improves the README or public perception)
- **Effort** — Small/Medium/Large (implementation time)
- **Expert input** — which experts recommended it and why
- **Risks & mitigations** — what could go wrong
- **Dependencies** — what must be done first

Tasks are sorted: High Impact + Small Effort first, then High Impact + Medium Effort, etc.

---

## 1. Capture App Screenshots for README

**Impact:** High | **Effort:** Medium

### What to do
Build browser mockups of 5 key screens using HTML/CSS/Tailwind that look like iOS app screenshots, then capture them as PNGs. This produces consistent, high-quality images without depending on device state or real data.

**Screens to mock up:**
1. **Dashboard** — metric cards with sparklines, baseline alert, "Last Anxiety: 6/10" card, sleep summary, HRV card with trend arrow
2. **HRV Trend Chart** — line chart with shaded baseline band, 30-day view, anxiety severity points overlaid
3. **watchOS Quick Log** — Digital Crown severity picker (1-10), minimal dark UI, "Log" button
4. **Medication dose follow-up** — the DoseAnxietyPromptView showing severity slider, medication name, "How's your anxiety 30 minutes after taking Lorazepam 0.5mg?"
5. **Clinical PDF report** — a rendered page showing anxiety summary, medication adherence table, HRV trend

**Implementation:**
```bash
# Create docs/screenshots/ directory
mkdir -p docs/screenshots

# Create an HTML file per mockup (use Tailwind CDN for styling)
# Each mockup should be a fixed-width container (375px for iPhone, 198px for Watch)
# Screenshot with browser dev tools or a headless browser
```

Then update `README.md`: uncomment the screenshot section and add real image paths.

### Expert input
- **GitHub Popularity Expert:** "A README with no screenshots of an iOS app signals 'this might not actually run.' Screenshots are non-negotiable."
- **Technical Writer:** "Screenshots should appear between the opening hook and the feature list — they are a pacing reset."
- **Writing Instructor:** "The reader has been absorbing words. Now they see the thing. This is where interest converts to engagement."

### Risks & mitigations
- **Risk:** Mockups look fake or don't match real app. **Mitigation:** Use actual color values from the codebase (severity colors, baseline band colors). Study the real views.
- **Risk:** Screenshots become outdated. **Mitigation:** Note the mockup source files so they can be regenerated.

### Dependencies
None — can be done immediately.

---

## 2. Add Issue Templates

**Impact:** High | **Effort:** Small

### What to do
Create `.github/ISSUE_TEMPLATE/` with two templates:

**bug_report.md:**
```markdown
---
name: Bug Report
about: Report a bug or unexpected behavior
labels: bug
---

**Describe the bug**
A clear description of what happened.

**Expected behavior**
What you expected to happen.

**Device & OS**
- iPhone model:
- iOS version:
- Apple Watch model (if applicable):
- watchOS version (if applicable):

**Steps to reproduce**
1.
2.
3.

**Additional context**
Screenshots, crash logs, or data export excerpts (redact personal data).
```

**feature_request.md:**
```markdown
---
name: Feature Idea
about: Suggest a feature or improvement
labels: enhancement
---

**What problem does this solve?**
Describe the situation where this would help.

**Proposed solution**
What you'd like to see.

**Have you read the design philosophy?**
- [ ] I've read [PROJECT_FUTURE_PLAN.md](../../PROJECT_FUTURE_PLAN.md) (especially "The Central Tension")
- [ ] This aligns with the project's goals

**Additional context**
Mockups, references, or links to related issues.
```

### Expert input
- **GitHub Popularity Expert:** "Issue templates are low effort, high signal. They tell contributors the project is organized and welcoming."
- **Technical Project Manager:** "The design philosophy checkbox prevents well-intentioned but off-mission feature requests."

### Risks & mitigations
None.

### Dependencies
None.

---

## 3. Add Code of Conduct

**Impact:** High | **Effort:** Small

### What to do
Create `CODE_OF_CONDUCT.md` using the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). For a mental health project, this signals sensitivity and maturity.

Add one project-specific paragraph at the top:

> Anxiety Watch is a tool for people managing anxiety and panic disorder. Many contributors and users may be living with these conditions. We ask that all interactions in this project reflect that reality — be patient, be kind, and remember that the person on the other end of the screen may be having a difficult day.

### Expert input
- **GitHub Popularity Expert:** "For health/mental-health projects, a code of conduct signals maturity. It doesn't need to be long."
- **Lived Experience Expert:** "The mental health community is sensitive to dismissiveness. An explicit code of conduct builds trust."

### Risks & mitigations
None.

### Dependencies
None.

---

## 4. Create a Makefile

**Impact:** High | **Effort:** Small

### What to do
Create a `Makefile` at the project root with targets for common commands. This was identified as the highest-impact developer experience change by the DX expert in the original expert review.

```makefile
.PHONY: build test test-server lint server-up server-down coverage

build:
	xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'

build-watch:
	xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator'

test:
	xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests

test-server:
	cd server && python -m pytest tests/

lint:
	cd server && flake8 . --max-line-length=120 --exclude=__pycache__

server-up:
	docker compose --env-file server/.env -f server/docker-compose.yml up -d

server-down:
	docker compose --env-file server/.env -f server/docker-compose.yml down

coverage:
	xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -enableCodeCoverage YES -resultBundlePath /tmp/coverage.xcresult
	xcrun xccov view --report /tmp/coverage.xcresult
```

Update `README.md` Getting Started section to mention `make build`, `make test`.

### Expert input
- **Technical Project Manager:** "Every action becomes a one-word command. Essential for contributors."
- **Developer Experience Expert (from original review):** "Identified as highest-impact DX change."

### Risks & mitigations
None.

### Dependencies
None.

---

## 5. Update README with Real Screenshot Images

**Impact:** High | **Effort:** Small (after task #1)

### What to do
Once browser mockup screenshots are captured (task #1), update `README.md`:
1. Uncomment the screenshot HTML block
2. Replace placeholder paths with actual image paths
3. Add alt text for accessibility

### Expert input
- **All panel members** agreed screenshots are the single most impactful addition to the README after the text itself.

### Risks & mitigations
None.

### Dependencies
Task #1 (capture screenshots).

---

## 6. Add CONTRIBUTING.md (Optional, Low Priority)

**Impact:** Medium | **Effort:** Small

### What to do
The README's Contributing section is sufficient at the current project scale. If the project attracts contributors, extract to a standalone `CONTRIBUTING.md` with:
- Development setup
- Testing expectations (Swift Testing, in-memory containers, fixed dates)
- Code style (reference CLAUDE.md)
- PR process
- Design philosophy summary

### Expert input
- **Technical Writer:** "Not necessary now. The README section is sufficient for a solo project."
- **GitHub Popularity Expert:** "Create this when you get your first external PR, not before."

### Risks & mitigations
- **Risk:** Premature optimization of contributor experience. **Mitigation:** Wait until there's demand.

### Dependencies
None, but recommended to defer.

---

## 7. Add GitHub Repository Description and Topics

**Impact:** Medium | **Effort:** Small

### What to do
Set the GitHub repository description and topics for discoverability:

```bash
gh repo edit --description "Personal iOS + watchOS anxiety tracker correlating journal entries, HealthKit physiology, medications, and CPAP data"

gh repo edit --add-topic swift,ios,watchos,swiftui,healthkit,anxiety,mental-health,swiftdata,health-tracking,cpap
```

### Expert input
- **GitHub Popularity Expert:** "Topics are how people find projects through GitHub Explore. Mental health + HealthKit + SwiftUI is a discoverable combination."

### Risks & mitigations
None.

### Dependencies
Repository must be public first.

---

## 8. README Refinements Based on Real Usage Feedback

**Impact:** Medium | **Effort:** Medium

### What to do
After the README has been live for 1-2 weeks, review:
- Are people opening issues? What are they asking about?
- Is the Getting Started section sufficient?
- Do the linked docs (PROJECT_FUTURE_PLAN.md, REQUIREMENTS.md) need summaries or are they overwhelming?

Consider adding:
- A "Frequently Asked Questions" section if patterns emerge
- A "Project History" section (2-3 sentences, like Dead on Film's)
- A comparison table vs. other apps (Daylio, Bearable, Apple Health State of Mind) — the clinical expert provided a detailed comparison

### Expert input
- **Writing Instructor:** "The README is a living document. Write it once, then refine based on what people actually ask."
- **Technical Project Manager:** "Don't over-optimize before you have users."

### Risks & mitigations
- **Risk:** Over-expanding the README. **Mitigation:** Target 1200-1800 words of prose. Move depth to linked docs.

### Dependencies
Repository must be public with some traffic.

---

## 9. Create Browser Mockup System for Ongoing Screenshot Needs

**Impact:** Medium | **Effort:** Medium

### What to do
Build a reusable HTML/CSS system (single page with sections) that renders realistic iOS app screen mockups. This enables:
- Consistent screenshots for README updates
- Marketing/blog images if the project grows
- Visual documentation for the future plan features

Use Tailwind CSS with iOS-like design tokens (SF Pro font, iOS system colors, rounded cards). Each screen should be in a phone-frame container.

### Expert input
- **Health App UX Expert:** "Visual proof the app works is essential. A reusable mockup system pays dividends."
- **iOS UI/UX Expert:** "Use SF Pro and Apple's HIG color palette for authenticity."

### Risks & mitigations
- **Risk:** Mockups diverge from real app. **Mitigation:** Reference actual view code when building mockups.

### Dependencies
None.

---

## 10. Write a Blog Post / Launch Announcement

**Impact:** Medium | **Effort:** Large

### What to do
When ready to make the repository public, write a companion blog post or GitHub Discussion that tells the personal story behind the project in more depth than the README. The README is deliberately restrained — it speaks *to* someone with anxiety without making it too personal. A blog post can go deeper: the origin story, why existing apps didn't work, the design philosophy in detail, what it's like to build a tool for your own condition.

### Expert input
- **GitHub Popularity Expert:** "The projects that take off have a story. HN, Reddit r/ios, r/anxiety, and Swift community forums would engage with this."
- **Poet:** "The README hooks. The blog post converts. They serve different purposes."
- **Lived Experience Expert:** "The anxiety community on Reddit would be very receptive to an honest post about building this. Not 'check out my app' but 'here's what I built for myself and why.'"

### Risks & mitigations
- **Risk:** Too personal / oversharing. **Mitigation:** Focus on the approach and what you learned, not medical details.
- **Risk:** Attracting users before the app is ready. **Mitigation:** The README clearly states it's under active development.

### Dependencies
README complete, screenshots captured, repository public.

---

## Summary: Priority Order

| # | Task | Impact | Effort | Do When |
|---|------|--------|--------|---------|
| 1 | Capture app screenshots (browser mockups) | High | Medium | Now |
| 2 | Add issue templates | High | Small | Now |
| 3 | Add code of conduct | High | Small | Now |
| 4 | Create Makefile | High | Small | Now |
| 5 | Update README with screenshots | High | Small | After #1 |
| 6 | Add CONTRIBUTING.md | Medium | Small | When needed |
| 7 | Set GitHub description & topics | Medium | Small | When going public |
| 8 | README refinements from feedback | Medium | Medium | After public launch |
| 9 | Build reusable mockup system | Medium | Medium | When updating screenshots |
| 10 | Write launch blog post | Medium | Large | When going public |

---

## Expert Panel Consensus Summary

### What all experts agreed on
- **Screenshots are mandatory.** The single most impactful addition after the text.
- **Lead with the person, not the technology.** The opening must speak to someone with anxiety first, developers second.
- **One status sentence replaces all disclaimers.** "The data collection layer is thorough. The intelligence layer is next."
- **The dose-triggered efficacy measurement is the headline feature.** It is genuinely novel across consumer, clinical, and research tools.
- **Self-monitoring health anxiety caution is essential.** A mental health tool that doesn't acknowledge this risk loses credibility with the people it's trying to help.

### What experts disagreed on
- **How much vision to include.** The GitHub Popularity Expert wanted more North Star content ("it's your secret weapon"). The Writing Instructor wanted less ("don't oversell work in progress"). The README balances these with a collapsible details block.
- **Comparison table vs. other apps.** The clinical expert provided a detailed comparison (Daylio, Bearable, Apple Health). The Technical Writer argued against naming competitors in the README. The current approach describes the gap without naming apps.
- **Crisis mode features in the README.** The Health App UX Expert wanted to highlight crisis-mode design ("large tap targets, no fine motor control"). The Lived Experience Expert cautioned against overemphasizing crisis: "Don't make the app sound like it's only for panic attacks. Most of my anxiety is low-grade and chronic." The README mentions crisis design briefly under "Designed for your worst moments" but does not center it.

### Key quotes from experts

> **Lived Experience Expert:** "Anxiety is less frightening when it is less mysterious. That is the value proposition — not 'track your HRV.'"

> **Clinical Expert:** "The dose-triggered anxiety prompt with follow-up creates something closer to an N-of-1 trial than anything a consumer app typically produces."

> **GitHub Popularity Expert:** "The projects that take off have a story. Every feature exists because a real person needed it — that is your story."

> **Writing Instructor:** "Never apologize for incompleteness. State what exists. State what's next. Never state what's missing."

> **Health App UX Expert:** "Most anxiety apps track how you feel. This one also tracks what your body is doing, what you took, how you slept, and whether your treatment is working — then connects all of it."

> **Poet:** "The transition from emotional opening to technical content should feel like zooming out from a personal moment to a system that enables it."

> **Technical Project Manager:** "Do not create a CONTRIBUTING.md, issue templates, or a blog post until you have evidence someone wants to contribute. Premature community infrastructure is a distraction."
