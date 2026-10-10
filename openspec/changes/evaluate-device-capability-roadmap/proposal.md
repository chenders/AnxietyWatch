# Proposal

## Why

The older Oura and Apple Watch Ultra plans mix completed foundations with optional, privacy-sensitive, legally constrained, or platform-dependent ideas. This change turns that material into explicit evidence and decision gates so unsupported ideas do not masquerade as committed implementation work.

## What Changes

- Verify the current official Oura API, account, OAuth, legal, and data-availability constraints and validate the existing cloud path with a live non-production account.
- Decide whether direct Oura BLE has enough documented protocol stability and user benefit to justify production support.
- Inventory the shipped Apple Watch/Ultra sensor foundation separately from proposed Action button, voice, State of Mind, location, ECG, prediction, and Smart Stack work.
- Record accept, defer, reject, or research outcomes with privacy, clinical, supportability, battery, and platform evidence.
- Create separate implementation changes only for accepted capabilities; this change does not silently authorize all legacy ideas.

## Capabilities

### New Capabilities

- `device-capability-governance`: Evidence, compatibility, privacy, and decision requirements for optional device integrations and platform features.

### Modified Capabilities

- None.

## Impact

This planning change may inspect Oura server/client integrations and watch capabilities but does not itself alter production behavior. HealthKit write proposals, location collection, or new wearable protocols require explicit acceptance and a follow-on change. There is no first-run, restore, server, or watchOS runtime change until a follow-on proposal is approved. Rollback is therefore documentary: rejected or deferred ideas remain inactive. User-data-loss risk is none; privacy and unsupported-protocol risk are the primary decision concerns.
