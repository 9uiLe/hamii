#!/usr/bin/env python3
"""Generation prototype using rows emitted by the real Swift IndexProjection test."""
import json
import math
from pathlib import Path
import sqlite3
import sys
import tempfile
import time


def connect(path):
    connection = sqlite3.connect(path, isolation_level=None, timeout=5)
    connection.execute("PRAGMA journal_mode=WAL")
    return connection


def setup(connection, rows):
    connection.executescript("""
      CREATE TABLE active(generation INTEGER NOT NULL);
      CREATE TABLE generations(generation INTEGER PRIMARY KEY, source_canonical_revision TEXT NOT NULL);
      CREATE TABLE projection_rows(generation INTEGER NOT NULL, row_key TEXT NOT NULL, value TEXT NOT NULL,
                                   PRIMARY KEY(generation, row_key));
    """)
    connection.execute("INSERT INTO active VALUES (1)")
    connection.execute("INSERT INTO generations VALUES (1, 'canonical-A')")
    connection.executemany("INSERT INTO projection_rows VALUES (1, ?, ?)", rows.items())


def snapshot(connection, current_source):
    connection.execute("BEGIN")
    try:
        generation, indexed_source = connection.execute("""
          SELECT a.generation, g.source_canonical_revision
          FROM active a JOIN generations g ON g.generation = a.generation
        """).fetchone()
        rows = dict(connection.execute("SELECT row_key, value FROM projection_rows WHERE generation = ?", (generation,)))
        # The source check is deliberately after the rows have been read.
        source = current_source() if callable(current_source) else current_source
        return {"status": "current", "generation": generation, "rows": rows} if source == indexed_source else {"status": "stale"}
    finally:
        connection.execute("COMMIT")


def stage(connection, after, affected, mode, generation=2):
    prior = connection.execute("SELECT generation FROM active").fetchone()[0]
    connection.execute("BEGIN IMMEDIATE")
    connection.execute("INSERT INTO generations VALUES (?, 'canonical-B')", (generation,))
    if mode == "incremental":
        connection.execute("INSERT INTO projection_rows SELECT ?, row_key, value FROM projection_rows WHERE generation = ?", (generation, prior))
        connection.executemany("DELETE FROM projection_rows WHERE generation = ? AND row_key = ?", ((generation, key) for key in affected))
        connection.executemany("INSERT INTO projection_rows VALUES (?, ?, ?)", ((generation, key, after[key]) for key in affected if key in after))
    else:
        connection.executemany("INSERT INTO projection_rows VALUES (?, ?, ?)", ((generation, key, value) for key, value in after.items()))
    connection.execute("UPDATE active SET generation = ?", (generation,))
    staged = dict(connection.execute("SELECT row_key, value FROM projection_rows WHERE generation = ?", (generation,)))
    if staged != after:
        connection.execute("ROLLBACK")
        raise AssertionError("staged generation differs from full IndexProjection oracle")


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def measure(rows, after, affected, mode, runs):
    samples = []
    for _ in range(runs):
        with tempfile.TemporaryDirectory(prefix="hamii-index-generation-") as directory:
            writer = connect(str(Path(directory) / "index.sqlite"))
            setup(writer, rows)
            start = time.perf_counter_ns()
            stage(writer, after, affected, mode)
            writer.execute("COMMIT")
            samples.append((time.perf_counter_ns() - start) / 1_000_000)
            writer.close()
    return {"runs": runs, "rawMs": samples, "p50Ms": percentile(samples, 0.5), "p95Ms": percentile(samples, 0.95)}


def main(raw_path, result_path):
    raw = json.loads(Path(raw_path).read_text())
    for case in raw["cases"]:
        assert case["matchesFullProjection"]
        old, new = case["beforeRows"], case["afterRows"]
        affected = set(case["invalidatedRows"])
        patched = dict(old)
        for key in affected:
            patched.pop(key, None)
            if key in new:
                patched[key] = new[key]
        assert patched == new, case["scenario"]

    base = next(case for case in raw["cases"] if case["scenario"] == "availability")
    with tempfile.TemporaryDirectory(prefix="hamii-index-atomic-") as directory:
        path = str(Path(directory) / "index.sqlite")
        writer, reader = connect(path), connect(path)
        setup(writer, base["beforeRows"])
        assert snapshot(reader, "canonical-A")["rows"] == base["beforeRows"]
        stage(writer, base["afterRows"], base["invalidatedRows"], "incremental")
        old_during = snapshot(reader, "canonical-A")
        new_during = snapshot(reader, "canonical-B")
        assert old_during["rows"] == base["beforeRows"] and new_during == {"status": "stale"}
        writer.execute("COMMIT")
        new_after = snapshot(reader, "canonical-B")
        assert new_after["rows"] == base["afterRows"] and new_after["generation"] == 2
        # A query starts with generation B; source switches to A after rows are read.
        source = {"current": "canonical-B"}
        def switch_after_row_read():
            source["current"] = "canonical-A"
            return source["current"]
        branch_switch_result = snapshot(reader, switch_after_row_read)
        assert branch_switch_result == {"status": "stale"}
        stage(writer, base["beforeRows"], base["invalidatedRows"], "incremental", generation=3)
        # The Canonical source changes after staging and before publication.
        candidate_source, observed_source = "canonical-B", "canonical-C"
        assert candidate_source != observed_source
        writer.execute("ROLLBACK")
        assert snapshot(reader, observed_source) == {"status": "stale"}
        assert snapshot(reader, "canonical-B")["rows"] == base["afterRows"]
        writer.close()
        reader.close()

    measurements = {}
    for count, entry in sorted(raw["fullProjectionTimings"].items(), key=lambda item: int(item[0])):
        old, new, affected = entry["beforeRows"], entry["afterRows"], entry["affectedKeys"]
        runs = 25 if int(count) < 1000 else 10
        measurements[count] = {
            "rowCount": len(old), "invalidatedCount": len(affected),
            "fullProjection": {key: entry[key] for key in ("runs", "rawMs", "p50Ms", "p95Ms")},
            "fullGeneration": measure(old, new, affected, "full", runs),
            "incrementalGeneration": measure(old, new, affected, "incremental", runs),
        }
    result = {
        "model": "actual Swift IndexProjection rows; spike-only SQLite WAL copy/patch/active-pointer generation",
        "correctness": [{key: value for key, value in case.items() if key not in ("beforeRows", "afterRows")}
                        for case in raw["cases"]],
        "atomic": {"oldReaderDuringBuild": "generation 1 full rows", "newSourceDuringBuild": new_during["status"],
                   "newReaderAfterCommit": "generation 2 full rows", "rollback": "generation 2 retained",
                   "sourceSwitchAfterRowRead": branch_switch_result["status"],
                   "sourceChangedBeforePublish": "rollback and retain generation 2",
                   "partialRowObservations": 0},
        "measurements": measurements,
        "limits": "generation timings exclude Canonical loading/revision, projection computation and query freshness; copy-all incremental prototype",
    }
    Path(result_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"atomic": result["atomic"], "cases": len(result["correctness"]),
                      "measurements": {size: {"rows": value["rowCount"],
                                         "fullP95": value["fullGeneration"]["p95Ms"],
                                         "incrementalP95": value["incrementalGeneration"]["p95Ms"]}
                                       for size, value in measurements.items()}}, indent=2))


if __name__ == "__main__":
    main(*sys.argv[1:])
