"""APNs client wrapper for the redundant server alert channel (sub-project C).

This is the *secondary* alert path (parent klaxon design §1): it can only ever
*add* an alert, never suppress or downgrade the on-device decision. Two alert
kinds are pushed by the server:

* :data:`KIND_BACKSTOP` — the conservative fixed-floor backstop noticed a sustained
  desaturation (see ``server/backstop.py``);
* :data:`KIND_HEARTBEAT` — an armed session's live upload stopped, so monitoring
  may have stopped (the dead-man's-switch that survives the phone being dead).

Delivery ships as a **Time-Sensitive** high-priority push today (breaks Focus,
respects the mute switch, needs no Apple approval) and upgrades to a **Critical
Alert** once sub-project A's entitlement lands — flip ``critical=True`` per call
(spec §3 / §5). Priority is always ``10``.

Security (repo Sensitive Data Rules + plan Global Constraints):
    * Every credential — the ``.p8`` auth key, key id, team id, topic, and the
      sandbox/production environment — comes from ENV VARS only (see
      :meth:`ApnsConfig.from_env`). Nothing is hardcoded.
    * Auth keys, signed JWTs, and device tokens are NEVER logged. Only
      non-identifying metadata (presence / length / host / status) is logged.

The actual HTTP call sits behind a thin, injectable ``transport`` seam so tests
mock it and no network is touched in CI. APNs requires HTTP/2; the default
transport uses ``httpx`` (see :func:`_default_transport`).
"""

import base64
import json
import logging
import os
import time
from collections import namedtuple
from dataclasses import dataclass

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

logger = logging.getLogger(__name__)

# --- APNs hosts (Apple, fixed) ---------------------------------------------
PRODUCTION_HOST = "api.push.apple.com"
SANDBOX_HOST = "api.sandbox.push.apple.com"
DEVICE_PATH = "/3/device/"

# --- Push framing -----------------------------------------------------------
# Priority 10 = deliver immediately (spec §3: high-priority alert). Push type
# "alert" is required for alert (non-silent) notifications.
PRIORITY_IMMEDIATE = 10
PUSH_TYPE_ALERT = "alert"

# Interruption levels: Time-Sensitive today; Critical once A's entitlement lands.
INTERRUPTION_TIME_SENSITIVE = "time-sensitive"
INTERRUPTION_CRITICAL = "critical"

# Non-critical pushes play the standard alert sound; Critical Alerts require the
# {"critical": 1, ...} sound dict with an explicit volume (0.0-1.0).
DEFAULT_SOUND = "default"
# "default" is guaranteed present; swap for a bundled klaxon sound file if desired.
CRITICAL_SOUND_NAME = "default"
CRITICAL_SOUND_VOLUME = 1.0  # life-safety backstop -> full volume

# --- Alert kinds ------------------------------------------------------------
KIND_BACKSTOP = "backstop"
KIND_HEARTBEAT = "heartbeat"

# Title/body per kind. Copy is deliberately factual and free of any personal or
# medical identifiers.
_ALERT_TEXT = {
    KIND_BACKSTOP: (
        "Low blood oxygen — backup check",
        "The backup monitor has seen sustained low blood oxygen. "
        "Check on monitoring now.",
    ),
    KIND_HEARTBEAT: (
        "Monitoring may have stopped",
        "The backup monitor stopped receiving data. "
        "Confirm that monitoring is still running.",
    ),
}
_DEFAULT_ALERT_TEXT = (
    "Anxiety Watch alert",
    "The backup monitor raised an alert. Check on monitoring now.",
)

DEFAULT_TIMEOUT_SECONDS = 10.0

# Transport response: what the HTTP seam returns to :func:`send`.
ApnsTransportResponse = namedtuple("ApnsTransportResponse", ["status", "apns_id", "body"])

# Result of a send: whether APNs accepted it, plus the status/id for the caller.
ApnsResult = namedtuple("ApnsResult", ["ok", "status", "apns_id"])


class ApnsError(Exception):
    """Base error for the APNs wrapper."""


class ApnsConfigError(ApnsError):
    """Raised when required APNs configuration is missing or malformed."""


