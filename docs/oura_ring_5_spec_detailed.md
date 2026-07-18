# Oura Ring 5 Detailed Implementation Spec

## Overview
This spec drives the autonomous implementation of the Oura Ring 5 integration for AnxietyWatchKit. It focuses on Phase 1 & 2 (Cloud API Data Parity and New Capabilities), avoiding BLE reverse engineering which is reserved for Phase 3.

## Components to Implement

### 1. `OuraModels.swift`
Provides `Codable` structs matching the Oura V2 Cloud API schema.
- `OuraIBIResponse` -> contains `data: [OuraIBIData]`, where `OuraIBIData` has `timestamp`, `ibi` (millisecond interval), and `validity`.
- `OuraSleepResponse` -> contains `data: [OuraSleepData]`, focusing on `day`, `average_hrv`, `average_heart_rate`, `time_in_bed`, `sleep_score`.
- `OuraReadinessResponse` -> contains `data: [OuraReadinessData]`, focusing on `temperature_deviation`, `score`.
- `OuraStressResponse` -> contains `data: [OuraStressData]`, focusing on `day`, `stress_high`, `recovery_high`.

### 2. `OuraAPIClient.swift`
An `actor` responsible for performing REST calls.
- **State**: `accessToken: String?`, `session: URLSession`
- **Endpoints**:
  - `fetchIBI(startDate:endDate:) async throws -> [OuraIBIData]`
  - `fetchSleep(startDate:endDate:) async throws -> [OuraSleepData]`
  - `fetchReadiness(startDate:endDate:) async throws -> [OuraReadinessData]`
  - `fetchStress(startDate:endDate:) async throws -> [OuraStressData]`
- **Error Handling**: Throws mapped errors for 401 Unauthorized, 429 Rate Limited (capturing Oura's `X-RateLimit-Tier`), etc.

### 3. `OuraHealthKitAdapter.swift`
An `actor` for secondary local fallback. Reads Apple Health types written by Oura.
- `HKCategoryTypeIdentifierSleepAnalysis`
- `HKQuantityTypeIdentifierOxygenSaturation`
- Only extracts records with a `sourceRevision.source.name` containing "Oura".

### 4. `OuraIntegrationTests.swift`
Ensures all JSON parsing and API endpoint formations are correct using mock `URLSession` or protocol stubs.

## Execution
This will be implemented and tested in the current context.
