# Oura Ring 5 Integration Spec & Plan

## 1. Overview
This document defines the plan to integrate Oura Ring 5 into AnxietyWatch, achieving parity with existing devices (Polar H10, EMAY SleepO2) and adding new capabilities (Daytime Stress, Resilience). 

Based on research, the integration will primarily use the **Oura Cloud API V2** (via OAuth2 and webhooks) because it exposes true beat-to-beat Interbeat Interval (IBI) in milliseconds (`/v2/usercollection/interbeat_interval`), fulfilling our HRV requirements without needing complex BLE reverse-engineering.

## 2. Phased Implementation Plan

### Phase 0: Prerequisites (Manual / Setup)
1. **Developer Registration**: Register AnxietyWatch in Oura's Developer Portal to get `client_id` and `client_secret`.
2. **Legal & Compliance Review**: Ensure compliance with Oura's API terms (no AI training on user data, complementary analytics).
3. **Live Verification**: Test the `interbeat_interval` endpoint against a live Ring 5 account to verify daytime coverage and `heartrate` scope binding.

### Phase 1: Data Parity (API & App Logic)
1. **OAuth2 Flow**: Implement `ASWebAuthenticationSession` in iOS app to acquire Oura tokens.
2. **Backend Storage**: Add PostgreSQL tables (`oura_ibi`, `oura_sleep`, `oura_heartrate`, `oura_daily`, `oura_credentials`).
3. **Webhook Receiver**: Implement webhook endpoint to receive data sync notifications (`x-oura-signature` verification).
4. **Data Sync Engine**: Fetch `interbeat_interval` (for HRV), `sleep`, `daily_spo2`, `daily_readiness`.
5. **HealthKit Redundancy**: Add local read permissions for Oura-written types (Sleep stages, HR, Resp Rate, SpO2) as a fallback.

### Phase 2: New Capabilities (Anxiety Context)
1. **Stress & Resilience**: Fetch `daily_stress` (15-min cadence) and `daily_resilience`.
2. **UI Integration**: Surface daytime stress spikes and temperature deviations on the Anxiety dashboard.
3. **Cardiovascular Metrics**: Pull `daily_cardiovascular_age` and `vo2_max`.

### Phase 3: Direct BLE (Optional / Power User)
1. **Reverse-Engineered GATT**: Implement BLE client for real-time live HRV (if API daytime latency is insufficient).
2. **Key Import**: Support importing the 16-byte pairing key from Android extraction (iOS limits native extraction).

## 3. Execution Tasks (Automated Implementation)
Since Phase 0 requires real-world physical setup, the autonomous execution will focus on scaffolding **Phase 1 & 2**:
- **O1**: Create Oura OAuth2 Models & Token Manager (Swift).
- **O2**: Create Oura Cloud API Client for fetching IBI, Sleep, SpO2, Readiness (Swift).
- **O3**: Create Database Schema (SwiftData/SQLite models for Oura data).
- **O4**: Create HealthKit sync fallback for Oura types.

These tasks will be executed after the core redesign v3 tasks (T31-T40) are complete.
