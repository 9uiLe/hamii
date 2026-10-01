# Binding/state relation comparison evidence

Run `python3 evaluate.py > evaluation.json` from this directory (or run the script by path). This is a Python standard-library-only Spike evaluator. Its saved [evaluation.json](evaluation.json) is deterministic; two final runs and the saved file had SHA-256 `45f4849a7c59e072d5917f59c4f5ca4d76956eae8e516a97e3bc85bc36815dee`. The independent auditor first verified byte-identical output after a serialization-order correction; the final report-only change separates six candidate semantic primitives from the shared missing-mapping policy.

| Artifact | Responsibility |
| --- | --- |
| [oracle.json](oracle.json) | P0–P4 synthetic source values and evaluator-only expected I01/I02 visibility/value. This is a Spike control, not final Product copy. |
| [relation-R.json](relation-R.json) | Candidate R: two output-oriented typed binding relations. |
| [graph-G.json](graph-G.json) | Candidate G: five typed nodes and four annotated value/visibility edges. |
| [transform-registry.json](transform-registry.json) | Shared deterministic date transform used by both candidates. |
| [repository-mapping.json](repository-mapping.json) | Explicit **proposed** Team MINO mapping, separate from semantic candidates. Renderability/date retention require Product implementation. |
| [evaluate.py](evaluate.py) | Strict normalization, 10-cell oracle comparison, missing/empty mapping rejection, wrong fallback detection, coverage/type guards. |
| [evaluation.json](evaluation.json) | Machine result. R and G match 10/10; negative checks fail closed within this simulation. |

Independent source auditors used separate fresh contexts. R received only R, the proposed mapping, transform registry, Team MINO iOS clean source at `dca2202f4be21869190d19bbcf223eb8646a2acd`, and Product convention docs. G received the corresponding G packet. They were not given oracle outputs, the other candidate or prior results. The evaluator auditor received both candidates and oracle but did not design them or read source audit results. The raw reports are preserved byte-for-byte as [R.txt](audits/R.txt), [G.txt](audits/G.txt), [evaluator.txt](audits/evaluator.txt), and [evaluator-followup.txt](audits/evaluator-followup.txt). `.txt` keeps the original temporary packet references as evidence without presenting them as current Repository links.

The initial evaluator audit found duplicate-oracle coverage and empty-mapping guard weaknesses. The follow-up confirms both are fixed. A later low-severity serialization-order issue was also fixed. The `mappingStatus` in the result remains **proposed simulation, not production validation**. The result identifies source dependencies but does not execute update propagation, cache transitions or UI rendering.
