"""Tests for the APNs client wrapper (``server/apns.py``).

The HTTP send is mocked via an injected transport seam — no real APNs endpoint is
contacted in CI. Tests assert:

* payload shape — Time-Sensitive interruption level (no critical sound dict) vs the
  ``{"critical": 1, ...}`` sound dict on a Critical Alert;
* request construction — correct host, headers (``apns-priority: 10``,
  ``apns-push-type: alert``, ``authorization: bearer <jwt>``, topic);
* one ``send`` call produces exactly one push;
* no secret (device token / signed JWT) ever reaches the logs.

All test data is obviously fictional (see the repo Sensitive Data Rules): the device
token is the literal string ``fictional-device-token`` and the key/team ids are fake.
The signing key is a throwaway P-256 key generated per-test — never a real ``.p8``.
"""

import base64
import json
import logging

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import apns

FICTIONAL_TOKEN = "fictional-device-token"
FICTIONAL_KEY_ID = "KEY1234567"
FICTIONAL_TEAM_ID = "TEAM123456"
FICTIONAL_TOPIC = "org.example.anxietywatch.fictional"


def _fictional_p8_pem() -> bytes:
    """A throwaway P-256 private key in PKCS#8 PEM — stands in for the APNs ``.p8``."""
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def _b64url_decode(segment: str) -> bytes:
    """Decode a base64url JWT segment that has had its ``=`` padding stripped."""
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


@pytest.fixture
def config():
    return apns.ApnsConfig(
        auth_key_pem=_fictional_p8_pem(),
        key_id=FICTIONAL_KEY_ID,
        team_id=FICTIONAL_TEAM_ID,
        topic=FICTIONAL_TOPIC,
        use_sandbox=True,
    )


class _RecordingTransport:
    """Mockable HTTP seam: records each call and returns a canned response."""

    def __init__(self, status=200):
        self.calls = []
        self._status = status

    def __call__(self, url, headers, body):
        self.calls.append((url, headers, body))
        return apns.ApnsTransportResponse(
            status=self._status, apns_id="fictional-apns-id", body=""
        )


# (1) build_payload(critical=False) -> Time-Sensitive, no critical sound dict.
def test_build_payload_non_critical_is_time_sensitive():
    payload = apns.build_payload(apns.KIND_BACKSTOP, critical=False)
    aps = payload["aps"]
    assert aps["interruption-level"] == "time-sensitive"
    # A Time-Sensitive push carries a plain sound string, never the critical dict.
    assert not isinstance(aps["sound"], dict)
    assert aps["alert"]["title"]
    assert aps["alert"]["body"]


# (2) build_payload(critical=True) -> aps.sound is the {"critical": 1, ...} dict.
def test_build_payload_critical_has_critical_sound_dict():
    payload = apns.build_payload(apns.KIND_BACKSTOP, critical=True)
    aps = payload["aps"]
    sound = aps["sound"]
    assert isinstance(sound, dict)
    assert sound["critical"] == 1
    assert sound["name"]
    assert isinstance(sound["volume"], float)
    assert 0.0 <= sound["volume"] <= 1.0
    assert aps["interruption-level"] == "critical"


def test_build_payload_kinds_have_distinct_copy():
    backstop = apns.build_payload(apns.KIND_BACKSTOP, critical=False)
    heartbeat = apns.build_payload(apns.KIND_HEARTBEAT, critical=False)
    # A desaturation backstop and a "monitoring may have stopped" heartbeat must
    # not read identically — they mean different things to the person reading them.
    assert backstop["aps"]["alert"]["body"] != heartbeat["aps"]["alert"]["body"]


# (3) send() constructs the correct host + headers against a MOCK (no network).
def test_send_posts_to_sandbox_host_with_expected_headers(config):
    transport = _RecordingTransport()
    payload = apns.build_payload(apns.KIND_BACKSTOP, critical=False)

    result = apns.send(
        FICTIONAL_TOKEN, payload, critical=False, config=config, transport=transport
    )

    assert result.ok
    assert len(transport.calls) == 1
    url, headers, body = transport.calls[0]
    assert url == f"https://api.sandbox.push.apple.com/3/device/{FICTIONAL_TOKEN}"
    assert headers["apns-priority"] == "10"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-topic"] == FICTIONAL_TOPIC

    auth = headers["authorization"]
    assert auth.startswith("bearer ")
    jwt = auth.split(" ", 1)[1]
    header_seg, claims_seg, sig_seg = jwt.split(".")
    header = json.loads(_b64url_decode(header_seg))
    assert header["alg"] == "ES256"
    assert header["kid"] == FICTIONAL_KEY_ID
    claims = json.loads(_b64url_decode(claims_seg))
    assert claims["iss"] == FICTIONAL_TEAM_ID
    assert claims["iat"] > 0
    # ES256 (P-256) JWS signature is a fixed 64-byte r||s pair.
    assert len(_b64url_decode(sig_seg)) == 64
    # The wire body is exactly the payload we built.
    assert json.loads(body) == payload


