# Watch Runtime Specification

## Purpose

Defines watchOS background-budget behavior and denormalized complication data delivery without direct database access from the extension.

## Requirements

### Requirement: Bounded background refresh
An application refresh SHALL spend no more than 500 ms on its SQLite commit and no more than 500 ms scheduling the next refresh plus enqueueing background work. It MUST complete promptly and MUST NOT await file transfer or delta pull. **Implementation status: background handler exists; replacement sync is intentionally not started on watch.**

#### Scenario: Refresh task is received
- **WHEN** watchOS delivers an application refresh task
- **THEN** local bounded work is enqueued or completed and the task is marked complete within its budget

### Requirement: Out-of-process continuation
Network synchronization initiated by a watch refresh SHALL use a background URL session so the operating system can continue it after refresh-task expiration. Cursor advancement MUST wait for a later acknowledged completion callback. **Implementation status: target behavior not fully integrated.**

#### Scenario: Refresh task expires after enqueue
- **WHEN** watchOS ends the refresh window after background upload was queued
- **THEN** the upload may continue out of process and no cursor advances until its acknowledgment callback

### Requirement: Retry ladder
Failed watch synchronization SHALL schedule the next attempt with exponential backoff from 15 minutes to four hours and plus-or-minus 20 percent jitter. After six consecutive failures, the watch SHALL send a lightweight urgent-sync context so the phone can pull. **Implementation status: package retry concepts exist; production watch path is incomplete.**

#### Scenario: Sixth consecutive synchronization failure occurs
- **WHEN** the sixth attempt fails without acknowledgment
- **THEN** the next refresh remains backoff-bounded and the watch publishes an urgent-sync hint to the paired phone

### Requirement: Complication isolation
The complication extension MUST NOT open the time-series database. The watch application SHALL publish denormalized complication state in the shared app-group container. **Implementation status: active watch feed and cache writer exist.**

#### Scenario: Complication timeline reloads
- **WHEN** the extension needs current state
- **THEN** it reads the shared denormalized cache without opening SQLite or querying live sensors

### Requirement: Coalesced atomic cache writes
Complication state submissions SHALL coalesce for 500 ms using a trailing-edge timer, keep the latest state, write to a temporary file, and atomically replace the shared cache. **Implementation status: implemented and tested.**

#### Scenario: Many states arrive within 500 ms
- **WHEN** multiple updates are submitted before the trailing timer fires
- **THEN** one atomic cache write publishes the final submitted state
