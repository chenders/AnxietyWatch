"""Job dispatcher — creates, schedules, and executes analysis jobs."""

import json
import logging
import os
import time
import threading
from concurrent.futures import ThreadPoolExecutor

import anthropic
import psycopg2
import psycopg2.extras

MODEL = "claude-opus-4-7"

logger = logging.getLogger(__name__)


def create_analysis_jobs(db, analysis_id):
    """Create analysis_jobs rows for a given analysis.

    Always creates a health_analysis job. If an active conflict exists,
    also creates 4 research jobs + 1 synthesis job with correct dependencies.
    """
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Check for active conflict
    cur.execute(
        "SELECT id FROM conflicts WHERE status = 'active' ORDER BY created_at DESC LIMIT 1"
    )
    conflict_row = cur.fetchone()
    conflict_id = conflict_row["id"] if conflict_row else None

    # 1. Health analysis job (no dependencies)
    cur.execute(
        "INSERT INTO analysis_jobs (analysis_id, job_type, depends_on, status, model) "
        "VALUES (%s, 'health_analysis', '{}', 'pending', %s) RETURNING id",
        (analysis_id, MODEL),
    )
    health_job_id = cur.fetchone()["id"]

    if conflict_id:
        # 2. Four research jobs — all depend on health_analysis
        research_job_ids = []
        for job_type in ["patient_validity", "psychiatrist_validity",
                         "patient_criticism", "psychiatrist_criticism"]:
            cur.execute(
                "INSERT INTO analysis_jobs "
                "(analysis_id, conflict_id, job_type, depends_on, status, model) "
                "VALUES (%s, %s, %s, %s, 'pending', %s) RETURNING id",
                (analysis_id, conflict_id, job_type, [health_job_id], MODEL),
            )
            research_job_ids.append(cur.fetchone()["id"])

        # 3. Synthesis job — depends on all 4 research jobs
        cur.execute(
            "INSERT INTO analysis_jobs "
            "(analysis_id, conflict_id, job_type, depends_on, status, model) "
            "VALUES (%s, %s, 'conflict_synthesis', %s, 'pending', %s)",
            (analysis_id, conflict_id, research_job_ids, MODEL),
        )

    db.commit()


def find_ready_jobs(db, analysis_id):
    """Find pending jobs whose dependencies are all completed."""
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Get all jobs for this analysis
    cur.execute(
        "SELECT * FROM analysis_jobs WHERE analysis_id = %s ORDER BY id",
        (analysis_id,),
    )
    all_jobs = cur.fetchall()

    # Build status lookup
    status_map = {j["id"]: j["status"] for j in all_jobs}

    ready = []
    for job in all_jobs:
        if job["status"] != "pending":
            continue
        deps = job["depends_on"] or []
        if all(status_map.get(dep_id) == "completed" for dep_id in deps):
            ready.append(job)

    return ready


def mark_running(db, job_id):
    """Mark a job as running."""
    cur = db.cursor()
    cur.execute(
        "UPDATE analysis_jobs SET status = 'running', started_at = NOW() WHERE id = %s",
        (job_id,),
    )
    db.commit()


def mark_completed(db, job_id, result, response_payload, tokens_in, tokens_out):
    """Mark a job as completed with its results."""
    cur = db.cursor()
    cur.execute(
        "UPDATE analysis_jobs SET status = 'completed', result = %s, "
        "response_payload = %s, tokens_in = %s, tokens_out = %s, "
        "completed_at = NOW() WHERE id = %s",
        (json.dumps(result), json.dumps(response_payload), tokens_in, tokens_out, job_id),
    )
    db.commit()


def mark_failed(db, job_id, error):
    """Mark a job as failed."""
    cur = db.cursor()
    cur.execute(
        "UPDATE analysis_jobs SET status = 'failed', error_message = %s, "
        "completed_at = NOW() WHERE id = %s",
        (str(error)[:2000], job_id),
    )
    db.commit()


def cascade_failures(db, failed_job_id):
    """Mark all jobs that depend on the failed job as failed, recursively."""
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Find jobs that directly depend on the failed job
    cur.execute(
        "SELECT id FROM analysis_jobs WHERE %s = ANY(depends_on) AND status = 'pending'",
        (failed_job_id,),
    )
    dependent_jobs = cur.fetchall()

    for dep_job in dependent_jobs:
        cur.execute(
            "UPDATE analysis_jobs SET status = 'failed', "
            "error_message = %s, completed_at = NOW() WHERE id = %s",
            (f"Dependency job {failed_job_id} failed", dep_job["id"]),
        )
        db.commit()
        # Recursively cascade
        cascade_failures(db, dep_job["id"])


def load_dependency_results(db, job):
    """Load result payloads from completed dependency jobs."""
    if not job.get("depends_on"):
        return {}
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    results = {}
    for dep_id in job["depends_on"]:
        cur.execute(
            "SELECT job_type, result FROM analysis_jobs WHERE id = %s",
            (dep_id,),
        )
        dep = cur.fetchone()
        if dep and dep["result"]:
            results[dep["job_type"]] = dep["result"]
    return results


