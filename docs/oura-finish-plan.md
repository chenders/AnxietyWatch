# Oura Ring Integration — Gap Report & Finish Plan

## 1. Gap Report

### (1) OAuth2 Authorization Flow
**Status:** **Not implemented.**
- The `OuraSettingsView` is reachable from the app's navigation (via `SettingsView` -> `DevicesSettingsView`).
- However, it relies entirely on a manual "Personal access token" pasted into a `SecureField`.
- There is no `ASWebAuthenticationSession` implemented to handle the OAuth2 authorization-code link flow.
- The app does not exchange an auth code for a token, nor does it pass credentials to the backend.

### (2) Data Polling and Persistence
**Status:** **Incomplete.**
- **iOS (`OuraService.swift`):** The polling loop (`startPolling()`) ONLY fetches `interbeat_interval` (IBI) and pushes it to the `SensorRouter` (which saves it to the local SQLite `samples` table). All other data types (sleep, readiness, resilience, daily_stress, daily_spo2, heartrate, daily_cardiovascular_age, vo2_max) are only fetched on-demand when opening `OuraDataDashboardView`. They are currently surfaced in the dashboard UI but are **never persisted** to the server or local DB.
- **Server (`server/delta_oura_patch.py`):** The PostgreSQL tables (`oura_sleep`, `oura_daily`, `oura_heartrate`, etc.) exist, but are never populated. The webhook endpoint (`/webhooks/oura`) verifies the signature but its worker is just a `# Worker implementation stub` (~line 222).
- **Missing in Stub:** The server needs a background worker that takes the webhook event, looks up the user's credentials from `oura_credentials`, fetches the new/updated records from the Oura Cloud API, and inserts/updates the rows in the respective `oura_*` tables. Additionally, there is no endpoint for the iOS app to supply its OAuth token to populate `oura_credentials` in the first place.

### (3) Stubbed / Broken Components
- **BLE Implementation (`OuraBLEActor.swift`):** The entire CoreBluetooth stack is stubbed. `connect()` and `disconnect()` merely update internal state without performing any BLE scanning, AES nonce authentication, or characteristic subscriptions.
- **Token Synchronization:** There is no mechanism to sync the Oura token from iOS to the Python backend so the backend can perform its webhook-triggered fetches.

### (4) Live Prerequisites (What the User Must Provide)
For this integration to function end-to-end against production, the user must provide:
1. **Oura Developer Application:** A registered OAuth application in the Oura Developer Portal to obtain a `Client ID` and `Client Secret`.
2. **Redirect URI:** A configured URI in the Oura Portal matching the iOS app's custom URL scheme or Universal Link.
3. **Active Oura Membership:** Required for API access.
4. **Environment Variables:** The server must be run with `OURA_CLIENT_SECRET` populated to verify webhook signatures.
5. **(Optional Phase 3) BLE Key:** For the stubbed BLE live HRV, a 16-byte pairing key extracted from a paired Android device.

---

## 2. Finish Plan (Parallel Workstreams)

The following workstreams are independent and can be executed in parallel by different agents.

### Workstream A: OAuth2 Flow & Token Sync
**Goal:** Replace the manual Personal Access Token field with a true OAuth2 flow, and securely transmit the resulting token to the backend `oura_credentials` table.
- **Files Touched:**
  - `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraService.swift`
  - `AnxietyWatch/Views/OuraSettingsView.swift`
  - `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraAPIClient.swift` (add server sync method)
  - `server/delta_oura_patch.py` (add POST `/api/oura/auth` endpoint to upsert `oura_credentials`)
- **Live Credentials Needed:** **Yes.** Requires an Oura Client ID/Secret and configured Redirect URI to test the OAuth flow interactively.

### Workstream B: Server Webhook Worker & Data Ingestion
**Goal:** Fulfill the Phase 1/Phase 2 data parity promise by replacing the webhook stub with an active fetcher that writes to the Postgres tables.
- **Files Touched:**
  - `server/delta_oura_patch.py` (implement the worker stub)
  - `server/requirements.txt` (if background task queue like Celery/RQ is needed, or just a simple threaded background executor)
- **Details:** When a webhook fires for `sleep`, `daily_readiness`, etc., the worker must fetch the changed date range using the token from `oura_credentials` and execute UPSERTs into `oura_sleep`, `oura_daily`, `oura_heartrate`, etc.
- **Live Credentials Needed:** **Yes.** Requires a valid Oura token in the database and the Client Secret to verify inbound webhooks (or trigger fetches manually for testing).

### Workstream C: iOS CoreBluetooth Implementation (Phase 3 Optional)
**Goal:** Implement the missing real-time BLE GATT client for HRV to replace the placeholder `OuraBLEActor.swift`.
- **Files Touched:**
  - `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor.swift`
  - `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEProtocol.swift`
- **Details:** Add `CBCentralManager` delegation, discover the Oura ring, perform AES-ECB nonce challenge-response auth using the provided key, and decode the streaming characteristics into `SensorRouter` samples.
- **Live Credentials Needed:** **Yes.** Requires a physical Oura Ring 5 and the extracted 16-byte AES key.