@dataclass(frozen=True)
class ApnsConfig:
    """APNs credentials + target environment, sourced from env vars.

    ``auth_key_pem`` holds the ``.p8`` private key bytes (PKCS#8 PEM). It is held
    only in memory and never logged.
    """

    auth_key_pem: bytes
    key_id: str
    team_id: str
    topic: str
    use_sandbox: bool

    @property
    def host(self) -> str:
        return SANDBOX_HOST if self.use_sandbox else PRODUCTION_HOST

    @classmethod
    def from_env(cls, env=None) -> "ApnsConfig":
        """Build config from environment variables (the only source of secrets).

        Env vars:
            APNS_AUTH_KEY      inline ``.p8`` PEM contents (takes precedence), or
            APNS_AUTH_KEY_PATH filesystem path to the ``.p8`` file;
            APNS_KEY_ID        the 10-char key id from the Apple Developer portal;
            APNS_TEAM_ID       the 10-char Apple team id;
            APNS_TOPIC         the app bundle id (APNs topic);
            APNS_ENV           "sandbox" (default) or "production".
        """
        env = os.environ if env is None else env
        auth_key_pem = _load_auth_key(env)
        key_id = _require(env, "APNS_KEY_ID")
        team_id = _require(env, "APNS_TEAM_ID")
        topic = _require(env, "APNS_TOPIC")
        environment = env.get("APNS_ENV", "sandbox").strip().lower()
        if environment not in ("sandbox", "production"):
            raise ApnsConfigError(
                "APNS_ENV must be 'sandbox' or 'production' (got an unexpected value)"
            )
        return cls(
            auth_key_pem=auth_key_pem,
            key_id=key_id,
            team_id=team_id,
            topic=topic,
            use_sandbox=(environment == "sandbox"),
        )


def _require(env, name: str) -> str:
    value = env.get(name)
    if not value or not value.strip():
        raise ApnsConfigError(f"Missing required APNs env var: {name}")
    return value.strip()


def _load_auth_key(env) -> bytes:
    """Return the ``.p8`` PEM bytes from inline contents or a file path.

    Never logs the key material — only which source was used.
    """
    inline = env.get("APNS_AUTH_KEY")
    if inline and inline.strip():
        return inline.encode("utf-8")
    path = env.get("APNS_AUTH_KEY_PATH")
    if path and path.strip():
        try:
            with open(path.strip(), "rb") as handle:
                return handle.read()
        except OSError as exc:
            # Report the failure without echoing the (potentially sensitive) path.
            raise ApnsConfigError("Could not read APNS_AUTH_KEY_PATH") from exc
    raise ApnsConfigError(
        "Missing APNs auth key: set APNS_AUTH_KEY (inline .p8) or APNS_AUTH_KEY_PATH"
    )


def build_payload(kind: str, critical: bool = False) -> dict:
    """Build the APNs payload dict for an alert of ``kind``.

    When ``critical`` is False the payload is a **Time-Sensitive** alert
    (``aps.interruption-level == "time-sensitive"``) with a plain sound string.
    When ``critical`` is True it is a **Critical Alert**: ``aps.sound`` becomes
    the ``{"critical": 1, "name": <sound>, "volume": <float>}`` dict that plays
    bypassing the mute switch and Focus (requires the Critical Alerts
    entitlement — sub-project A).
    """
    title, body = _ALERT_TEXT.get(kind, _DEFAULT_ALERT_TEXT)
    # dict[str, object]: the value types are heterogeneous (a nested alert dict,
    # then a str or the critical-sound dict, then an interruption-level str), so
    # the container is annotated wide rather than inferred to the first entry.
    aps: dict[str, object] = {"alert": {"title": title, "body": body}}
    if critical:
        aps["sound"] = {
            "critical": 1,
            "name": CRITICAL_SOUND_NAME,
            "volume": CRITICAL_SOUND_VOLUME,
        }
        aps["interruption-level"] = INTERRUPTION_CRITICAL
    else:
        aps["sound"] = DEFAULT_SOUND
        aps["interruption-level"] = INTERRUPTION_TIME_SENSITIVE
    return {"aps": aps}


