---
applyTo: "server/**/*.py"
---

# Python / Server Code Review Instructions

These instructions apply when reviewing Python files in the `server/` directory. Cross-cutting project standards live in `.github/copilot-instructions.md`.

## Python Coding Conventions

- **Line length:** 120 characters max.
- **SQL:** Always parameterize user-supplied values (`%s` placeholders with psycopg2). Never interpolate user input into SQL strings (no f-strings, `%` formatting, or `.format()` with user data). If you need dynamic table or column names, only interpolate identifiers selected from a strict server-side allowlist, never directly from user input.
- **Auth:** API endpoints use Bearer token auth with SHA-256 hashed keys stored in PostgreSQL. Admin pages use session-based auth with `hmac.compare_digest` for password comparison.
- **Upserts:** All sync operations use `INSERT ... ON CONFLICT ... DO UPDATE` for idempotency.
- **Error responses:** Never leak internal error details (stack traces, DB connection strings) to API clients.

## Data Flow: iOS App → Server

The iOS app's `SyncService` POSTs JSON to the server's `/api/sync` endpoint. The JSON schema matches `DataExporter`'s output format — camelCase keys with ISO 8601 dates. The server upserts into PostgreSQL using natural keys (timestamp, date, or name). Both full and incremental syncs use the same upsert path.

## Patterns to actively look for in server reviews

These are the recurring categories from PR #130's review history. Check every server diff for them:

- **Unparameterized SQL** — any user-supplied value flowing into SQL must go through a `%s` placeholder. f-strings or `.format()` with user data is a SQL-injection risk.
- **Schema / migration drift** — when adding columns or constraints, the Alembic migration and `schema.sql` must produce identical DDL for fresh-init and upgrade paths. Specifically check `nullable=False` / `NOT NULL`, FK declarations, defaults.
- **Endpoint precedence bugs** — when an endpoint has multiple validation paths, run existence checks (`SELECT 1`) before payload-shape checks so unknown resources return 404 rather than 400 for empty bodies.
- **DoS-by-large-payload** — endpoints accepting binary blobs need both an upfront `request.content_length` check *and* a bounded chunked-stream read for clients that omit `Content-Length` (chunked-transfer can bypass content-length-only checks).
- **JSON shape drift** — if an iOS model stores a JSON column as `String?` (pre-encoded), the server endpoint should accept both pre-encoded strings (`json.loads` round-trip) and decoded dicts, and use `psycopg2.extras.Json(...)` to avoid double-encoding.
- **Logged credentials or PII** — any log call including a password, API key, token, security answer, username, or email address is a bug, even at DEBUG level. Log presence/length, not values.
- **FK / on-delete contract** — when adding foreign keys, verify the FK is asserted in tests (not just the column name) — a future migration that drops the FK while keeping the column should fail the test.

## Python Testing Conventions

- Use pytest. Run `cd server && python -m pytest tests/`.
- Server tests need a Postgres instance reachable via `DATABASE_URL`.
- When testing endpoints that branch on validation order (e.g., 404 before 400), seed prerequisite rows in the test so each path is isolated.

## Server-specific Don'ts

- Don't use an ORM — raw SQL with psycopg2 is intentional.
- Don't leak internal error details to API clients (stack traces, DB connection strings).
- Don't store secrets in code or commit `.env` files.
