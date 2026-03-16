"""Cross-reference scanning and validation for specgraph artifacts."""

from __future__ import annotations

import re

from .parser import extract_list_ids, extract_scalar_id, _ARTIFACT_ID_RE

# All list-type frontmatter fields that hold artifact cross-references.
# Includes both the canonical field (linked-artifacts) and type-specific
# fields used by individual artifact types (linked-research, linked-adrs, etc.).
_XREF_LIST_FIELDS = (
    "depends-on-artifacts",
    "linked-artifacts",
    "validates",
    "linked-research",
    "linked-adrs",
    "linked-epics",
    "linked-specs",
    "affected-artifacts",
    "linked-journeys",
    "linked-stories",
    "linked-personas",
)

# Known artifact type prefixes — body references are filtered to these
# to avoid false positives from CVE-2024, GPT-4, BSD-3, etc.
_KNOWN_ARTIFACT_PREFIXES = frozenset({
    "VISION", "EPIC", "SPEC", "SPIKE", "ADR", "JOURNEY",
    "PERSONA", "DESIGN", "RUNBOOK", "STORY", "BUG",
})


def scan_body(body_text: str, known_ids: set[str], self_id: str) -> set[str]:
    """Find artifact IDs mentioned in body text that are in the known graph."""
    found = set(_ARTIFACT_ID_RE.findall(body_text))
    return (found & known_ids) - {self_id}


def collect_frontmatter_ids(frontmatter: dict) -> set[str]:
    """Collect all artifact IDs referenced in frontmatter fields.

    Extracts from:
    - List fields: depends-on-artifacts, linked-artifacts, validates
    - addresses list: strips sub-path (e.g. JOURNEY-001.PP-03 -> JOURNEY-001)
    - Scalar fields: parent-epic, parent-vision, superseded-by

    Excludes: source-issue, evidence-pool
    """
    ids: set[str] = set()

    # List fields — extract artifact IDs from each item
    for key in _XREF_LIST_FIELDS:
        ids.update(extract_list_ids(frontmatter, key))

    # addresses — strip sub-path suffix, keep only the base artifact ID
    addresses = frontmatter.get("addresses", [])
    if isinstance(addresses, list):
        for item in addresses:
            if isinstance(item, str):
                # Strip sub-path like ".PP-03" — take only the first ARTIFACT_ID_RE match
                match = _ARTIFACT_ID_RE.match(item)
                if match:
                    ids.add(match.group(0))

    # Scalar fields
    for key in ("parent-epic", "parent-vision", "superseded-by"):
        val = extract_scalar_id(frontmatter, key)
        if val:
            ids.add(val)

    return ids


def check_reciprocal_edges(nodes: dict, edges: list[dict]) -> list[dict]:
    """Check that depends-on edges have a corresponding linked-artifacts entry.

    For each edge with type == "depends-on" from A to B:
    - If B is missing from nodes, flag as a gap.
    - If B's linked-artifacts does not contain A, flag as a gap.

    Returns a list of gap dicts with keys: from, to, edge_type, expected_field.
    """
    gaps: list[dict] = []

    for edge in edges:
        if edge.get("type") != "depends-on":
            continue

        from_id = edge["from"]
        to_id = edge["to"]

        node = nodes.get(to_id)
        if node is None:
            # Target node is missing from graph — flag as gap
            gaps.append({
                "from": from_id,
                "to": to_id,
                "edge_type": "depends-on",
                "expected_field": "linked-artifacts",
            })
            continue

        # Collect all artifact IDs from the target node's cross-ref fields.
        # Two expected node shapes: flat dict {field: value} from tests, or
        # {raw_fields: {field: value}} from parse_artifact() output via graph.py.
        raw = node.get("raw_fields", node) if "raw_fields" in node else node
        all_linked_ids: set[str] = set()
        for xref_field in _XREF_LIST_FIELDS:
            vals = raw.get(xref_field, [])
            if isinstance(vals, list):
                for v in vals:
                    all_linked_ids.update(
                        m for m in _ARTIFACT_ID_RE.findall(str(v))
                    )
            elif isinstance(vals, str) and vals:
                all_linked_ids.update(_ARTIFACT_ID_RE.findall(vals))

        if from_id not in all_linked_ids:
            gaps.append({
                "from": from_id,
                "to": to_id,
                "edge_type": "depends-on",
                "expected_field": "linked-artifacts",
            })

    return gaps


def compute_discrepancies(body_ids: set[str], frontmatter_ids: set[str]) -> dict:
    """Compute set differences between body-mentioned and frontmatter-declared IDs.

    Returns a dict with:
    - body_not_in_frontmatter: IDs found in body but not declared in frontmatter
    - frontmatter_not_in_body: IDs declared in frontmatter but not found in body
    """
    return {
        "body_not_in_frontmatter": body_ids - frontmatter_ids,
        "frontmatter_not_in_body": frontmatter_ids - body_ids,
    }


def compute_xref(artifacts: list[dict], edges: list[dict]) -> list[dict]:
    """Run full cross-reference pipeline over a list of artifact dicts.

    Each artifact dict must have: id, file, body, frontmatter.

    Returns a list of entries (one per artifact) that have at least one
    discrepancy. Each entry has:
    - artifact: str
    - file: str
    - body_not_in_frontmatter: list
    - frontmatter_not_in_body: list
    - missing_reciprocal: list of gap dicts
    """
    if not artifacts:
        return []

    # Build known_ids set and nodes dict for reciprocal check
    known_ids = {a["id"] for a in artifacts}
    nodes: dict = {}
    for a in artifacts:
        fm = a.get("frontmatter", {})
        nodes[a["id"]] = fm

    # Check reciprocal edges across all nodes
    reciprocal_gaps = check_reciprocal_edges(nodes, edges)
    # Group reciprocal gaps by the "to" node (the one missing the back-link)
    reciprocal_by_artifact: dict[str, list[dict]] = {}
    for gap in reciprocal_gaps:
        reciprocal_by_artifact.setdefault(gap["to"], []).append({
            "from": gap["from"],
            "edge_type": gap["edge_type"],
            "expected_field": gap["expected_field"],
        })

    results = []
    for artifact in artifacts:
        artifact_id = artifact["id"]
        body = artifact.get("body", "")
        frontmatter = artifact.get("frontmatter", {})

        # Scan for TYPE-NNN patterns in the body, filtering to known artifact
        # type prefixes to avoid false positives from CVE-2024, GPT-4, BSD-3, etc.
        body_ids = {
            ref for ref in _ARTIFACT_ID_RE.findall(body)
            if ref.split("-")[0] in _KNOWN_ARTIFACT_PREFIXES
        } - {artifact_id}
        fm_ids = collect_frontmatter_ids(frontmatter)
        discrepancies = compute_discrepancies(body_ids, fm_ids)
        missing_reciprocal = reciprocal_by_artifact.get(artifact_id, [])

        has_discrepancy = (
            discrepancies["body_not_in_frontmatter"]
            or discrepancies["frontmatter_not_in_body"]
            or missing_reciprocal
        )

        if has_discrepancy:
            results.append({
                "artifact": artifact_id,
                "file": artifact.get("file", ""),
                "body_not_in_frontmatter": sorted(discrepancies["body_not_in_frontmatter"]),
                "frontmatter_not_in_body": sorted(discrepancies["frontmatter_not_in_body"]),
                "missing_reciprocal": missing_reciprocal,
            })

    return results
