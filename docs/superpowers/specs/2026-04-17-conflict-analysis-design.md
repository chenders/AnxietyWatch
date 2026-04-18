# Patient Context & Conflict Analysis — Design Spec

## Goal

Give Claude rich context about the patient and their psychiatrist so analysis conclusions are grounded in the individual's clinical picture. When a patient-psychiatrist conflict is active, run an evidence-based research pipeline that assesses each side's position against current medical literature, producing a balanced synthesis with cited sources and confidence scores.

## Problem

The AI analysis currently knows nothing about the patient beyond their raw health data. It doesn't know their age, gender, medical history, or who their psychiatrist is. When the therapeutic relationship is strained — disagreements about medication changes, treatment approach, diagnosis — the analysis can't account for that stress or help the patient understand whether their concerns (or their psychiatrist's position) are supported by evidence.

## Architecture Overview

```
Admin UI (Flask templates)
    │
    ├── Patient Profile page ─────► patient_profile table
    │     └── "Refine with Claude" ─► Claude API (medical history structuring)
    │
    ├── Psychiatrist Profile page ─► psychiatrist_profile table
    │     └── "Research" button ────► Claude API + web search (credential lookup)
    │
    ├── Conflict list/detail pages ► conflicts table
    │
    └── Analysis trigger ───────────► analyses table
                                         │
                                    Job Dispatcher
                                         │
                        ┌────────────────┼────────────────┐
                        ▼                ▼                ▼
                  health_analysis   (if active conflict)  ...
                        │           ┌────┴────┐
                        ▼           ▼         ▼
                   [result]    patient_    psychiatrist_
                        │      validity    validity
                        │           │         │
                        │      patient_    psychiatrist_
                        │      criticism   criticism
                        │           │         │
                        │           └────┬────┘
                        │                ▼
                        │        conflict_synthesis
                        │                │
                        └───────┬────────┘
                                ▼
                        Analysis Detail Page
                        [Health] | [Conflict]
```

### Modules

- **`server/analysis.py`** — existing module, gains patient context in prompt and creates jobs via dispatcher
- **`server/conflict_analysis.py`** — new module for conflict research prompt builders and result parsers
- **`server/job_dispatcher.py`** — new module for job queue, dependency resolution, thread pool execution
- **`server/admin.py`** — new routes for patient profile, psychiatrist profile, conflicts

## Data Model

### `patient_profile` table (single row, enforced at application level)

```sql
CREATE TABLE IF NOT EXISTS patient_profile (
    id                          SERIAL PRIMARY KEY,
    name                        TEXT,
    date_of_birth               DATE,
    gender                      TEXT,
    medical_history_raw         TEXT,
    medical_history_structured  TEXT,
    other_medications           TEXT,
    profile_summary             TEXT,
    updated_at                  TIMESTAMPTZ DEFAULT NOW()
);
```

- `name`: user-entered preferred name, used in analysis reports for readability (e.g., "Chris's HRV trend..." instead of "The patient's HRV trend...")
- `date_of_birth`, `gender`: auto-populated from HealthKit via sync, editable on admin page
- `medical_history_raw`: user's free-form input
- `medical_history_structured`: Claude-refined structured version (after 1-2 refinement rounds)
- `other_medications`: free text for medications not tracked in the app (e.g., managed by other providers)
- `profile_summary`: Claude-synthesized prompt-ready text combining demographics + medications + history

### `psychiatrist_profile` table (single row, enforced at application level)

```sql
CREATE TABLE IF NOT EXISTS psychiatrist_profile (
    id                SERIAL PRIMARY KEY,
    name              TEXT NOT NULL,
    location          TEXT NOT NULL,
    research_result   JSONB,
    profile_summary   TEXT,
    researched_at     TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);
```

- `name`, `location`: user-provided inputs for Claude to research
- `research_result`: full JSON output from Claude's research (credentials, board certifications, specialty, publications, disciplinary history, treatment philosophy)
- `profile_summary`: editable prompt-ready summary — user can correct if Claude got something wrong

### `conflicts` table

```sql
CREATE TABLE IF NOT EXISTS conflicts (
    id                              SERIAL PRIMARY KEY,
    status                          TEXT NOT NULL DEFAULT 'active'
                                        CHECK (status IN ('active', 'resolved')),
    description                     TEXT NOT NULL,
    patient_perspective             TEXT,
    patient_assumptions             TEXT,
    patient_desired_resolution      TEXT,
    patient_wants_from_other        TEXT,
    psychiatrist_perspective        TEXT,
    psychiatrist_assumptions        TEXT,
    psychiatrist_desired_resolution TEXT,
    psychiatrist_wants_from_other   TEXT,
    additional_context              TEXT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at                     TIMESTAMPTZ,
    updated_at                      TIMESTAMPTZ DEFAULT NOW()
);
```

- `status`: `active` or `resolved`. Only one conflict should be `active` at a time.
- Patient-side fields: the patient's own perspective, stated in good faith
- Psychiatrist-side fields: the patient's best-faith effort at representing the psychiatrist's position
- `additional_context`: anything else relevant to understanding the conflict

### `analysis_jobs` table

```sql
CREATE TABLE IF NOT EXISTS analysis_jobs (
    id                SERIAL PRIMARY KEY,
    analysis_id       INTEGER NOT NULL REFERENCES analyses(id),
    conflict_id       INTEGER REFERENCES conflicts(id),
    job_type          TEXT NOT NULL
                          CHECK (job_type IN (
                              'health_analysis',
                              'patient_validity',
                              'psychiatrist_validity',
                              'patient_criticism',
                              'psychiatrist_criticism',
                              'conflict_synthesis'
                          )),
    depends_on        INTEGER[],
    status            TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'running', 'completed', 'failed')),
    request_payload   JSONB,
    response_payload  JSONB,
    result            JSONB,
    model             TEXT NOT NULL,
    tokens_in         INTEGER,
    tokens_out        INTEGER,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at        TIMESTAMPTZ,
    completed_at      TIMESTAMPTZ,
    error_message     TEXT
);
```

- `depends_on`: array of `analysis_jobs.id` values that must be `completed` before this job can run
- `job_type`: determines which prompt builder and result parser to use
- `result`: parsed/structured output (insights for health analysis, findings for research jobs, synthesis for the final step)
- The existing `analyses` table remains as the top-level container. Its `summary`, `trend_direction`, `insights` fields are populated from the `health_analysis` job's result.

### Existing table changes

**`analyses`**: No schema changes. The `request_payload` field continues to store the health analysis prompt. Conflict analysis results are read from `analysis_jobs` at render time.

## Job Dispatcher — `server/job_dispatcher.py`

### Job creation

When `start_analysis()` is called, it creates all jobs upfront:

1. **Always:** one `health_analysis` job (no dependencies)
2. **If active conflict exists:**
   - `patient_validity` — depends on health_analysis
   - `psychiatrist_validity` — depends on health_analysis
   - `patient_criticism` — depends on health_analysis
   - `psychiatrist_criticism` — depends on health_analysis
   - `conflict_synthesis` — depends on all four research jobs

### Dispatch loop

A background thread runs:

```python
def dispatch_analysis(analysis_id, database_url):
    pool = ThreadPoolExecutor(max_workers=2)
    while True:
        ready = find_ready_jobs(analysis_id)  # pending + all deps completed
        if not ready and no_running_jobs(analysis_id):
            break
        for job in ready:
            mark_running(job)
            pool.submit(execute_job, job, database_url)
        time.sleep(2)
    pool.shutdown(wait=True)
    finalize_analysis(analysis_id, database_url)
```

- `max_workers=2`: allows parallel execution of validity-A + validity-B (or criticism-A + criticism-B) without overwhelming the API
- The loop polls every 2 seconds for newly ready jobs
- When all jobs are done (or failed), `finalize_analysis` updates the parent `analyses` row

### Job execution

```python
def execute_job(job, database_url):
    try:
        # Read dependency results
        dep_results = load_dependency_results(job)

        # Build prompt using job-type-specific builder
        system, user_msg, tools = build_job_prompt(job, dep_results)

        # Call Claude API
        response = call_claude(system, user_msg, tools, model=job.model)

        # Parse result using job-type-specific parser
        result = parse_job_result(job.job_type, response)

        # Update job row
        mark_completed(job, result, response)
    except Exception as e:
        mark_failed(job, e)
        cascade_failures(job)  # fail dependent jobs
```

### Error handling

- If a job fails, all jobs that depend on it are marked `failed` with `error_message = "Dependency job {id} failed"`
- The `health_analysis` job failing marks the entire analysis as failed
- Conflict job failures are non-fatal to the main analysis — the Health Analysis tab still works; the Conflict Analysis tab shows which steps failed
- No automatic retries in v1 — the user can re-run the full analysis

### Model selection

- `health_analysis`: Opus (existing behavior)
- Research jobs (validity, criticism): Opus with web search tool
- `conflict_synthesis`: Opus (needs strong reasoning to weigh evidence)

## Admin UI

### Patient Profile — `/admin/patient-profile`

Single-page form with sections:

**Demographics section:**
- Name: text input (preferred name for reports — e.g., "Chris")
- Date of birth: date input (pre-populated from HealthKit sync if available)
- Gender: select dropdown (Male, Female, Non-binary, Other, Prefer not to say). Pre-populated from HealthKit if available.

**Current Medications section:**
- Read-only list of active medications from `medication_definitions` table (name, default dose, category)
- Text area: "Other medications not tracked in this app" — for medications managed by other providers
- Helper text: "List any medications you take that aren't tracked in AnxietyWatch (e.g., managed by your PCP or other specialists)"

**Medical History section:**
- Large text area for free-form medical history input
- "Refine with Claude" button triggers the refinement flow:
  1. User writes medical history, clicks button
  2. Server sends to Claude: "Parse this medical history. Structure it into relevant categories (diagnoses, surgeries, allergies, family history, etc.). List follow-up questions that would be clinically relevant for someone using an anxiety tracking app."
  3. Page updates to show: Claude's structured version + follow-up questions
  4. User answers questions in a response text area, clicks "Finalize"
  5. Server sends original + answers to Claude for final structured summary
  6. Both `medical_history_raw` and `medical_history_structured` are saved
- If the user skips refinement, the raw text is saved as-is and used directly in the prompt

**Profile Summary section:**
- "Generate Summary" button runs a Claude call that synthesizes demographics + active medications + other medications + structured medical history into a single `profile_summary` text
- The summary is shown in an editable text area so the user can tweak it
- This `profile_summary` is what gets injected into every analysis prompt

**Save button** at the bottom saves all fields.

### Psychiatrist Profile — `/admin/psychiatrist-profile`

**Input section:**
- Name: text input
- Location: text input (city/state or practice name)
- "Research" button kicks off a Claude call with web search:
  - Prompt: "Research this psychiatrist: {name}, located in/near {location}. Find their credentials, board certifications, medical school, specialty areas, treatment philosophy (if publicly stated), published research, and any public disciplinary records or malpractice history. Use reliable sources. Cite each finding."
  - Shows loading spinner while running
  - On completion, displays the structured results

**Research Results section** (shown after research completes):
- Formatted display of `research_result` JSON: credentials, specialty, publications, disciplinary history, etc.
- Each finding shows its source
- `researched_at` timestamp displayed

**Profile Summary section:**
- Auto-generated from research results
- Editable text area — user can correct inaccuracies
- This is what goes into the analysis prompt

**"Re-research" button** to re-run if the user updates name/location or wants fresh results.

### Conflicts — `/admin/conflicts`

**List page:**
- Active conflicts at top (should be at most one), resolved below
- Each row: short description (truncated), status badge, created date, link to detail
- "New Conflict" button

**Detail page — `/admin/conflicts/<id>`:**

Form layout:

**Conflict Description** (full width):
- Text area: "Describe the conflict as objectively and in as good-faith a manner as possible"

**Two-column layout — Patient's Side | Psychiatrist's Side:**

| Patient | Psychiatrist |
|---------|-------------|
| "Your perspective on the conflict" | "Your best understanding of their perspective" |
| "What assumptions are you making?" | "What assumptions do you think they're making?" |
| "How do you think this should be resolved?" | "How do you think they want to resolve it?" |
| "What do you want from your psychiatrist?" | "What do you think they want from you?" |

Each cell is a text area.

**Additional Context** (full width):
- Text area: "Anything else relevant to understanding this conflict"

**Actions:**
- Save button (saves all fields, sets `updated_at`)
- "Mark Resolved" button (sets `status = 'resolved'`, `resolved_at = NOW()`)
- For resolved conflicts: "Reopen" button (sets `status = 'active'`, clears `resolved_at`)

### Analysis Page Modifications

**Analysis trigger page:**
- When an active conflict exists, show an info banner: "Active conflict detected — conflict research & analysis will run automatically after the health analysis completes."

**Analysis detail page — `/admin/analysis/<id>`:**
- Add tab navigation: **Health Analysis** | **Conflict Analysis**
- Health Analysis tab: existing content, no changes
- Conflict Analysis tab (only shown if conflict jobs exist for this analysis):
  - Job status overview: list of all conflict jobs with status badges (pending/running/completed/failed)
  - **Evidence Supporting Patient's Position**: rendered findings from `patient_validity` job, with sources and confidence scores
  - **Evidence Supporting Psychiatrist's Position**: rendered findings from `psychiatrist_validity` job
  - **Criticisms of Patient's Position**: rendered findings from `patient_criticism` job
  - **Criticisms of Psychiatrist's Position**: rendered findings from `psychiatrist_criticism` job
  - **Synthesis**: the full conflict synthesis — summary, position assessments, areas of agreement, key disagreements, suggested paths forward, all with preserved sources
  - If any job failed: show error message for that section, other completed sections still display

## Prompt Design

### Patient Context in Health Analysis

`build_prompt()` gains a `patient_context: dict | None` parameter. When present, a `## Patient Context` section is added to the system prompt before Data Quality Notes:

```
## Patient Context

**Patient:** [name, if set] — [profile_summary from patient_profile]

**Psychiatrist:** [profile_summary from psychiatrist_profile]

**Active conflict with psychiatrist:** The patient and psychiatrist are currently in a
disagreement. Description: [short description from conflicts table]. Factor this into your
analysis — anxiety patterns during this period may be influenced by therapeutic relationship
stress. Detailed conflict analysis will be conducted separately.
```

If `patient_profile.name` is set, the analysis should use the patient's name throughout the response for readability (e.g., "Chris's HRV was elevated" rather than "The patient's HRV was elevated").

- Patient section is always included if `patient_profile.profile_summary` exists
- Psychiatrist section is always included if `psychiatrist_profile.profile_summary` exists
- Conflict note is only included when an active conflict exists
- If no profiles are configured, the section is omitted entirely (existing behavior)

### Conflict Research Job Prompts

All conflict research jobs share a common context block:

```
## Context

**Patient Profile:**
[patient profile_summary]

**Psychiatrist Profile:**
[psychiatrist profile_summary]

**Conflict Description:**
[conflict description]

**Patient's Position:**
- Perspective: [patient_perspective]
- Assumptions: [patient_assumptions]
- Desired resolution: [patient_desired_resolution]
- Wants from psychiatrist: [patient_wants_from_other]

**Psychiatrist's Position (as understood by patient):**
- Perspective: [psychiatrist_perspective]
- Assumptions: [psychiatrist_assumptions]
- Desired resolution: [psychiatrist_desired_resolution]
- Wants from patient: [psychiatrist_wants_from_other]

**Additional Context:**
[additional_context]

**Health Analysis Summary:**
[summary from the completed health_analysis job]
```

#### `patient_validity` prompt

System: "You are a medical research analyst. Your task is to assess the evidentiary basis for the patient's position in a conflict with their psychiatrist. Search for current accepted medical literature, clinical guidelines (APA, NICE, WHO), and treatment standards that support the patient's perspective, assumptions, and desired resolution. Use web search to find reliable sources. Cite every claim."

Output format: findings array (see below).

#### `psychiatrist_validity` prompt

System: "You are a medical research analyst. Your task is to assess the evidentiary basis for the psychiatrist's position in a conflict with their patient. Search for current accepted medical literature, clinical guidelines (APA, NICE, WHO), and treatment standards that support the psychiatrist's perspective, assumptions, and desired resolution. Use web search to find reliable sources. Cite every claim."

Output format: findings array (same structure as `patient_validity`).

#### `patient_criticism` prompt

System: "You are a medical research analyst. Your task is to find evidence that challenges or contradicts the patient's position. Search for current accepted medical literature, clinical guidelines, and research that would argue against the patient's perspective, assumptions, or proposed resolution. Be thorough and fair. Use web search to find reliable sources. Cite every claim."

#### `psychiatrist_criticism` prompt

System: "You are a medical research analyst. Your task is to find evidence that challenges or contradicts the psychiatrist's position. Search for current accepted medical literature, clinical guidelines, and research that would argue against the psychiatrist's perspective, assumptions, or proposed resolution. Be thorough and fair. Use web search to find reliable sources. Cite every claim."

Output format: findings array (same structure as `patient_criticism`).

#### `conflict_synthesis` prompt

System: "You are a clinical conflict analyst. You have received four evidence-based assessments of a patient-psychiatrist conflict — evidence supporting each side, and evidence challenging each side. Synthesize these into a balanced, actionable analysis. Preserve all source citations and confidence scores. Identify where the evidence clearly favors one side, where it's ambiguous, and where both parties may have valid but incomplete perspectives. Suggest evidence-based paths forward."

Receives: the common context block + all four research job results as structured input.

### Research Job Output Format

```json
{
  "findings": [
    {
      "claim": "What aspect of the position this finding addresses",
      "assessment": "What the evidence says",
      "sources": [
        {
          "title": "Study or guideline name",
          "url": "URL if available",
          "type": "peer_reviewed | clinical_guideline | meta_analysis | expert_consensus | other",
          "year": 2024
        }
      ],
      "confidence": 0.82,
      "confidence_explanation": "Why this confidence level — sample size, study quality, relevance"
    }
  ]
}
```

### Synthesis Output Format

```json
{
  "summary": "Narrative synthesis of the conflict in light of the evidence",
  "patient_position_assessment": {
    "supported_by_evidence": [
      {
        "finding": "Summary of supporting evidence",
        "sources": ["source citations"],
        "confidence": 0.8
      }
    ],
    "challenged_by_evidence": [
      {
        "finding": "Summary of challenging evidence",
        "sources": ["source citations"],
        "confidence": 0.75
      }
    ],
    "overall_strength": "strong | moderate | weak | mixed"
  },
  "psychiatrist_position_assessment": {
    "supported_by_evidence": [...],
    "challenged_by_evidence": [...],
    "overall_strength": "strong | moderate | weak | mixed"
  },
  "areas_of_agreement": [
    "Where both sides align, with evidence"
  ],
  "key_disagreements": [
    {
      "issue": "The core disagreement",
      "patient_view": "Patient's position",
      "psychiatrist_view": "Psychiatrist's position",
      "evidence_says": "What the research supports",
      "sources": [...]
    }
  ],
  "suggested_paths_forward": [
    {
      "approach": "Description of a path forward",
      "evidence_basis": "Why the evidence supports this approach",
      "sources": [...]
    }
  ],
  "confidence": 0.75,
  "confidence_explanation": "Overall confidence in this synthesis"
}
```

## iOS Changes

### HealthKit Demographics

`SyncService` reads two HealthKit properties on sync:
- `HKHealthStore().dateOfBirth()` — returns `Date?`
- `HKHealthStore().biologicalSex()` — returns `HKBiologicalSex` enum (.male, .female, .other, .notSet)

These require `HKObjectType.characteristicType(forIdentifier:)` authorization, which should be added to the existing authorization request in `HealthKitManager`.

The sync payload gains an optional `demographics` field:
```json
{
  "demographics": {
    "dateOfBirth": "1992-03-15",
    "biologicalSex": "male"
  }
}
```

### Server Sync Endpoint

When `demographics` is present in the sync payload, upsert into `patient_profile`:
- Only set `date_of_birth` and `gender` if the `patient_profile` row doesn't exist yet OR if those fields are currently NULL
- Never overwrite manually-entered values

## Implementation Phases

### Phase 1: Data Model + Profiles

- Schema: `patient_profile`, `psychiatrist_profile`, `conflicts`, `analysis_jobs` tables
- Admin pages: patient profile (with Claude-assisted medical history refinement), psychiatrist profile (with Claude web search research)
- iOS: sync HealthKit demographics (date of birth, biological sex)
- Server sync endpoint: accept demographics, upsert into patient_profile
- Prompt integration: add `## Patient Context` section to `build_prompt()`
- Tests: profile CRUD, Claude refinement mocking, prompt generation with context

### Phase 2: Conflict Tracking

- Admin pages: conflict list + detail/edit with two-column perspective layout
- Conflict lifecycle: create, edit, resolve, reopen
- Active conflict note injected into health analysis prompt
- Analysis trigger page: active conflict banner
- Tests: conflict CRUD, lifecycle transitions, prompt integration

### Phase 3: Job Queue + Conflict Research Pipeline

- Refactor `start_analysis` to create `analysis_jobs` rows (health_analysis always, conflict jobs when active)
- Job dispatcher: dependency resolution, thread pool (max_workers=2), dispatch loop
- Conflict research prompt builders in `conflict_analysis.py`
- Web search tool integration for research jobs
- Result parsers for research and synthesis output formats
- Error handling: cascading failures, non-fatal conflict job failures
- Back-populate `analyses` fields from `health_analysis` job result
- Tests: dispatcher, job execution, dependency ordering, failure cascading, prompt builders, result parsers

### Phase 4: Analysis UI

- Tabbed analysis detail page: Health Analysis | Conflict Analysis
- Conflict Analysis tab: job status overview, research findings with sources and confidence, synthesis display
- Handle partial results (some jobs completed, some failed)
- Tests: template rendering with various job states

## Testing

### Unit tests

- Profile CRUD (patient + psychiatrist)
- Conflict CRUD + lifecycle transitions
- Job dispatcher: dependency resolution, parallel execution, failure cascading
- Prompt builders: patient context injection, research job prompts, synthesis prompt
- Result parsers: research findings, synthesis output
- `build_prompt` with and without patient context / active conflict

### Integration tests

- Claude-assisted medical history refinement (mocked API)
- Psychiatrist research job (mocked API + web search)
- Full conflict analysis pipeline: create jobs → dispatch → execute → finalize (mocked API)
- Sync endpoint with demographics payload
- Analysis detail page rendering with conflict analysis tabs

### Existing tests

- All existing analysis tests continue to pass — `build_prompt` changes are additive (new optional parameter)
- All existing sync tests continue to pass — demographics is optional in payload
