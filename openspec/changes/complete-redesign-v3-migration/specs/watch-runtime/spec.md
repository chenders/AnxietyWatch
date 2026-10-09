# Watch Runtime Delta

## ADDED Requirements

### Requirement: Background completion resumes sync state
The watch application SHALL reconnect background URL-session completion callbacks to the pending sync attempt, validate the server acknowledgment, and commit cursor state in a later wake.

#### Scenario: Upload finishes while app is suspended
- **WHEN** the operating system completes a queued upload out of process
- **THEN** the next delegate wake validates its response and atomically commits or retries the pending attempt

### Requirement: Read-only complication cache reader
The complication target SHALL provide a tested reader that decodes the latest atomic cache, tolerates absence or corruption, and never opens the time-series database.

#### Scenario: Cache file is missing or malformed
- **WHEN** the complication requests state before a valid cache exists
- **THEN** it returns an explicit stale or unavailable snapshot without crashing or querying SQLite

### Requirement: Failure escalation remains budget safe
The six-failure urgent-sync hint and all retry scheduling SHALL execute within watch background budgets and SHALL not keep a refresh task alive for network completion.

#### Scenario: Urgent-sync hint cannot be published
- **WHEN** the sixth-failure context update itself fails
- **THEN** the watch records the failure, schedules bounded retry, and still completes the refresh task promptly
