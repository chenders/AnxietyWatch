"""HTTP client for the ez Share WiFi SD card's directory API.

The card exposes files over plain HTTP at http://192.168.4.1. Directory
listings come back as HTML (charset gb2312): each <a> inside the <pre>
block is a file (href .../download?file=<8.3 shortname>) or a subdirectory
(href dir?dir=A:%5C<name>). Directories show "<DIR>" (HTML-entity-encoded as
&lt;DIR&gt;) in the size column. Sizes are whole-KB, so any dedup keys on
(name, kb_size), never exact bytes.

Validated live against a real ResMed AirSense 11 + ez Share card on
2026-07-23 (firmware LZ1640EDPG:2.0.7). For CPAP ingest, the file that
matters is the top-level STR.EDF (cumulative daily summary); the DATALOG/
folders hold high-resolution waveforms that are a deferred V2 concern.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass

import requests
from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

_FILE_HREF = re.compile(r"download\?file=([^&\"']+)")
_KB = re.compile(r"(\d+)\s*KB")

# Non-data entries to skip in a listing: card control files + macOS metadata
# that appears whenever the card has been mounted on a Mac (confirmed present
# in the live listing) + Windows recycle metadata. Compared case-insensitively
# because the card reports e.g. "journal.jnl" lowercase.
_SKIP_NAMES = {
    "ezshare.cfg", "journal.jnl", "system volume information",
    ".fseventsd", ".spotlight-v100", ".trashes", ".ds_store",
    "identification.json", "identification.crc",
}


def _is_noise(name: str) -> bool:
    return name.lower() in _SKIP_NAMES or name.startswith("._")


@dataclass
class DirEntry:
    name: str
    shortname: str | None   # 8.3 download name for files, None for dirs
    is_dir: bool
    kb_size: int | None     # whole KB for files, None for dirs
    href: str


def parse_dir_listing(html: str) -> list[DirEntry]:
    """Parse an ez Share /dir HTML page into DirEntry rows (noise filtered)."""
    soup = BeautifulSoup(html, "lxml")
    pre = soup.find("pre")
    if pre is None:
        return []
    entries: list[DirEntry] = []
    for a in pre.find_all("a"):
        href = str(a.get("href") or "")
        name = a.get_text(strip=True)
        if not name or _is_noise(name):
            continue
        is_dir = "dir?dir=" in href
        m = _FILE_HREF.search(href)
        shortname = m.group(1) if m else None
        meta_text = str(a.previous_sibling) if a.previous_sibling else ""
        kb_match = _KB.search(meta_text)
        kb_size = None if is_dir or kb_match is None else int(kb_match.group(1))
        entries.append(DirEntry(name=name, shortname=shortname,
                                is_dir=is_dir, kb_size=kb_size, href=href))
    return entries


# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------


class EzShareError(Exception):
    """Base class for ez Share client errors."""


class EzShareUnreachable(EzShareError):
    """The card AP did not answer — the expected state when the CPAP is off."""


class EzShareLegacyFirmware(EzShareError):
    """Card exposes only the legacy photo-gallery API (no /dir)."""


class EzShareHTTPError(EzShareError):
    """Unexpected HTTP response or invalid downloaded content."""


class EzShareClient:
    def __init__(self, base_url: str = "http://192.168.4.1", timeout: float = 15.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _get(self, path: str) -> requests.Response:
        url = path if path.startswith("http") else f"{self.base_url}/{path.lstrip('/')}"
        try:
            resp = requests.get(url, timeout=self.timeout)
        except requests.exceptions.RequestException as exc:
            raise EzShareUnreachable(str(exc)) from exc
        if resp.status_code != 200:
            raise EzShareHTTPError(f"{url} -> HTTP {resp.status_code}")
        return resp

    def version(self) -> str:
        """Return the firmware version string. Raises on unreachable/legacy."""
        text = self._get("client?command=version").content.decode("gb2312", "replace")
        m = re.search(r"<version>([^<]+)</version>", text)
        if not m:
            raise EzShareLegacyFirmware("no <version> in response")
        return m.group(1).strip()

    def list_dir(self, path: str = "A:") -> list[DirEntry]:
        # Backslashes in the path are URL-encoded as %5C by the caller.
        text = self._get(f"dir?dir={path}").content.decode("gb2312", "replace")
        return parse_dir_listing(text)

    def download(self, entry: DirEntry) -> bytes:
        if entry.shortname is None:
            raise EzShareHTTPError(f"{entry.name} is not a downloadable file")
        data = self._get(f"download?file={entry.shortname}").content
        if entry.name.lower().endswith(".edf") and not data.startswith(b"0"):
            # EDF's 8-byte version field is '0' left-justified; anything else
            # is a truncated/garbled transfer — reject so the caller retries.
            raise EzShareHTTPError(f"{entry.name}: invalid EDF header")
        return data

    def download_str_edf(self) -> bytes | None:
        """Download the top-level STR.EDF (cumulative daily summary), or None."""
        entry = next((e for e in self.list_dir("A:")
                      if not e.is_dir and e.name.upper() == "STR.EDF"), None)
        return self.download(entry) if entry else None

    def datalog_days(self, since_yyyymmdd: str | None = None) -> list[str]:
        """Return DATALOG day-folder names (YYYYMMDD), optionally on/after a cursor.

        Not used by the V1 summary path (STR.EDF carries all daily metrics); kept
        for a future waveform-detail ingest.
        """
        days = [e.name for e in self.list_dir("A:%5CDATALOG")
                if e.is_dir and e.name.isdigit() and len(e.name) == 8]
        if since_yyyymmdd:
            days = [d for d in days if d >= since_yyyymmdd]  # inclusive: EDFs grow
        return sorted(days)
