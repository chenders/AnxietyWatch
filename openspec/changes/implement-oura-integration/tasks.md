# Oura Integration Tasks

## 1. Foundation

- [ ] 1.1 Create OuraTokenStore with Keychain storage for access/refresh tokens
- [ ] 1.2 Create OuraOAuthManager with PKCE flow and ASWebAuthenticationSession
- [ ] 1.3 Create OuraAPIClient with authenticated request handling and token refresh
- [ ] 1.4 Add Oura OAuth redirect URL to Info.plist URL schemes
- [ ] 1.5 Create Config/Oura.xcconfig for client ID (gitignored)

## 2. Data Models

- [ ] 2.1 Create OuraSleepSession SwiftData model
- [ ] 2.2 Create OuraDailyReadiness SwiftData model
- [ ] 2.3 Create OuraDailyActivity SwiftData model
- [ ] 2.4 Create OuraHRVSummary SwiftData model
- [ ] 2.5 Add Oura models to app schema and model container
- [ ] 2.6 Add Oura models to DataExporter
- [ ] 2.7 Add Oura models to RestoreFromServer

## 3. Sync Service

- [ ] 3.1 Create OuraService orchestrating sync lifecycle
- [ ] 3.2 Implement initial sync (fetch last 30 days on first connect)
- [ ] 3.3 Implement incremental sync with date cursors
- [ ] 3.4 Add BGTaskScheduler registration for background sync
- [ ] 3.5 Implement sync scheduling (4-hour default interval)
- [ ] 3.6 Add rate limit handling with exponential backoff
- [ ] 3.7 Add offline queue for failed sync attempts

## 4. UI - Settings

- [ ] 4.1 Create OuraSettingsView with connection status
- [ ] 4.2 Add Connect button triggering OAuth flow
- [ ] 4.3 Add Disconnect button with confirmation
- [ ] 4.4 Show last sync time and manual refresh button
- [ ] 4.5 Add OuraSettingsView to main Settings navigation
- [ ] 4.6 Handle OAuth callback in app delegate / scene delegate

## 5. UI - Dashboard & Trends

- [ ] 5.1 Create OuraDashboardCard showing recent metrics
- [ ] 5.2 Add OuraDashboardCard to main dashboard (when connected)
- [ ] 5.3 Create OuraSleepDetailView for sleep session breakdown
- [ ] 5.4 Integrate Oura HRV into TrendsView HRV chart
- [ ] 5.5 Add Oura sleep scores to sleep trends (if applicable)

## 6. Testing

- [ ] 6.1 Unit tests for OuraTokenStore
- [ ] 6.2 Unit tests for OuraAPIClient response parsing
- [ ] 6.3 Unit tests for OuraService sync state machine
- [ ] 6.4 Integration tests for OAuth → sync flow (mock server)
- [ ] 6.5 UI tests for OuraSettingsView connect/disconnect flow

## 7. Server Sync

- [ ] 7.1 Add Oura models to server schema (migration)
- [ ] 7.2 Add Oura entities to ENTITY_QUERIES for sync
- [ ] 7.3 Add server-side Oura API proxy (optional, for web dashboard)
- [ ] 7.4 Server tests for Oura entity sync

## 8. Documentation & Validation

- [ ] 8.1 Add Oura setup instructions to README
- [ ] 8.2 Document OAuth configuration in docs/
- [ ] 8.3 Run full test suite (app, package, server)
- [ ] 8.4 OpenSpec validation
- [ ] 8.5 Pre-PR review
