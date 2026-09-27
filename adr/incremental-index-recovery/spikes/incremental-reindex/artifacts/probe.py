#!/usr/bin/env python3
"""Concept probe for reverse-dependency invalidation and atomic SQLite generations.

This intentionally models a small dependency graph, not the HamiiIndex schema.
"""

import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import time


BASE = {
    "scope:app": "App",
    "scope:commerce": "Commerce",
    "scope:checkout": "Checkout",
    "token:spacing.base": "8",
    "token:spacing.card": "alias spacing.base",
    "component:button": "Button",
    "component:summary": "CheckoutSummary",
    "screen:checkout": "CheckoutScreen",
}
DEPS = {
    "scope:commerce": {"scope:app"},
    "scope:checkout": {"scope:commerce"},
    "token:spacing.card": {"token:spacing.base"},
    "component:button": {"scope:app"},
    "component:summary": {"scope:checkout", "token:spacing.card", "component:button"},
    "screen:checkout": {"component:summary"},
}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def source_id(entities, deps):
    return digest({"entities": entities, "dependencies": {key: sorted(value) for key, value in deps.items()}})


def full_rows(entities, deps):
    memo = {}

    def visit(entity, visiting):
        if entity in memo:
            return memo[entity]
        if entity in visiting:
            raise ValueError("dependency cycle")
        signature = digest([entity, entities[entity], [(dependency, visit(dependency, visiting | {entity})) for dependency in sorted(deps.get(entity, set()))]])
        memo[entity] = signature
        return signature

    for entity in entities:
        visit(entity, set())
    return memo


def affected(changed, deps):
    reverse = {}
    for consumer, sources in deps.items():
        for source in sources:
            reverse.setdefault(source, set()).add(consumer)
    pending = list(changed)
    found = set(changed)
    while pending:
        for consumer in reverse.get(pending.pop(), set()):
            if consumer not in found:
                found.add(consumer)
                pending.append(consumer)
    return found


def initialize(connection, entities, deps):
    connection.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE active(generation INTEGER NOT NULL);
        CREATE TABLE generations(generation INTEGER PRIMARY KEY, source_id TEXT NOT NULL);
        CREATE TABLE rows(generation INTEGER NOT NULL, entity TEXT NOT NULL, value TEXT NOT NULL,
                          PRIMARY KEY(generation, entity));
    """)
    connection.execute("INSERT INTO active VALUES (1)")
    connection.execute("INSERT INTO generations VALUES (1, ?)", (source_id(entities, deps),))
    connection.executemany("INSERT INTO rows VALUES (1, ?, ?)", full_rows(entities, deps).items())
    connection.commit()


def query(connection, expected_source):
    connection.execute("BEGIN")
    generation, observed = connection.execute("SELECT a.generation, g.source_id FROM active a JOIN generations g ON a.generation = g.generation").fetchone()
    rows = dict(connection.execute("SELECT entity, value FROM rows WHERE generation = ?", (generation,)))
    connection.commit()
    return {"status": "current", "generation": generation, "rows": rows} if observed == expected_source else {"status": "stale"}


def stage(writer, entities, deps, changed, next_generation):
    previous = writer.execute("SELECT generation FROM active").fetchone()[0]
    invalid = affected(changed, deps)
    oracle = full_rows(entities, deps)
    writer.execute("BEGIN IMMEDIATE")
    writer.execute("INSERT INTO generations VALUES (?, ?)", (next_generation, source_id(entities, deps)))
    writer.execute("INSERT INTO rows SELECT ?, entity, value FROM rows WHERE generation = ?", (next_generation, previous))
    writer.executemany("INSERT OR REPLACE INTO rows VALUES (?, ?, ?)", [(next_generation, entity, oracle[entity]) for entity in sorted(invalid)])
    writer.execute("UPDATE active SET generation = ?", (next_generation,))
    return invalid, oracle


def probe():
    with tempfile.TemporaryDirectory(prefix="hamii-generation-probe-") as directory:
        database = str(Path(directory) / "index.sqlite")
        writer = sqlite3.connect(database, isolation_level=None, timeout=5)
        reader = sqlite3.connect(database, isolation_level=None, timeout=5)
        initialize(writer, BASE, DEPS)
        assert query(reader, source_id(BASE, DEPS))["status"] == "current"
        rows = []
        for generation, change, payload in [
            (2, "token:spacing.base", "12"),
            (3, "component:button", "PrimaryButton"),
            (4, "scope:commerce", "CommercePromoted"),
        ]:
            updated = dict(BASE)
            if rows:
                for row in rows:
                    updated[row["changed"]] = row["newPayload"]
            updated[change] = payload
            before = time.perf_counter()
            invalid, oracle = stage(writer, updated, DEPS, {change}, generation)
            stage_ms = round((time.perf_counter() - before) * 1000, 3)
            before_publish = query(reader, source_id(updated, DEPS))
            assert before_publish == {"status": "stale"}
            writer.commit()
            after_publish = query(reader, source_id(updated, DEPS))
            assert after_publish["status"] == "current" and after_publish["rows"] == oracle
            rows.append({"changed": change, "newPayload": payload, "affected": sorted(invalid),
                         "stageMs": stage_ms, "beforeCommit": before_publish["status"],
                         "afterCommit": after_publish["status"], "matchesFullRebuildOracle": True})

        failed = dict(updated)
        failed["token:spacing.base"] = "16"
        stage(writer, failed, DEPS, {"token:spacing.base"}, 5)
        writer.rollback()
        rollback_query = query(reader, source_id(failed, DEPS))
        assert rollback_query == {"status": "stale"}
        writer.close()
        reader.close()
        return {"model": "synthetic dependency digest index, SQLite WAL", "rows": rows,
                "rollbackQuery": rollback_query["status"],
                "scope": "feasibility only; not actual HamiiIndex rows, Canonical parser, concurrent Git, large project or production latency"}


if __name__ == "__main__":
    result = probe()
    Path(__file__).with_name("result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
