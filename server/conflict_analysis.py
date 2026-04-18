"""Conflict analysis — prompt builders and result parsers for conflict research jobs."""

import json
import logging

import psycopg2.extras

logger = logging.getLogger(__name__)

# System prompts for each job type
SYSTEM_PROMPTS = {
    "patient_validity": (
        "You are a medical research analyst. Your task is to assess the evidentiary basis "
        "for the patient's position in a conflict with their psychiatrist. Search for current "
        "accepted medical literature, clinical guidelines (APA, NICE, WHO), and treatment "
        "standards that support the patient's perspective, assumptions, and desired resolution. "
        "Use web search to find reliable sources. Cite every claim."
    ),
    "psychiatrist_validity": (
        "You are a medical research analyst. Your task is to assess the evidentiary basis "
        "for the psychiatrist's position in a conflict with their patient. Search for current "
        "accepted medical literature, clinical guidelines (APA, NICE, WHO), and treatment "
        "standards that support the psychiatrist's perspective, assumptions, and desired resolution. "
        "Use web search to find reliable sources. Cite every claim."
    ),
    "patient_criticism": (
        "You are a medical research analyst. Your task is to find evidence that challenges "
        "or contradicts the patient's position. Search for current accepted medical literature, "
        "clinical guidelines, and research that would argue against the patient's perspective, "
        "assumptions, or proposed resolution. Be thorough and fair. Use web search to find "
        "reliable sources. Cite every claim."
    ),
    "psychiatrist_criticism": (
        "You are a medical research analyst. Your task is to find evidence that challenges "
        "or contradicts the psychiatrist's position. Search for current accepted medical "
        "literature, clinical guidelines, and research that would argue against the "
        "psychiatrist's perspective, assumptions, or proposed resolution. Be thorough and "
        "fair. Use web search to find reliable sources. Cite every claim."
    ),
    "conflict_synthesis": (
        "You are a clinical conflict analyst. You have received four evidence-based "
        "assessments of a patient-psychiatrist conflict — evidence supporting each side, "
        "and evidence challenging each side. Synthesize these into a balanced, actionable "
        "analysis. Preserve all source citations and confidence scores. Identify where the "
        "evidence clearly favors one side, where it's ambiguous, and where both parties may "
        "have valid but incomplete perspectives. Suggest evidence-based paths forward."
    ),
}

RESEARCH_OUTPUT_INSTRUCTIONS = """
Return your findings as a JSON object with this structure:
{
  "findings": [
    {
      "claim": "What aspect of the position this finding addresses",
      "assessment": "What the evidence says",
      "sources": [
        {"title": "Study or guideline name", "url": "URL if available",
         "type": "peer_reviewed | clinical_guideline | meta_analysis | expert_consensus | other",
         "year": 2024}
      ],
      "confidence": 0.82,
      "confidence_explanation": "Why this confidence level"
    }
  ]
}
"""

SYNTHESIS_OUTPUT_INSTRUCTIONS = """
Return your synthesis as a JSON object with this structure:
{
  "summary": "Narrative synthesis of the conflict in light of the evidence",
  "patient_position_assessment": {
    "supported_by_evidence": [{"finding": "...", "sources": ["..."], "confidence": 0.8}],
    "challenged_by_evidence": [{"finding": "...", "sources": ["..."], "confidence": 0.75}],
    "overall_strength": "strong | moderate | weak | mixed"
  },
  "psychiatrist_position_assessment": {
    "supported_by_evidence": [...],
    "challenged_by_evidence": [...],
    "overall_strength": "strong | moderate | weak | mixed"
  },
  "areas_of_agreement": ["Where both sides align"],
  "key_disagreements": [
    {"issue": "...", "patient_view": "...", "psychiatrist_view": "...",
     "evidence_says": "...", "sources": [...]}
  ],
  "suggested_paths_forward": [
    {"approach": "...", "evidence_basis": "...", "sources": [...]}
  ],
  "confidence": 0.75,
  "confidence_explanation": "Overall confidence in this synthesis"
}
"""


