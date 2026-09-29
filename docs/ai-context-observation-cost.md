# AI Context Canonical Observation Cost

## Question and evidence

The production `ProjectContextService` obtains one `ProjectRepository.observe()` per response. This measurement separates its Canonical observation work from projection and the CLI process floor. Raw samples and conditions are in [ai-context-observation-cost.json](measurements/ai-context-observation-cost.json). Run `swift build --product hamii && python3 scripts/measure-ai-context-observation.py --output docs/measurements/ai-context-observation-cost.json` to regenerate the result using disposable projects.

The script reuses the 1,000 and 10,000 Layer fixtures from `scripts/measure-ai-context.py`: one selected Text Layer plus unrelated Text siblings in the **same Screen shard**. Each project has ten Canonical JSON paths. It measures 20 ordinary `observe()` calls, 20 instrumented calls through the same implementation, 100 context operations against one already observed in-memory `ProjectObservation`, 20 separate Agent profile reads, and 10 one-shot `hamii version --json` calls per scale. The Swift tests and executable use debug builds; these are path measurements, not release-build latency claims. All values below are milliseconds; `min` and `max` describe only these finite samples. The prior T1/T2/T3 workflow timings come from [AI Context Query Performance](ai-context-query-performance.md), with five runs per workflow under its recorded conditions. AI total tokens, task success, and cost were not measured.

| Measure (median; min–max) | 1k Layers | 10k Layers |
| --- | ---: | ---: |
| Ordinary `observe()` | 12.344; 12.262–15.729 | 109.524; 109.108–113.121 |
| Instrumented `observe()` | 12.315; 12.223–13.042 | 109.102; 108.600–110.546 |
| Entity decode, summed per observation | 7.401 | 73.109 |
| Document validation | 3.277 | 32.289 |
| ClientPrecondition Canonical path discovery | 0.476 | 0.573 |
| ClientPrecondition second bytes read | 0.191 | 0.531 |
| ClientPrecondition hash | 0.139 | 1.168 |
| In-memory context operation range (six operations) | 0.002–0.015 | 0.002–0.015 |
| Separate Agent profile read/validation | 0.031; 0.031–0.135 | 0.031; 0.031–0.065 |
| Minimal one-shot CLI version | 5.997; 5.842–6.971 | 5.896; 5.803–6.081 |

The first collection grouped each folder measurement as an independent sample. Empty folders then produced a misleading 0 ms entity-decode median. The collection was corrected to sum every stage **within each observation** before calculating its median; the linked JSON contains the final corrected run only. One intermediate corrected run had a 286 ms `version` outlier; that run was overwritten during the script assertion check and is not included in the reported samples. Instrumented stages are nested in places and should not be added together as if all were disjoint. The in-memory operation timings include memory repository dispatch and exclude Canonical observation, so they are an approximation of projection cost rather than an end-to-end service measurement.

In this fixture, entity decode and Document validation account for most of the measured `observe()` time. The ClientPrecondition path discovery, second bytes read, and hash are visible but small by comparison. Ten Canonical files contain one large Screen shard; this does not establish behavior for many shards, many assets, different validation graphs, cold filesystem cache, or concurrent writers. `AgentProfilesRepository.profiles()` is measured separately because the production `observe()` call does not invoke it. The work changes only measurement recording and does not change the production freshness, validation, or save rules.

The previous one-shot CLI results were: 1k T1/T2/T3 medians 43.194/86.726/86.172 ms and 10k 247.372/496.050/491.846 ms. They include multiple processes and Canonical observations, so they must not be subtracted from these stage values to estimate an exact overhead. The `version` result is only a process/CLI floor, not the full startup attribution.

## Next decision input

The observed cost is sensitive to Layer count inside one Screen; the next focused measurement should separate entity decoding and validation on representative shard shapes before choosing any caching, partial read, or session design. No performance optimization or safety relaxation follows from this profile alone.
