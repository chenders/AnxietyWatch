# Implement Oura Ring Integration

## Summary

Implement full Oura Ring integration for AnxietyWatch, enabling users to connect their Oura Ring and import sleep, activity, readiness, and HRV data for correlation with anxiety journal entries and medication efficacy tracking.

## Background

Oura Ring is a popular wearable that tracks sleep stages, HRV, respiratory rate, body temperature, and activity. This data is highly relevant to anxiety monitoring:
- Sleep quality and duration correlate with anxiety symptoms
- HRV is a physiological marker of stress and recovery
- Activity levels and readiness scores provide context for daily functioning

A partial Oura integration was previously implemented but removed in `remove/oura-integration` due to incomplete OAuth flow, missing error handling, and lack of test coverage. This change implements a complete, production-ready integration.

## Goals

1. **OAuth 2.0 Authentication**: Secure, user-friendly Oura account linking with proper token refresh and revocation handling
2. **Cloud API Sync**: Scheduled background fetch of sleep, activity, readiness, and daily HRV summaries
3. **BLE Direct Sync** (optional future): Real-time HRV streaming from Oura Ring via Bluetooth for live vitals display
4. **Data Visualization**: Dashboard views showing Oura metrics alongside anxiety entries and medication logs
5. **Correlation Insights**: Surface patterns between Oura metrics and user-reported anxiety (e.g., "Your anxiety tends to be higher after nights with <6h sleep")

## Non-Goals

- Real-time clinical alerting based on Oura data (that belongs to AnxietyWatch2)
- Oura data as a replacement for HealthKit (Oura remains a supplementary source)
- Automatic anxiety predictions from Oura data alone

## Requirements

### R1: OAuth Authentication
- Implement OAuth 2.0 PKCE flow for Oura API
- Securely store tokens in Keychain
- Handle token refresh automatically
- Provide clear disconnect/revoke UI
- Handle authorization errors gracefully

### R2: Cloud Sync
- Fetch daily summaries: sleep, activity, readiness, HRV
- Implement incremental sync (only fetch new data since last sync)
- Background refresh on schedule (configurable, default 4 hours)
- Rate limit compliance (Oura API limits)
- Offline resilience (queue failed requests)

### R3: Data Model
- Define SwiftData models for Oura-sourced data
- Maintain source provenance (distinguish Oura vs HealthKit)
- Support server sync/restore round-trip
- Add export support for Oura data

### R4: Visualization
- Settings view for Oura connection management
- Dashboard card showing recent Oura metrics
- Trends integration showing Oura data alongside other sources
- Sleep detail view with Oura sleep stages

### R5: Testing
- Unit tests for OAuth flow, token management, API client
- Integration tests for sync pipeline
- UI tests for settings and dashboard

## Deferred

- BLE direct streaming (future phase)
- Oura Gen 4 specific features
- Correlation engine / insights (separate change)

## Acceptance Criteria

1. User can connect Oura account via OAuth in Settings
2. App fetches and displays last 7 days of Oura data after connection
3. Background sync updates data every 4 hours
4. Oura data appears in Trends alongside HealthKit data
5. User can disconnect Oura and data is retained (but marked historical)
6. All tests pass, no new warnings
7. Works offline (shows cached data, queues sync)