def no_running_jobs(db, analysis_id):
    """Check if there are any running jobs for this analysis."""
    cur = db.cursor()
    cur.execute(
        "SELECT count(*) FROM analysis_jobs "
        "WHERE analysis_id = %s AND status = 'running'",
        (analysis_id,),
    )
    return cur.fetchone()[0] == 0


def finalize_analysis(db, analysis_id):
    """Update the parent analyses row from the health_analysis job result."""
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cur.execute(
        "SELECT status, result, response_payload, tokens_in, tokens_out "
        "FROM analysis_jobs WHERE analysis_id = %s AND job_type = 'health_analysis'",
        (analysis_id,),
    )
    health_job = cur.fetchone()

    if not health_job:
        return

    if health_job["status"] == "failed":
        cur.execute(
            "UPDATE analyses SET status = 'failed', error_message = 'Health analysis job failed', "
            "completed_at = NOW() WHERE id = %s",
            (analysis_id,),
        )
    elif health_job["status"] == "completed" and health_job["result"]:
        result = health_job["result"]
        cur.execute(
            "UPDATE analyses SET status = 'completed', "
            "response_payload = %s, summary = %s, trend_direction = %s, "
            "insights = %s, tokens_in = %s, tokens_out = %s, "
            "completed_at = NOW() WHERE id = %s",
            (
                json.dumps(health_job["response_payload"]),
                result.get("summary"),
                result.get("trend_direction"),
                json.dumps(result.get("insights", [])),
                health_job["tokens_in"],
                health_job["tokens_out"],
                analysis_id,
            ),
        )
    db.commit()


def dispatch_analysis(analysis_id, database_url):
    """Main dispatch loop — runs in a background thread.

    Polls for ready jobs every 2 seconds and submits them to a thread pool.
    Exits when all jobs are done or failed.
    """
    conn = psycopg2.connect(database_url)
    conn.autocommit = False
    pool = ThreadPoolExecutor(max_workers=2)

    try:
        while True:
            ready = find_ready_jobs(conn, analysis_id)
            if not ready and no_running_jobs(conn, analysis_id):
                break
            for job in ready:
                mark_running(conn, job["id"])
                pool.submit(_execute_single_job, job, database_url)
            time.sleep(2)
    except Exception:
        logger.exception("Dispatch loop failed for analysis %d", analysis_id)
    finally:
        pool.shutdown(wait=True)
        try:
            finalize_analysis(conn, analysis_id)
        except Exception:
            logger.exception("Failed to finalize analysis %d", analysis_id)
        conn.close()


def _execute_single_job(job, database_url):
    """Execute a single job in a worker thread. Opens its own DB connection."""
    conn = psycopg2.connect(database_url)
    conn.autocommit = False
    try:
        from conflict_analysis import build_job_prompt, parse_job_result
        from analysis import parse_response

        dep_results = load_dependency_results(conn, job)

        if job["job_type"] == "health_analysis":
            # Health analysis uses the request_payload stored on the analyses row
            cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
            cur.execute(
                "SELECT request_payload FROM analyses WHERE id = %s",
                (job["analysis_id"],),
            )
            analysis = cur.fetchone()
            payload = analysis["request_payload"]
            system_prompt = payload["system"]
            user_message = payload["messages"][0]["content"]

            client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
            message = client.messages.create(
                model=job["model"],
                max_tokens=16384,
                system=system_prompt,
                messages=[{"role": "user", "content": user_message}],
            )
            raw = message.model_dump()
            parsed = parse_response(raw)
            result = {
                "summary": parsed["summary"],
                "trend_direction": parsed["trend_direction"],
                "insights": parsed["insights"],
            }
            mark_completed(
                conn, job["id"], result, raw,
                parsed["tokens_in"], parsed["tokens_out"],
            )
        else:
            # Conflict analysis jobs
            system, user_msg, tools = build_job_prompt(conn, job, dep_results)

            client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
            kwargs = {
                "model": job["model"],
                "max_tokens": 8192,
                "system": system,
                "messages": [{"role": "user", "content": user_msg}],
            }
            if tools:
                kwargs["tools"] = tools
            message = client.messages.create(**kwargs)

            raw = message.model_dump()
            result = parse_job_result(job["job_type"], message)
            tokens_in = raw.get("usage", {}).get("input_tokens", 0)
            tokens_out = raw.get("usage", {}).get("output_tokens", 0)
            mark_completed(conn, job["id"], result, raw, tokens_in, tokens_out)

    except Exception as e:
        logger.exception("Job %d (%s) failed", job["id"], job["job_type"])
        mark_failed(conn, job["id"], e)
        cascade_failures(conn, job["id"])
    finally:
        conn.close()
