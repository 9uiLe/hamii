#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ADR_FIELDS = (
    "Context", "Decision to Make", "Constraints", "Options", "Current Hypothesis",
    "Unknowns", "Required Evidence", "Decision Criteria", "Status",
)
SPIKE_FIELDS = (
    "Related Decision", "Hypothesis", "Questions", "Prototype Scope", "Out of Scope",
    "Measurements", "Success Criteria", "Failure Criteria", "Result", "Conclusion", "Artifacts",
)
STATUSES = {"Open", "Researching", "Spike Required", "Ready for Decision", "Implementation Required"}
errors = []

for decision in sorted((ROOT / "adr").iterdir()):
    if not decision.is_dir():
        continue
    adr = decision / "ADR.md"
    if not adr.exists():
        errors.append(f"{decision}: missing ADR.md")
        continue
    text = adr.read_text()
    for field in ADR_FIELDS:
        if f"## {field}" not in text:
            errors.append(f"{adr}: missing {field}")
    status = text.split("## Status")[-1].strip().splitlines()[0] if "## Status" in text else ""
    if status not in STATUSES:
        errors.append(f"{adr}: invalid status {status!r}")
    if (decision / "SPIKE.md").exists():
        errors.append(f"{decision}: SPIKE.md must be under spikes/<name>/")
    for spike in sorted((decision / "spikes").glob("*/SPIKE.md")):
        body = spike.read_text()
        for field in SPIKE_FIELDS:
            if f"## {field}" not in body:
                errors.append(f"{spike}: missing {field}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("ADR queue valid")
