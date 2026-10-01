#!/usr/bin/env python3
"""Deterministic, spike-only R/G normalization and P0–P4 oracle check."""

from __future__ import annotations

import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys


HERE = Path(__file__).resolve().parent
OUTPUTS = {"I01", "I02"}
SOURCES = {"profile.renderable", "profile.displayName", "profile.createdAt"}
SOURCE_TYPES = {"profile.renderable": "Bool", "profile.displayName": "String?", "profile.createdAt": "Instant?"}


def read(name: str) -> dict:
    return json.loads((HERE / name).read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def normalize_relation(doc: dict) -> dict:
    require(doc.get("schema") == "spike-typed-relation-v1", "R schema")
    require(set(doc) == {"schema", "semanticSources", "relations"}, "R top-level fields")
    require(doc["semanticSources"] == SOURCE_TYPES, "R semantic source types")
    rules = {rule["output"]: rule for rule in doc["relations"]}
    require(len(doc["relations"]) == len(rules) == 2 and set(rules) == OUTPUTS, "R output set")
    normalized = {}
    for output, rule in rules.items():
        require(set(rule) == {"output", "source", "visibleWhen", "whenNil", "transform"}, f"R {output} fields")
        require(rule["source"] in SOURCES, f"R {output} value source")
        require(set(rule["visibleWhen"]) == {"source", "equals"}, f"R {output} predicate")
        require(rule["visibleWhen"]["source"] in SOURCES, f"R {output} visibility source")
        require(type(rule["visibleWhen"]["equals"]) is bool, f"R {output} predicate type")
        normalized[output] = {
            "valueSource": rule["source"],
            "visibilitySource": rule["visibleWhen"]["source"],
            "visibilityEquals": rule["visibleWhen"]["equals"],
            "whenNil": rule["whenNil"],
            "transform": rule["transform"],
        }
    return normalized


def normalize_graph(doc: dict) -> dict:
    require(doc.get("schema") == "spike-annotated-graph-v1", "G schema")
    require(set(doc) == {"schema", "nodes", "edges"}, "G top-level fields")
    nodes = {node["id"]: node for node in doc["nodes"]}
    require(len(nodes) == len(doc["nodes"]) == 5, "G unique nodes")
    require({key for key, node in nodes.items() if node["kind"] == "semanticSource"} == SOURCES, "G sources")
    require({key for key, node in nodes.items() if node["kind"] == "output"} == OUTPUTS, "G outputs")
    require(all(set(node) == {"id", "kind", "type"} for node in nodes.values()), "G node fields")
    require({key: node["type"] for key, node in nodes.items() if key in SOURCES} == SOURCE_TYPES, "G source types")
    require(all(nodes[output]["type"] == "String" for output in OUTPUTS), "G output types")
    require(len(doc["edges"]) == 4, "G edge count")
    grouped = {output: {} for output in sorted(OUTPUTS)}
    for edge in doc["edges"]:
        require(edge["from"] in SOURCES and edge["to"] in OUTPUTS, "G edge endpoints")
        require(edge["role"] in {"visibility", "value"}, "G edge role")
        require(edge["role"] not in grouped[edge["to"]], "G duplicate role")
        grouped[edge["to"]][edge["role"]] = edge
    normalized = {}
    for output, edges in grouped.items():
        require(set(edges) == {"visibility", "value"}, f"G {output} roles")
        visible, value = edges["visibility"], edges["value"]
        require(set(visible) == {"from", "to", "role", "equals"}, f"G {output} visibility fields")
        require(type(visible["equals"]) is bool, f"G {output} visibility type")
        require(set(value) == {"from", "to", "role", "whenNil", "transform"}, f"G {output} value fields")
        normalized[output] = {
            "valueSource": value["from"],
            "visibilitySource": visible["from"],
            "visibilityEquals": visible["equals"],
            "whenNil": value["whenNil"],
            "transform": value["transform"],
        }
    return normalized


def transform(value: object, name: str, registry: dict) -> str:
    require(name in registry["transforms"], f"unknown transform {name}")
    if name == "identity":
        require(isinstance(value, str), "identity type")
        return value
    require(name == "membershipDate-ko-utc-v1", "unhandled transform")
    spec = registry["transforms"][name]
    require(spec["calendar"] == "gregorian" and spec["timezone"] == "UTC", "date transform spec")
    require(isinstance(value, str), "date type")
    date = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    return f"{date.year}년 {date.month}월 {date.day}일 가입"


def validate_oracle(oracle: dict) -> None:
    require(oracle.get("schema") == "spike-oracle-v1", "oracle schema")
    cases = oracle["cases"]
    require(len(cases) == 5 and {case["id"] for case in cases} == {"P0", "P1", "P2", "P3", "P4"},
            "oracle must cover five unique states")
    by_id = {case["id"]: case for case in cases}
    for case in cases:
        require(set(case["sources"]) == SOURCES, f"{case['id']} sources")
        require(type(case["sources"]["profile.renderable"]) is bool, f"{case['id']} renderable type")
        require(case["sources"]["profile.displayName"] is None or isinstance(case["sources"]["profile.displayName"], str),
                f"{case['id']} name type")
        require(case["sources"]["profile.createdAt"] is None or isinstance(case["sources"]["profile.createdAt"], str),
                f"{case['id']} date type")
        require(set(case["expected"]) == OUTPUTS, f"{case['id']} expected outputs")
        for output, expected in case["expected"].items():
            require(set(expected) == {"visible", "value"} and type(expected["visible"]) is bool,
                    f"{case['id']} {output} expectation shape")
            require((expected["visible"] and isinstance(expected["value"], str)) or
                    (not expected["visible"] and expected["value"] is None),
                    f"{case['id']} {output} expectation value")
    require(by_id["P0"]["sources"]["profile.renderable"] is False, "P0 must have no renderable profile")
    require(all(by_id[name]["sources"]["profile.renderable"] is True for name in ("P1", "P2", "P3", "P4")),
            "P1–P4 must have renderable profiles")
    require(by_id["P1"]["sources"] == by_id["P2"]["sources"], "P1/P2 must preserve cached values")
    require(by_id["P3"]["sources"]["profile.createdAt"] is None and
            by_id["P4"]["sources"]["profile.createdAt"] is not None, "P3/P4 date distinction")


def valid_mapping_sources(mappings: dict) -> set[str]:
    require(mappings.get("schema") == "spike-repository-mapping-v1", "mapping schema")
    require(mappings.get("mappingStatus") == "proposed integration mapping, not existing production state",
            "mapping must be labeled proposed")
    entries = mappings.get("semanticSources", {})
    valid = set()
    for source, entry in entries.items():
        if (source in SOURCES and isinstance(entry, dict) and
                set(entry) == {"plan", "evidence", "requiresImplementation"} and
                isinstance(entry["plan"], str) and entry["plan"].strip() and
                isinstance(entry["evidence"], str) and entry["evidence"].strip() and
                type(entry["requiresImplementation"]) is bool):
            valid.add(source)
    return valid


def render(rules: dict, values: dict, mappings: dict, registry: dict) -> dict:
    needed = {rule[key] for rule in rules.values() for key in ("visibilitySource", "valueSource")}
    missing = sorted(needed - valid_mapping_sources(mappings))
    if missing:
        return {output: {"status": "needsResolution", "missingMappings": missing} for output in sorted(OUTPUTS)}
    result = {}
    for output in sorted(OUTPUTS):
        rule = rules[output]
        missing_values = sorted({rule["visibilitySource"], rule["valueSource"]} - set(values))
        if missing_values:
            result[output] = {"status": "needsResolution", "missingSources": missing_values}
            continue
        if values[rule["visibilitySource"]] != rule["visibilityEquals"]:
            result[output] = {"status": "sufficient", "visible": False, "value": None}
            continue
        value = values[rule["valueSource"]]
        if value is None:
            nil_rule = rule["whenNil"]
            if nil_rule["kind"] == "needsResolution":
                result[output] = {"status": "needsResolution", "reason": "nil value"}
                continue
            require(nil_rule["kind"] == "literal" and isinstance(nil_rule["value"], str), "nil behavior")
            rendered = nil_rule["value"]
        else:
            rendered = transform(value, rule["transform"], registry)
        result[output] = {"status": "sufficient", "visible": True, "value": rendered}
    return result


def evaluate(label: str, doc: dict, rules: dict, oracle: dict, mappings: dict, registry: dict) -> dict:
    rows = []
    for case in oracle["cases"]:
        actual = render(rules, case["sources"], mappings, registry)
        for output in sorted(OUTPUTS):
            expected = case["expected"][output]
            got = actual[output]
            rows.append({"case": case["id"], "output": output, "classification": got["status"],
                         "actual": got, "expected": expected,
                         "matchesOracle": got.get("status") == "sufficient" and
                         got.get("visible") == expected["visible"] and got.get("value") == expected["value"]})
    missing_mapping = copy.deepcopy(mappings)
    del missing_mapping["semanticSources"]["profile.renderable"]
    negative = [render(rules, case["sources"], missing_mapping, registry) for case in oracle["cases"]]
    require(all(all(entry["status"] == "needsResolution" for entry in row.values()) for row in negative),
            f"{label} missing mapping did not fail closed")
    empty_mapping = copy.deepcopy(mappings)
    empty_mapping["semanticSources"]["profile.renderable"] = {}
    invalid = [render(rules, case["sources"], empty_mapping, registry) for case in oracle["cases"]]
    require(all(all(entry["status"] == "needsResolution" for entry in row.values()) for row in invalid),
            f"{label} empty mapping did not fail closed")
    mutated = copy.deepcopy(rules)
    mutated["I02"]["whenNil"] = {"kind": "literal", "value": "WRONG"}
    p3 = next(case for case in oracle["cases"] if case["id"] == "P3")
    bad = render(mutated, p3["sources"], mappings, registry)["I02"]
    require(bad["value"] != p3["expected"]["I02"]["value"], f"{label} oracle missed bad fallback")
    encoded = json.dumps(doc, ensure_ascii=False)
    leakage = [needle for needle in ("ProfileMain", "Profile.nickname", "MVI", "TCA", "Profile.createdAt") if needle in encoded]
    dependency_sets = {output: sorted({rule["visibilitySource"], rule["valueSource"]}) for output, rule in rules.items()}
    return {"candidate": label, "rows": rows, "matchedCells": sum(row["matchesOracle"] for row in rows),
            "totalCells": len(rows), "missingRenderableMapping": "needsResolution in all 10 cells",
            "emptyRenderableMapping": "needsResolution in all 10 cells",
            "wrongFallbackDetected": True, "semanticPrimitives":
            ["typed semantic source", "output", "visibility predicate", "value source", "nil behavior", "transform"],
            "sharedEvaluationPolicy": ["missing Repository mapping -> Needs Resolution"],
            "sourceDependencies": dependency_sets, "sourceDependenciesDerivableWithoutUpdateTriggerField": True,
            "runtimeUpdatePropagationTested": False, "duplicatedVisibilityRules": 1,
            "boundedProductSymbolScanMatches": leakage, "mappingStatus": "proposed simulation, not production validation",
            "jsonBytesUtf8": len((HERE / ("relation-R.json" if label == "R" else "graph-G.json")).read_bytes()),
            "nodeCount": len(doc["nodes"]) if label == "G" else None,
            "edgeCount": len(doc["edges"]) if label == "G" else None,
            "relationCount": len(doc["relations"]) if label == "R" else None}


def main() -> None:
    oracle, mappings, registry = read("oracle.json"), read("repository-mapping.json"), read("transform-registry.json")
    validate_oracle(oracle)
    r, g = read("relation-R.json"), read("graph-G.json")
    duplicate_case = copy.deepcopy(oracle)
    duplicate_case["cases"][4] = copy.deepcopy(duplicate_case["cases"][3])
    invalid_r = copy.deepcopy(r)
    invalid_r["semanticSources"]["profile.createdAt"] = "Product.Profile.createdAt"
    invalid_g = copy.deepcopy(g)
    next(node for node in invalid_g["nodes"] if node["id"] == "I02")["type"] = "Product.String"
    for name, check, value in (("duplicate oracle case", validate_oracle, duplicate_case),
                                ("Product type in R", normalize_relation, invalid_r),
                                ("Product type in G", normalize_graph, invalid_g)):
        try:
            check(value)
        except ValueError:
            continue
        raise ValueError(f"guard failed to reject {name}")
    reports = [evaluate("R", r, normalize_relation(r), oracle, mappings, registry),
               evaluate("G", g, normalize_graph(g), oracle, mappings, registry)]
    require(all(report["matchedCells"] == 10 and not report["boundedProductSymbolScanMatches"] for report in reports),
            "candidate failed oracle or leaked Product architecture")
    print(json.dumps({"schema": "spike-evaluation-v1", "guardChecks":
                      ["duplicate P3 replacing P4 rejected", "Product type in R rejected", "Product type in G rejected"],
                      "reports": reports}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError) as error:
        print(f"EVALUATION_FAILED: {error}", file=sys.stderr)
        raise SystemExit(1)
