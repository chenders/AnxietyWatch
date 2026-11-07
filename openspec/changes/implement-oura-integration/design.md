# Oura Integration Design

## Overview

This design describes the architecture for Oura Ring integration, covering OAuth authentication, cloud API sync, data modeling, and UI integration.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AnxietyWatch App                          │
├─────────────────────────────────────────────────────────────────┤
│  OuraSettingsView ──► OuraOAuthManager ──► ASWebAuthSession     │
│         │                    │                                   │
│         ▼                    ▼                                   │
│  OuraService ◄────────► OuraTokenStore (Keychain)               │
│         │                                                        │
│         ▼                                                        │
│  OuraAPIClient ──────────────► Oura Cloud API                   │
│         │                                                        │
│         ▼                                                        │
│  OuraDataImporter ──► SwiftData (OuraSleepSession, etc.)        │
│         │                                                        │
│         ▼                                                        │
│  TrendsView / DashboardCard ◄── Query Oura models               │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### D1: OuraOAuthManager

Handles OAuth 2.0 PKCE flow:
- Generates code verifier and challenge
- Opens ASWebAuthenticationSession to Oura authorization URL
- Exchanges authorization code for tokens
- Stores tokens via OuraTokenStore

### D2: OuraTokenStore

Keychain-backed secure token storage:
- Access token, refresh token, expiry
- Automatic token refresh before expiry
- Revocation cleanup

### D3: OuraAPIClient

REST client for Oura Cloud API v2:
- Daily activity summaries
- Daily readiness summaries  
- Sleep sessions with stages
- Daily HRV summaries
- Rate limit handling (429 backoff)
- Incremental sync cursors

### D4: OuraService

Orchestrates sync lifecycle:
- Initial sync after OAuth
- Scheduled background sync (BGTaskScheduler)
- Manual refresh trigger
- Sync state machine (idle → syncing → complete/error)

### D5: Data Models

SwiftData models for Oura data:

```swift
@Model class OuraSleepSession {
    var id: String  // Oura's sleep ID
    var startTime: Date
    var endTime: Date
    var totalSleepSeconds: Int
    var remSeconds: Int
    var deepSeconds: Int
    var lightSeconds: Int
    var awakeSeconds: Int
    var sleepScore: Int?
    var syncedAt: Date
}

@Model class OuraDailyReadiness {
    var date: Date  // Day this applies to
    var score: Int
    var temperatureDeviation: Double?
    var restingHeartRate: Int?
    var hrvBalance: Int?
    var syncedAt: Date
}

@Model class OuraDailyActivity {
    var date: Date
    var score: Int
    var activeCalories: Int
    var steps: Int
    var totalCalories: Int
    var syncedAt: Date
}

@Model class OuraHRVSummary {
    var date: Date
    var averageHRV: Double
    var minHRV: Double?
    var maxHRV: Double?
    var syncedAt: Date
}
```

### D6: UI Components

- **OuraSettingsView**: Connection status, connect/disconnect buttons, last sync time, manual refresh
- **OuraDashboardCard**: Compact view of recent readiness, sleep score, HRV for main dashboard
- **OuraTrendsIntegration**: Overlay Oura HRV/sleep on existing trends charts
- **OuraSleepDetailView**: Full sleep session breakdown with stages

## Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | Use ASWebAuthenticationSession | Standard iOS OAuth flow, handles redirect |
| D2 | Store tokens in Keychain | Security best practice for credentials |
| D3 | Separate models from HealthKit | Different data shapes, provenance tracking |
| D4 | Background sync via BGTaskScheduler | Battery efficient, system-managed scheduling |
| D5 | Default 4-hour sync interval | Balance freshness vs battery/API limits |
| D6 | Retain data after disconnect | User may reconnect; don't lose history |

## Migration

No migration needed — this is a new feature addition.

## Testing Strategy

- **Unit**: OuraAPIClient response parsing, token refresh logic, sync cursor management
- **Integration**: Full OAuth → sync → query cycle with mock server
- **UI**: Settings connection flow, dashboard rendering with/without data

## Dependencies

- AuthenticationServices (ASWebAuthenticationSession)
- BackgroundTasks (BGTaskScheduler)
- SwiftData
- Keychain Services

## Risks

| Risk | Mitigation |
|------|------------|
| Oura API changes | Version-pin API, monitor deprecations |
| Rate limiting | Exponential backoff, respect 429 |
| Token expiry during background | Refresh before scheduling sync |
| User revokes access on Oura side | Handle 401, prompt re-auth |