def _build_context_block(db, conflict_id, health_summary=None):
    """Build the shared context block used by all conflict research prompts."""
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Patient profile
    cur.execute("SELECT profile_summary FROM patient_profile LIMIT 1")
    patient = cur.fetchone()
    patient_summary = patient["profile_summary"] if patient else "Not provided"

    # Psychiatrist profile
    cur.execute("SELECT profile_summary FROM psychiatrist_profile LIMIT 1")
    psych = cur.fetchone()
    psych_summary = psych["profile_summary"] if psych else "Not provided"

    # Conflict details
    cur.execute("SELECT * FROM conflicts WHERE id = %s", (conflict_id,))
    c = cur.fetchone()

    parts = [
        f"## Context\n",
        f"**Patient Profile:**\n{patient_summary}\n",
        f"**Psychiatrist Profile:**\n{psych_summary}\n",
        f"**Conflict Description:**\n{c['description']}\n",
        f"**Patient's Position:**",
        f"- Perspective: {c.get('patient_perspective') or 'Not provided'}",
        f"- Assumptions: {c.get('patient_assumptions') or 'Not provided'}",
        f"- Desired resolution: {c.get('patient_desired_resolution') or 'Not provided'}",
        f"- Wants from psychiatrist: {c.get('patient_wants_from_other') or 'Not provided'}\n",
        f"**Psychiatrist's Position (as understood by patient):**",
        f"- Perspective: {c.get('psychiatrist_perspective') or 'Not provided'}",
        f"- Assumptions: {c.get('psychiatrist_assumptions') or 'Not provided'}",
        f"- Desired resolution: {c.get('psychiatrist_desired_resolution') or 'Not provided'}",
        f"- Wants from patient: {c.get('psychiatrist_wants_from_other') or 'Not provided'}",
    ]

    if c.get("additional_context"):
        parts.append(f"\n**Additional Context:**\n{c['additional_context']}")

    if health_summary:
        parts.append(f"\n**Health Analysis Summary:**\n{health_summary}")

    return "\n".join(parts)


def build_job_prompt(db, job, dep_results):
    """Build system prompt, user message, and tools for a conflict analysis job.

    Returns (system_prompt, user_message, tools_or_none).
    """
    job_type = job["job_type"]
    system = SYSTEM_PROMPTS[job_type]

    health_summary = None
    health_result = dep_results.get("health_analysis")
    if health_result:
        health_summary = health_result.get("summary", "")

    if job_type == "conflict_synthesis":
        # Synthesis receives all 4 research results as structured input
        context = _build_context_block(db, job["conflict_id"], health_summary)

        research_sections = []
        for rt, label in [
            ("patient_validity", "Evidence Supporting Patient's Position"),
            ("psychiatrist_validity", "Evidence Supporting Psychiatrist's Position"),
            ("patient_criticism", "Criticisms of Patient's Position"),
            ("psychiatrist_criticism", "Criticisms of Psychiatrist's Position"),
        ]:
            result = dep_results.get(rt, {})
            research_sections.append(
                f"## {label}\n```json\n{json.dumps(result, indent=2)}\n```"
            )

        user_msg = context + "\n\n" + "\n\n".join(research_sections)
        user_msg += "\n\n" + SYNTHESIS_OUTPUT_INSTRUCTIONS

        return system, user_msg, None  # no tools for synthesis

    else:
        # Research jobs (validity/criticism) — use web search
        context = _build_context_block(db, job["conflict_id"], health_summary)
        user_msg = context + "\n\n" + RESEARCH_OUTPUT_INSTRUCTIONS

        tools = [{"type": "web_search_20250305"}]
        return system, user_msg, tools


def parse_job_result(job_type, message):
    """Parse a Claude API response into structured result for a conflict job.

    Extracts JSON from the response text, handling markdown code fences.
    """
    # Collect text blocks from the response
    text_parts = []
    for block in message.content:
        if hasattr(block, "text") and getattr(block, "type", None) == "text":
            text_parts.append(block.text)

    full_text = "\n".join(text_parts).strip()

    # Try to extract JSON
    try:
        # Strip markdown code fences
        clean = full_text
        if "```json" in clean:
            clean = clean.split("```json", 1)[1]
            clean = clean.rsplit("```", 1)[0]
        elif "```" in clean:
            clean = clean.split("```", 1)[1]
            clean = clean.rsplit("```", 1)[0]
        result = json.loads(clean.strip())
    except (json.JSONDecodeError, IndexError):
        # Fallback: wrap raw text
        logger.warning("Failed to parse JSON from %s job response, using raw text", job_type)
        if job_type == "conflict_synthesis":
            result = {"summary": full_text, "raw": True}
        else:
            result = {"findings": [{"claim": "Raw response", "assessment": full_text,
                                    "sources": [], "confidence": 0.5,
                                    "confidence_explanation": "Could not parse structured response"}]}

    return result
