#!/usr/bin/env python3
"""Generate the three static PR #16 visual aids.

Run from the repository root. Requires Pillow and rsvg-convert (for PNG review renders).
The final SVG montage embeds reviewed WebP screenshots so it remains self-contained.
"""
from __future__ import annotations

import base64
import html
import subprocess
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / "docs/pr16-visuals"
SOURCE = WORK / "source"
SHOTS = SOURCE / "screenshots"
RENDERED = WORK / "rendered"
SHOTS.mkdir(parents=True, exist_ok=True)
RENDERED.mkdir(parents=True, exist_ok=True)

BG = "#0b1020"
PANEL = "#151d32"
PANEL2 = "#1b2640"
TEXT = "#f4f7ff"
MUTED = "#b8c4db"
BLUE = "#72b7ff"
CYAN = "#63d7d0"
GOLD = "#f3c969"
PURPLE = "#bd9cff"
GREEN = "#72d6a0"
BORDER = "#53637f"


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def text(x, y, value, size=24, fill=TEXT, weight=500, anchor="start"):
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}">{esc(value)}</text>'


def multiline(x, y, lines, size=21, fill=MUTED, line=30, weight=500, anchor="start"):
    spans = "".join(f'<tspan x="{x}" dy="{0 if i == 0 else line}">{esc(v)}</tspan>' for i, v in enumerate(lines))
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}">{spans}</text>'


def card(x, y, w, h, title, sub, accent=BLUE, dashed=False):
    dash = ' stroke-dasharray="10 8"' if dashed else ""
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="18" fill="{PANEL}" stroke="{accent}" stroke-width="2"{dash}/>'
        + text(x + 22, y + 36, title, 23, TEXT, 700)
        + multiline(x + 22, y + 68, sub if isinstance(sub, list) else [sub], 18, MUTED, 25)
    )


