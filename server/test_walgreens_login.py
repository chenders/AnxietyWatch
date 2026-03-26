#!/usr/bin/env python3
"""Test script for Walgreens login — reads credentials from env vars or getpass."""

import getpass
import logging
import os
import sys

from walgreens_client import WalgreensClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    stream=sys.stdout,
)

email = os.environ.get("WAL_EMAIL") or input("Walgreens email: ")
password = os.environ.get("WAL_PASS") or getpass.getpass("Password: ")
answer = os.environ.get("WAL_ANSWER") or getpass.getpass(
    "Security question answer: "
)

client = WalgreensClient(
    username=email,
    password=password,
    security_answer=answer,
)

try:
    results = client.fetch_prescriptions()
    print(f"\nSUCCESS: {len(results)} prescriptions fetched")
    for r in results[:5]:
        print(f"  {r['medication_name']} — filled {r['date_filled']}")
except Exception as e:
    print(f"\nFAILED: {type(e).__name__}: {e}")
