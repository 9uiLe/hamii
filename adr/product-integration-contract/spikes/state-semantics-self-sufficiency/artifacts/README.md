# Contract-only probe inputs

Three new agent contexts each received one existing contract expression, clean Team MINO iOS source at `dca2202f4be21869190d19bbcf223eb8646a2acd`, and that Repository's own convention documents. They were instructed not to read the shared semantic fixture, prior generation prompts/results/patches, hamii ADRs, or another probe. They did not edit source. The scenario question named S0 = profile unavailable or loading, S1 = loaded with `createdAt == nil`, and S2 = loaded with `createdAt != nil`, **without providing the expected I01/I02 output**. The full expected-output table existed only in [SPIKE.md](../SPIKE.md) for evaluator use.

| Shape | Contract expression supplied | SHA-256 | Raw agent result |
| --- | --- | --- | --- |
| screen | [contract.json](../../existing-profile-state/artifacts/attempts/screen/contract.json) | `7c3281b09b784d8a00ea9a23e59f597fa90ea314232490fa806f0aad7a260fa1` | [screen.md](results/screen.md) |
| component | [contract.json](../../existing-profile-state/artifacts/attempts/component/contract.json) | `8fe4f02c30db3a1e40ebbb8e3ff2c593eb5051ca1d834f41acea00338624ab71` | [component.md](results/component.md) |
| graph | [contract.json](../../existing-profile-state/artifacts/attempts/graph/contract.json) | `f0b96dc18a0d54b6638a5789b54b3102d96b4b3dbb5ba484a1c2fdaaed514c7b` | [graph.md](results/graph.md) |

Fixed question for each agent: For each supplied scenario, identify what this contract **itself** uniquely requires for I01 displayName and I02 secondaryText, versus what target Repository source allows discovery. Classify each scenario `sufficient / insufficient / repository-discoverable / ambiguous` with exact contract fields and source paths/lines. A Product source state does not prove hamii contract intent. Record minimal missing semantics, whether a state list alone or a binding-to-state relation or dependency graph is needed, and whether a safe patch plan exists without silent guesses. Record UTC timing. The packet contained no source changes or acceptance answer.

The raw result files above are copied byte-for-byte from each agent's output. The temporary packets and target checkout were outside this Repository; the pinned contract JSON and source commit make the inputs reproducible.