def _b64url(data: bytes) -> str:
    """Base64url-encode without padding (JWS/JWT segment encoding)."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def build_jwt(config: ApnsConfig, issued_at=None) -> str:
    """Build a signed APNs provider JWT (ES256) from the ``.p8`` key.

    The signature is the raw 64-byte ``r || s`` form JWS requires — not the DER
    encoding ``cryptography`` returns — so we convert it explicitly. The returned
    token is a credential and must never be logged.
    """
    if issued_at is None:
        issued_at = int(time.time())
    header = {"alg": "ES256", "kid": config.key_id}
    claims = {"iss": config.team_id, "iat": issued_at}
    signing_input = "{}.{}".format(
        _b64url(json.dumps(header, separators=(",", ":")).encode("utf-8")),
        _b64url(json.dumps(claims, separators=(",", ":")).encode("utf-8")),
    )
    private_key = serialization.load_pem_private_key(config.auth_key_pem, password=None)
    if not isinstance(private_key, ec.EllipticCurvePrivateKey):
        raise ApnsConfigError("APNs auth key must be an EC P-256 (.p8) private key")
    der_signature = private_key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_signature)
    raw_signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return "{}.{}".format(signing_input, _b64url(raw_signature))


def _default_transport(url, headers, body):
    """Default HTTP/2 transport (APNs requires HTTP/2).

    Imported lazily so the module — and the mocked tests — do not need ``httpx``.
    ``httpx[http2]`` is NOT yet in ``server/requirements.txt``; add it before the
    live send path is exercised in production, or inject a custom ``transport``.
    """
    try:
        import httpx
    except ImportError as exc:  # pragma: no cover - exercised only without httpx
        raise ApnsError(
            "APNs send needs an HTTP/2 client. Add 'httpx[http2]' to "
            "requirements.txt or pass transport= to send()."
        ) from exc
    with httpx.Client(http2=True, timeout=DEFAULT_TIMEOUT_SECONDS) as client:
        response = client.post(url, headers=headers, content=body)
    return ApnsTransportResponse(
        status=response.status_code,
        apns_id=response.headers.get("apns-id"),
        body=response.text,
    )


def send(token, payload, *, critical=False, config=None, use_sandbox=None,
         transport=None, issued_at=None) -> ApnsResult:
    """Send one APNs push for ``payload`` to ``token``.

    Builds a fresh provider JWT from the ``.p8`` key, targets the correct APNs
    host (sandbox vs production), and POSTs with ``apns-priority: 10`` and
    ``apns-push-type: alert``. The HTTP call goes through ``transport`` (a
    callable ``(url, headers, body) -> ApnsTransportResponse``) so it is mockable;
    when omitted it defaults to :func:`_default_transport`.

    ``critical`` selects the Critical-Alert delivery headers; it should match the
    ``critical`` used to build ``payload``. Idempotency (one push per alert event)
    is the caller's responsibility (``alert_event``); this function performs
    exactly one send per call.

    A non-2xx APNs status is logged (metadata only) and returned as
    ``ApnsResult(ok=False, ...)`` rather than raised — a redundant channel must
    not crash its caller on a delivery failure.
    """
    cfg = config if config is not None else ApnsConfig.from_env()
    sandbox = cfg.use_sandbox if use_sandbox is None else use_sandbox
    host = SANDBOX_HOST if sandbox else PRODUCTION_HOST
    url = "https://{}{}{}".format(host, DEVICE_PATH, token)

    jwt = build_jwt(cfg, issued_at=issued_at)
    headers = {
        "authorization": "bearer {}".format(jwt),
        "apns-topic": cfg.topic,
        "apns-priority": str(PRIORITY_IMMEDIATE),
        "apns-push-type": PUSH_TYPE_ALERT,
    }
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")

    # Log only non-identifying metadata: never the token, JWT, or key material.
    logger.info(
        "APNs push: host=%s critical=%s token_present=%s token_len=%d body_bytes=%d",
        host,
        critical,
        bool(token),
        len(token) if token else 0,
        len(body),
    )

    send_fn = transport if transport is not None else _default_transport
    response = send_fn(url, headers, body)
    ok = 200 <= response.status < 300
    if not ok:
        logger.warning("APNs push rejected: host=%s status=%s", host, response.status)
    return ApnsResult(ok=ok, status=response.status, apns_id=response.apns_id)