def test_send_uses_production_host_when_not_sandbox(config):
    prod = apns.ApnsConfig(
        auth_key_pem=config.auth_key_pem,
        key_id=config.key_id,
        team_id=config.team_id,
        topic=config.topic,
        use_sandbox=False,
    )
    transport = _RecordingTransport()

    apns.send(
        FICTIONAL_TOKEN,
        apns.build_payload(apns.KIND_HEARTBEAT),
        config=prod,
        transport=transport,
    )

    url, _headers, _body = transport.calls[0]
    assert url == f"https://api.push.apple.com/3/device/{FICTIONAL_TOKEN}"


# (4) One raise -> exactly one push (per-call; idempotency is enforced upstream).
def test_one_send_produces_exactly_one_push(config):
    transport = _RecordingTransport()

    apns.send(
        FICTIONAL_TOKEN,
        apns.build_payload(apns.KIND_BACKSTOP, critical=True),
        critical=True,
        config=config,
        transport=transport,
    )

    assert len(transport.calls) == 1


def test_send_never_logs_device_token_or_jwt(config, caplog):
    transport = _RecordingTransport()
    with caplog.at_level(logging.DEBUG):
        apns.send(
            FICTIONAL_TOKEN,
            apns.build_payload(apns.KIND_BACKSTOP),
            config=config,
            transport=transport,
        )

    logged = " ".join(record.getMessage() for record in caplog.records)
    assert FICTIONAL_TOKEN not in logged
    _url, headers, _body = transport.calls[0]
    jwt = headers["authorization"].split(" ", 1)[1]
    assert jwt not in logged


def test_send_non_2xx_reports_failure_without_raising(config):
    transport = _RecordingTransport(status=410)  # 410 Gone = unregistered token
    result = apns.send(
        FICTIONAL_TOKEN,
        apns.build_payload(apns.KIND_BACKSTOP),
        config=config,
        transport=transport,
    )
    assert result.ok is False
    assert result.status == 410


def test_from_env_reads_inline_key_contents(monkeypatch):
    pem = _fictional_p8_pem()
    monkeypatch.setenv("APNS_AUTH_KEY", pem.decode("ascii"))
    monkeypatch.setenv("APNS_KEY_ID", FICTIONAL_KEY_ID)
    monkeypatch.setenv("APNS_TEAM_ID", FICTIONAL_TEAM_ID)
    monkeypatch.setenv("APNS_TOPIC", FICTIONAL_TOPIC)
    monkeypatch.setenv("APNS_ENV", "sandbox")

    cfg = apns.ApnsConfig.from_env()

    assert cfg.use_sandbox is True
    assert cfg.key_id == FICTIONAL_KEY_ID
    assert cfg.team_id == FICTIONAL_TEAM_ID
    assert cfg.topic == FICTIONAL_TOPIC
    assert cfg.host == "api.sandbox.push.apple.com"


def test_from_env_reads_key_from_path(monkeypatch, tmp_path):
    pem = _fictional_p8_pem()
    key_file = tmp_path / "AuthKey_FICTIONAL.p8"
    key_file.write_bytes(pem)
    monkeypatch.delenv("APNS_AUTH_KEY", raising=False)
    monkeypatch.setenv("APNS_AUTH_KEY_PATH", str(key_file))
    monkeypatch.setenv("APNS_KEY_ID", FICTIONAL_KEY_ID)
    monkeypatch.setenv("APNS_TEAM_ID", FICTIONAL_TEAM_ID)
    monkeypatch.setenv("APNS_TOPIC", FICTIONAL_TOPIC)
    monkeypatch.setenv("APNS_ENV", "production")

    cfg = apns.ApnsConfig.from_env()

    assert cfg.auth_key_pem == pem
    assert cfg.use_sandbox is False
    assert cfg.host == "api.push.apple.com"


def test_from_env_missing_key_raises(monkeypatch):
    for var in (
        "APNS_AUTH_KEY",
        "APNS_AUTH_KEY_PATH",
        "APNS_KEY_ID",
        "APNS_TEAM_ID",
        "APNS_TOPIC",
    ):
        monkeypatch.delenv(var, raising=False)
    with pytest.raises(apns.ApnsConfigError):
        apns.ApnsConfig.from_env()