def svg_wrap(title_value, desc_value, width, height, body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">
<title id="title">{esc(title_value)}</title><desc id="desc">{esc(desc_value)}</desc>
<style>text{{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}} .arrow{{fill:none;stroke:{MUTED};stroke-width:3;marker-end:url(#arrow)}} .label{{paint-order:stroke;stroke:{BG};stroke-width:8px;stroke-linejoin:round}}</style>
<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10z" fill="{MUTED}"/></marker></defs>
<rect width="100%" height="100%" fill="{BG}"/>{body}</svg>'''


def architecture():
    b = text(70, 70, "How AnxietyWatch v3 fits together", 42, TEXT, 750)
    b += text(70, 110, "Distinct sources converge on shared processing; persistence and transport remain separate paths.", 22, MUTED)
    b += text(70, 168, "INPUTS", 19, CYAN, 800)
    inputs = [
        ("Polar H10", "BLE sensor"), ("EMAY", "BLE / imported data"),
        ("Apple Health", "HealthKit adapter"), ("Oura Cloud", "daily summaries"),
        ("Oura BLE", "feature-gated · hardware-dependent"), ("CPAP", "imported records"),
    ]
    for i, (a, s) in enumerate(inputs):
        x = 70 + (i % 2) * 260; y = 190 + (i // 2) * 108
        b += card(x, y, 238, 86, a, s, CYAN if i < 3 else PURPLE)
    b += card(70, 530, 498, 105, "Deterministic demo fixtures", ["isolated display/demo lane", "not production observations"], GOLD, True)

    b += f'<rect x="640" y="170" width="510" height="530" rx="28" fill="{PANEL2}" stroke="{BLUE}" stroke-width="3"/>'
    b += text(895, 215, "AnxietyWatchKit + iPhone integration", 27, TEXT, 750, "middle")
    b += card(700, 250, 390, 84, "Adapters and sensor actors", "source-specific ingestion", BLUE)
    b += card(700, 370, 390, 84, "SensorRouter", "normalizes and routes observations", BLUE)
    b += card(700, 490, 390, 92, "CNS processing / coordinator", "quality → severity → fusion → tier state", BLUE)
    b += card(700, 618, 390, 62, "Monitoring view models", "presentation state", BLUE)
    for y1, y2, lab in [(334,370,"route"),(454,490,"process"),(582,618,"publish")]:
        b += f'<path class="arrow" d="M895 {y1} V{y2-6}"/>' + text(910, (y1+y2)//2+5, lab, 15, MUTED)
    b += '<path class="arrow" d="M568 330 C610 330 620 292 694 292"/>' + text(585, 305, "observations", 16, MUTED)
    b += '<path class="arrow" d="M568 575 C610 575 620 645 694 645" stroke-dasharray="8 7"/>' + text(578, 622, "demo display only", 16, GOLD)

    b += text(1220, 168, "STORAGE, OUTPUTS & TRANSPORT", 19, GREEN, 800)
    b += card(1220, 190, 310, 95, "Local GRDB storage", "schema, migration, retention", GREEN)
    b += card(1220, 325, 310, 95, "iPhone + Watch UI", "monitoring state and views", GREEN)
    b += card(1220, 460, 310, 95, "Complication cache", "watch-facing snapshot output", GREEN)
    b += card(1220, 595, 310, 95, "WatchConnectivity", "device transport foundation", PURPLE, True)
    b += card(1220, 735, 310, 95, "Server mirror", "push-oriented app sync", PURPLE)
    b += '<path class="arrow" d="M1150 410 H1214"/>' + text(1164, 393, "view", 15, MUTED)
    b += '<path class="arrow" d="M1150 530 H1214"/>' + text(1158, 514, "cache", 15, MUTED)
    b += '<path class="arrow" d="M1150 275 C1185 275 1180 238 1214 238"/>' + text(1158, 252, "persist", 15, MUTED)
    b += '<path class="arrow" d="M1375 690 V729"/>' + text(1393, 716, "sync", 15, MUTED)
    b += text(70, 785, "Boundaries that matter", 25, GOLD, 750)
    b += multiline(70, 820, ["• Oura Cloud, Apple Health and Oura BLE remain distinct sources.", "• HealthKit remains the physiological source of truth; the server is a mirror.", "• Oura BLE is feature-gated and physical Ring 5 behavior remains hardware-dependent."], 20, MUTED, 31)
    return svg_wrap("AnxietyWatch v3 architecture and data flow", "Separate Polar, EMAY, Apple Health, Oura Cloud, feature-gated Oura BLE, and CPAP inputs feed shared routing and CNS processing. Local storage, user interfaces, complication cache, WatchConnectivity, and server mirror are separate output and transport paths. Demo fixtures stay outside production observations.", 1600, 940, b)


def provenance():
    b = text(70, 70, "Source-aware by design — demos stop at the boundary", 42, TEXT, 750)
    b += text(70, 110, "A value’s label says where it came from; simulation is never presented as a hardware reading.", 22, MUTED)
    b += text(70, 170, "PRODUCTION / IMPORTED SOURCES", 19, GREEN, 800)
    srcs = [("Oura Cloud", "daily summaries · wellness metrics"),("Apple Health", "HealthKit import / bridge"),("Polar H10", "hardware sensor path"),("EMAY Oximeter", "hardware / imported path"),("CPAP", "imported session data")]
    for i,(a,s) in enumerate(srcs): b += card(70, 195+i*112, 470, 88, a, s, GREEN if i else PURPLE)
    b += f'<rect x="585" y="195" width="390" height="536" rx="28" fill="{PANEL2}" stroke="{BLUE}" stroke-width="3"/>'
    b += text(780, 242, "Source-aware presentation", 27, TEXT, 750, "middle")
    b += multiline(620, 290, ["Every metric keeps a visible", "source or demo label."], 22, MUTED, 31)
    for i,(shape,label,col) in enumerate([("●","Cloud summary",PURPLE),("◆","HealthKit / import",GREEN),("■","Live sensor path",CYAN),("◇","Demo / simulated",GOLD)]):
        b += text(635, 385+i*64, shape, 28, col, 800) + text(680, 382+i*64, label, 21, TEXT, 650)
    b += f'<rect x="620" y="642" width="320" height="64" rx="12" fill="{BG}" stroke="{GOLD}"/>'
    b += multiline(640, 668, ["Oura BLE: feature-gated", "key required · hardware-dependent"], 17, GOLD, 22, 700)
    b += '<path class="arrow" d="M540 455 H579"/>' + '<path class="arrow" d="M975 455 H1014"/>'

    b += text(1030, 170, "ISOLATED DEMONSTRATIONS", 19, GOLD, 800)
    b += card(1030, 195, 500, 250, "Simulated device session", ["Polar H10 (Simulated) + EMAY (Simulated)", "DETERMINISTIC · HARDWARE-FREE · SIX-HOUR CLOCK"], GOLD, True)
    b += multiline(1060, 330, ["⊘ does not activate production BLE", "⊘ does not open a production SensorSession", "⊘ does not write HealthKit", "⊘ does not persist demo readings as real"], 18, TEXT, 27, 600)
    b += card(1030, 480, 500, 250, "CNS tier demonstration", ["Clear → Watch → Confirm → Klaxon", "DEMO UI PROGRESSION — NOT A CLINICAL ALARM"], GOLD, True)
    b += multiline(1060, 615, ["⊘ does not arm production monitoring", "⊘ does not send a real alert or notification", "⊘ does not diagnose a condition"], 18, TEXT, 29, 600)
    b += f'<path d="M995 195 V730" stroke="{GOLD}" stroke-width="4" stroke-dasharray="12 10"/>'
    b += text(1009, 770, "ISOLATION BOUNDARY", 16, GOLD, 800)
    b += f'<rect x="70" y="800" width="1460" height="92" rx="18" fill="{PANEL}" stroke="{BORDER}"/>'
    b += text(800, 838, "All displayed health values in these aids are fictional, deterministic simulator content.", 22, TEXT, 700, "middle")
    b += text(800, 871, "Physical Oura Ring 5 BLE protocol/decryption validation remains hardware-dependent.", 19, MUTED, 600, "middle")
    return svg_wrap("AnxietyWatch source provenance and demo boundaries", "Production and imported sources—Oura Cloud, Apple Health, Polar H10, EMAY and CPAP—retain visible provenance. Feature-gated Oura BLE requires a key and remains hardware-dependent. Simulated Polar and EMAY sessions do not activate production BLE, open a production sensor session, write HealthKit, or persist readings as real. The CNS tier demonstration neither arms production monitoring nor sends a real alert or diagnosis.", 1600, 940, b)


def prepare_shots():
    home = Path.home() / "anxietywatch-screenshots-verified"
    picks = {
        "dashboard": (home/"dashboard-01.png", "Dashboard"),
        "oura": (home/"oura-data-01.png", "Oura data"),
        "trends": (home/"trends-01.png", "Trends"),
        "journal": (home/"journal-01.png", "Journal"),
        "medications": (home/"medications-01.png", "Medications"),
        "settings": (home/"settings-01.png", "Settings & sources"),
    }
    out = {}
    for slug,(path,label) in picks.items():
        if not path.exists():
            raise SystemExit(f"Missing reviewed source screenshot: {path}")
        im = Image.open(path).convert("RGB")
        # Keep a representative upper viewport. It avoids scroll seams and preserves navigation context.
        im = im.crop((0, 0, im.width, min(im.height, 2360)))
        target = SHOTS / f"{slug}.webp"
        im.save(target, "WEBP", quality=82, method=6)
        out[slug] = (target,label)
    return out


def data_uri(path):
    return "data:image/webp;base64," + base64.b64encode(path.read_bytes()).decode("ascii")


def montage():
    shots = prepare_shots()
    b = text(70, 70, "Representative v3 dark-mode surfaces", 42, TEXT, 750)
    b += text(70, 110, "A source-aware redesign across daily context, reflection, trends and configuration.", 22, MUTED)
    b += f'<rect x="1420" y="45" width="310" height="56" rx="28" fill="{PANEL2}" stroke="{GOLD}"/>'
    b += text(1575, 81, "FICTIONAL DEMO DATA", 18, GOLD, 800, "middle")
    positions = [(70,170),(650,170),(1230,170),(70,700),(650,700),(1230,700)]
    notes = {
        "dashboard":"daily context",
        "oura":"Cloud summary surface",
        "trends":"time-based patterns",
        "journal":"subjective anchor",
        "medications":"treatment context",
        "settings":"source controls",
    }
    for (slug,(path,label)),(x,y) in zip(shots.items(),positions):
        b += f'<rect x="{x}" y="{y}" width="500" height="470" rx="22" fill="{PANEL}" stroke="{BORDER}" stroke-width="2"/>'
        # Source aspect ratio ~0.51; fit a 190x414 phone crop.
        b += f'<clipPath id="clip-{slug}"><rect x="{x+24}" y="{y+24}" width="210" height="390" rx="18"/></clipPath>'
        b += f'<image href="{data_uri(path)}" x="{x+24}" y="{y+24}" width="210" height="458" preserveAspectRatio="xMidYMin slice" clip-path="url(#clip-{slug})"/>'
        b += text(x+270, y+90, label, 28, TEXT, 750)
        b += text(x+270, y+126, notes[slug], 19, CYAN if slug != "oura" else PURPLE, 700)
        descs = {
          "dashboard":["Status, risk context", "and latest sleep"],
          "oura":["Daily readiness, sleep", "and resilience metrics"],
          "trends":["Anxiety and physiology", "over selected ranges"],
          "journal":["Entries remain the anchor", "for objective context"],
          "medications":["Medication records", "alongside symptoms"],
          "settings":["Health, device and", "sync source controls"],
        }
        b += multiline(x+270, y+185, descs[slug], 20, MUTED, 29)
        b += f'<rect x="{x+270}" y="{y+310}" width="190" height="50" rx="12" fill="{BG}" stroke="{BORDER}"/>'
        b += text(x+365, y+342, "SIMULATOR", 16, MUTED, 800, "middle")
    b += f'<rect x="70" y="1210" width="1660" height="105" rx="20" fill="{PANEL2}" stroke="{GOLD}"/>'
    b += text(900, 1252, "Representative surfaces — not a claim that the comprehensive walkthrough is complete.", 22, TEXT, 700, "middle")
    b += text(900, 1287, "All values are deterministic and fictional; remaining route choreography stays follow-up work.", 19, MUTED, 600, "middle")
    return svg_wrap("Representative AnxietyWatch v3 dark-mode surfaces", "Six simulator screenshots show Dashboard daily context, Oura Cloud summaries, Trends, Journal, Medications, and Settings source controls. All values are fictional and deterministic. These are representative surfaces, not a completed comprehensive walkthrough or hardware validation.", 1800, 1360, b)


def architecture_v2():
    b = text(70, 70, "How AnxietyWatch v3 fits together", 42, TEXT, 750)
    b += text(70, 110, "Active monitoring, app data, storage/sync foundations, and demos have different boundaries.", 22, MUTED)

    b += text(70, 168, "ACTIVE LIVE MONITORING PIPELINE", 19, GREEN, 800)
    for i, (name, detail) in enumerate([("Polar H10", "BLE actor"), ("EMAY Oximeter", "BLE actor"), ("Apple Health", "HealthKit read adapter")]):
        b += card(70, 195 + i * 105, 310, 82, name, detail, GREEN)
    b += card(470, 235, 310, 90, "SensorRouter", "routes supported observations", BLUE)
    b += card(470, 385, 310, 105, "CNS processing", ["quality → severity → fusion", "→ monitoring state"], BLUE)
    b += card(870, 235, 310, 90, "Monitoring view model", "iPhone presentation state", BLUE)
    b += card(870, 385, 310, 105, "Complication cache", "watch-facing snapshot output", BLUE)
    b += '<path class="arrow" d="M380 300 H464"/>' + text(397, 284, "observations", 15, MUTED)
    b += '<path class="arrow" d="M625 325 V379"/>' + text(642, 360, "process", 15, MUTED)
    b += '<path class="arrow" d="M780 438 H864"/>' + text(797, 422, "publish", 15, MUTED)
    b += '<path class="arrow" d="M1025 325 V379"/>' + text(1043, 360, "cache", 15, MUTED)
    b += card(1260, 235, 270, 255, "Phased coexistence", ["Legacy app services remain", "during package rollout.", "", "This diagram does not", "claim every source uses", "the live router."], PURPLE, True)

    b += text(70, 565, "SEPARATE APP DATA / PRESENTATION PATHS", 19, PURPLE, 800)
    for i, (name, detail) in enumerate([("Oura Cloud", "daily API summaries"), ("CPAP", "imported session records"), ("Deterministic fixtures", "seeded demo-store content")]):
        b += card(70 + i * 345, 590, 315, 105, name, detail, PURPLE if i < 2 else GOLD, i == 2)
    b += card(1110, 590, 420, 105, "Source-aware app surfaces", ["Dashboard · Oura · Trends", "Journal · Settings"], CYAN)
    b += '<path class="arrow" d="M385 642 H1104"/>' + text(690, 626, "separate presentation/data paths", 15, MUTED)

    b += text(70, 765, "FOUNDATIONS — NOT DRAWN AS ONE COMPLETED CHAIN", 19, BLUE, 800)
    foundations = [
        ("Local GRDB + HLC", "package storage/sync foundation"),
        ("Phone ↔ Watch", "legacy path + package transport foundation"),
        ("Existing app sync", "pushes to personal server mirror"),
        ("Oura BLE", "feature-gated · key required · hardware-dependent"),
    ]
    for i,(name,detail) in enumerate(foundations):
        b += card(70 + i*375, 790, 345, 92, name, detail, BLUE if i < 3 else PURPLE, i in (1,3))
    b += text(70, 925, "Demo-device observations do not enter the production router, HealthKit, or production sensor sessions.", 20, GOLD, 700)
    return svg_wrap("AnxietyWatch v3 architecture and data flow", "The active live monitoring pipeline routes Polar H10, EMAY Oximeter, and Apple Health observations through SensorRouter into CNS processing, monitoring presentation state, and complication cache output. Oura Cloud, CPAP records, and deterministic fixtures use separate app data or presentation paths. GRDB and HLC, phone-watch transport, existing server mirror sync, and feature-gated Oura BLE are shown as separate foundations rather than one completed chain. Demo-device observations stay outside the production router, HealthKit, and production sessions.", 1600, 980, b)


def provenance_v2():
    b = text(70, 70, "Source-aware where shown — demos stop at the boundary", 42, TEXT, 750)
    b += text(70, 110, "Selected surfaces label source or mode; simulation is never presented as a hardware reading.", 22, MUTED)
    b += text(70, 170, "PRODUCTION / IMPORTED SOURCES", 19, GREEN, 800)
    srcs = [("Oura Cloud", "daily API summaries"),("Apple Health", "separate HealthKit read/import source"),("Polar H10", "hardware sensor path"),("EMAY Oximeter", "hardware / imported path"),("CPAP", "imported session data")]
    for i,(a,s) in enumerate(srcs): b += card(70, 195+i*112, 490, 88, a, s, GREEN if i else PURPLE)

    b += f'<rect x="610" y="195" width="350" height="550" rx="28" fill="{PANEL2}" stroke="{BLUE}" stroke-width="3"/>'
    b += text(785, 242, "Visible label examples", 27, TEXT, 750, "middle")
    b += multiline(645, 292, ["Selected Oura and demo", "surfaces identify source/mode."], 21, MUTED, 30)
    for i,(shape,label,col) in enumerate([("●","Oura Cloud",PURPLE),("◆","Apple Health / import",GREEN),("■","Live sensor",CYAN),("◇","Demo / simulated",GOLD)]):
        b += text(650, 385+i*62, shape, 28, col, 800) + text(695, 382+i*62, label, 20, TEXT, 650)
    b += f'<rect x="645" y="635" width="280" height="78" rx="12" fill="{BG}" stroke="{PURPLE}"/>'
    b += multiline(665, 662, ["Oura BLE foundation", "feature-gated · key required", "hardware-dependent"], 16, PURPLE, 20, 700)

    b += text(1010, 170, "ISOLATED DEMONSTRATIONS", 19, GOLD, 800)
    b += card(1010, 195, 520, 250, "Simulated Polar + EMAY session", ["DETERMINISTIC · HARDWARE-FREE", "six-hour logical demo clock"], GOLD, True)
    b += multiline(1045, 332, ["⊘ No production BLE or sensor session", "⊘ No HealthKit writes", "⊘ Simulated observations are not saved as readings"], 18, TEXT, 31, 650)
    b += card(1010, 480, 520, 265, "Isolated CNS UI demonstration", ["scripted: Clear → Watch → Confirm → Klaxon", "separate from production tier naming"], GOLD, True)
    b += multiline(1045, 630, ["⊘ No production monitoring or real notification", "⊘ No diagnosis or clinical certainty"], 18, TEXT, 32, 650)
    b += f'<path d="M985 195 V745" stroke="{GOLD}" stroke-width="4" stroke-dasharray="12 10"/>'
    b += text(1000, 782, "ISOLATION BOUNDARY", 16, GOLD, 800)
    b += f'<rect x="70" y="820" width="1460" height="100" rx="18" fill="{PANEL}" stroke="{BORDER}"/>'
    b += text(800, 858, "Deterministic app fixtures may be seeded into the demo store for screenshots.", 21, TEXT, 700, "middle")
    b += text(800, 891, "Physical Oura Ring 5 BLE protocol/decryption validation remains hardware-dependent.", 19, MUTED, 600, "middle")
    return svg_wrap("AnxietyWatch source provenance and demo boundaries", "Selected Oura and demo surfaces show source or mode labels. Oura Cloud, Apple Health, Polar H10, EMAY and CPAP remain distinct sources. Feature-gated Oura BLE requires key provisioning and remains hardware-dependent. Simulated Polar and EMAY observations activate no production Bluetooth or sensor session, write no HealthKit data, and are not saved as readings. The scripted CNS UI demonstration neither arms production monitoring nor sends a real notification or diagnosis. Deterministic application fixtures may be seeded into the demo store for screenshots.", 1600, 960, b)


def montage_v2():
    shots = prepare_shots()
    selected = [("dashboard", shots["dashboard"]), ("oura", shots["oura"]), ("trends", shots["trends"]), ("journal", shots["journal"])]
    b = text(70, 70, "Representative v3 dark-mode surfaces", 42, TEXT, 750)
    b += text(70, 110, "Four high-value views show the redesign at a readable scale.", 22, MUTED)
    b += f'<rect x="1130" y="45" width="310" height="56" rx="28" fill="{PANEL2}" stroke="{GOLD}"/>'
    b += text(1285, 81, "FICTIONAL DEMO DATA", 18, GOLD, 800, "middle")
    positions = [(70,165),(770,165),(70,790),(770,790)]
    details = {
      "dashboard":("Dashboard", "daily context", ["Status and risk context", "with latest sleep summary"]),
      "oura":("Oura data", "Oura Cloud / demo surface", ["Readiness, sleep and", "resilience summaries"]),
      "trends":("Trends", "time-based patterns", ["Anxiety and physiology", "across selected ranges"]),
      "journal":("Journal", "subjective anchor", ["Entries contextualize", "objective measurements"]),
    }
    for (slug,(path,_)),(x,y) in zip(selected,positions):
        title_value,badge,desc = details[slug]
        b += f'<rect x="{x}" y="{y}" width="630" height="565" rx="22" fill="{PANEL}" stroke="{BORDER}" stroke-width="2"/>'
        b += f'<clipPath id="clip2-{slug}"><rect x="{x+28}" y="{y+24}" width="270" height="500" rx="18"/></clipPath>'
        b += f'<image href="{data_uri(path)}" x="{x+28}" y="{y+24}" width="270" height="589" preserveAspectRatio="xMidYMin slice" clip-path="url(#clip2-{slug})"/>'
        b += text(x+340, y+95, title_value, 32, TEXT, 750)
        b += text(x+340, y+137, badge, 19, PURPLE if slug == "oura" else CYAN, 700)
        b += multiline(x+340, y+205, desc, 22, MUTED, 32)
        b += f'<rect x="{x+340}" y="{y+380}" width="225" height="54" rx="12" fill="{BG}" stroke="{GOLD}"/>'
        b += text(x+452, y+414, "FICTIONAL SIMULATOR", 15, GOLD, 800, "middle")
    b += f'<rect x="70" y="1415" width="1330" height="110" rx="20" fill="{PANEL2}" stroke="{GOLD}"/>'
    b += text(735, 1458, "Representative surfaces — the comprehensive walkthrough is not complete.", 22, TEXT, 700, "middle")
    b += text(735, 1494, "All shown values are deterministic and fictional; route choreography remains follow-up work.", 19, MUTED, 600, "middle")
    return svg_wrap("Representative AnxietyWatch v3 dark-mode surfaces", "Four large simulator screenshots show the Dashboard daily context, Oura Cloud and demo summary surface, Trends, and Journal. All shown values are fictional and deterministic. These representative surfaces do not claim a completed comprehensive walkthrough or hardware validation.", 1470, 1570, b)


def main():
    assets = {"architecture": architecture_v2(), "provenance": provenance_v2(), "ui-montage": montage_v2()}
    for name, content in assets.items():
        svg = RENDERED / f"{name}.svg"
        svg.write_text(content)
        subprocess.run(["rsvg-convert", str(svg), "-o", str(RENDERED / f"{name}.png")], check=True)
        print(svg)

if __name__ == "__main__":
    main()
