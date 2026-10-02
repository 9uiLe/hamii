# Human / Agent mutation matrix probe

Run from the repository root:

```sh
HAMII_SOURCE_COMMIT=$(git rev-parse HEAD) sh adr/authoring-policy-enforcement/spikes/actor-policy-parity/artifacts/actor-mutation-matrix/run.sh > /tmp/hamii-actor-mutation-matrix.json
```

`run.sh` creates an isolated temporary Swift package depending on the current
repository, runs `probe.swift`, and removes that package. A failed assertion or
build returns a nonzero exit code. The committed `result.json` records one run
on commit `38fef033c4bb2d905d22333b6cb705947ada21b6`, macOS 27.0,
Swift 6.4, arm64. The run passed 20 of 20 checks. It is a correctness matrix,
not a latency benchmark.

The probe uses a minimal in-memory `ProjectRepository` with a fixed
`ClientPrecondition`. Each Human/Agent pair starts from the same `Document`
and uses the same `AuthoringIntent` through `ProjectService.mutate`, which
invokes `MutationEngine.apply` and `DocumentValidator.validate`. For the two
product-policy cases, it also constructs the exact candidate directly and
compares typed `rule` and `entityID` diagnostics. The main base Document is
valid under both enabled policies.

Confirmed for this exercised path:

- Empty Button text: both actors reject `accessibility.controlLabel` on
  `layer_button`; direct candidate validation reports the same diagnostic.
- Untokened Stack: both actors reject `token.spacingRequired` on
  `layer_stack`; direct candidate validation reports the same diagnostic.
- `maximumMutationNodes = 2`: three mutations are rejected for both actors.
- `AgentHarness.maximumMutations = 1`: two mutations succeed for Human and
  are rejected for Agent.
- `mayPromoteScope = false` rejects only Agent promotion; Human and an
  explicitly approved Agent can promote the same component.
- The availability control reports `component.denied` on `layer_instance`
  for both actors and for direct candidate validation. This control starts
  with an intentionally invalid in-memory Document to hold a fixed instance
  ID. It does **not** prove that `CanonicalRepository.observe` would accept
  that Document; that repository validates on load and may reject earlier.
- Every rejected candidate had zero `ProjectRepository.commit` calls,
  unchanged revision 0, and unchanged in-memory state token.

Unknown: disk Canonical bytes, GUI/CLI adapter forwarding, concurrent
observations, and persisted invalid-policy load behavior are not exercised
here. No prototype is production policy code.
