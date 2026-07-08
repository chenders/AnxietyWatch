# Query Prod

Run a read-only SQL query against the production AnxietyWatch sync database on megadude. Wraps the safe execution path that bypasses the `.env` permission issue and uses the correct docker-compose project name.

## Arguments

- `$ARGUMENTS` — the SQL query to run. Wrap multi-line queries in single quotes.

## Why this command exists

Prior incident: `docker compose -p server` was used by mistake instead of `-p anxietywatch`, which silently pointed at a different (empty) database. The compose project name is derived from the deployment directory at `/opt/anxietywatch`, not from the `server/` subdirectory inside it.

Separately, the prod `.env` file at `/opt/anxietywatch/.env` is owned by `deploy:root 0600`. The maintainer's account doesn't have read access, so `docker compose` CLI commands fail with "open .env: permission denied" before they can connect. The fix is to skip compose entirely and use `docker exec` directly against the already-running database container, which has the env vars loaded in memory.

## Instructions

### 1. Sanity-check the query

Before running, confirm the query is **read-only**. Block (do not execute) any query that contains, outside of string literals:

- `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `DROP`, `ALTER`, `CREATE`, `GRANT`, `REVOKE`
- `\copy`, `COPY … TO`, or anything that writes to the filesystem
- A bare `SELECT *` without a `LIMIT` clause on tables known to be unbounded: `medication_doses`, `barometric_readings`, `hrv_readings`, `cpap_sessions`, `health_snapshots`, `polar_rr_intervals`

If any of the above is detected, refuse and ask the user to either confirm intent explicitly or add a `LIMIT`. Never execute a destructive query without an explicit "yes, run it" from the user in the conversation.

### 2. Run the query

Use this exact form — do not vary it:

```bash
ssh megadude "docker exec anxietywatch-db psql -U anxietywatch -d anxietywatch -c \"$ARGUMENTS\""
```

Notes:

- The container name `anxietywatch-db` is fixed by the compose project name. If `docker ps` on megadude shows a different name, the deployment has drifted — stop and surface that.
- `psql -c` runs a single statement and exits. For multi-statement reads, use `psql -1 -c '… ; …'` (transactional) or break into multiple `/query-prod` calls.
- Output goes to stdout; capture and present as a table.

### 3. Helpful patterns

Top-of-mind aggregates the maintainer often wants:

- **Days exceeding a daily medication ceiling:**
  ```sql
  SELECT (timestamp AT TIME ZONE 'America/Los_Angeles')::date AS day,
         ROUND(SUM(dose_mg)::numeric, 2) AS total_mg,
         COUNT(*) AS doses
  FROM medication_doses
  WHERE medication_name ILIKE 'clonazepam%'
  GROUP BY day HAVING SUM(dose_mg) > 3.0
  ORDER BY day;
  ```
  Note the `ILIKE 'clonazepam%'` to capture both `Clonazepam 1mg Tablets` and `clonazePAM` (a documented name-drift artifact that has not been migrated).

- **Most recent sync activity per table:**
  ```sql
  SELECT 'medication_doses' AS tbl, MAX(timestamp) AS last_ts FROM medication_doses
  UNION ALL SELECT 'cpap_sessions', MAX(date)::timestamptz FROM cpap_sessions
  UNION ALL SELECT 'hrv_readings', MAX(timestamp) FROM hrv_readings
  ORDER BY last_ts DESC NULLS LAST;
  ```

- **Bucketing by Pacific time, not UTC** — always wrap timestamps with `AT TIME ZONE 'America/Los_Angeles'` before `::date` when reporting on calendar days. Per project memory, the maintainer is always in Pacific.

### 4. Output

Present the query result table. If the result is empty, say "0 rows" explicitly — don't elide. If a column contains free-text user data (notes, journal text), summarize length rather than echoing the raw value into the conversation, since this is a public-repo session and verbatim journal text shouldn't surface.

## Limits

- This command is for **ad-hoc reads only**. For repeated structured queries (e.g., automated reports), promote the query to a server-side admin endpoint instead.
- If a query takes longer than 30 seconds, kill it and ask the user to add a tighter `WHERE` clause.
- Do not run this command from CI or any unattended context — it requires a live SSH session and the docker container being up.
