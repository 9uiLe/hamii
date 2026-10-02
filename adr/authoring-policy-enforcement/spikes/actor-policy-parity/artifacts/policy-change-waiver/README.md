# Policy change, waiver scope, and validation cost probe

This is Spike evidence, not a production waiver implementation. `Probe.swift` uses the
current `DocumentValidator`, `MutationEngine`, `ProjectService`, and
`CanonicalRepository`. `result.json` contains the bounded raw measurements and
rule/entity outcomes.

## Reproduction

Input commit: `38fef033c4bb2d905d22333b6cb705947ada21b6` (the probe source is
an uncommitted Spike artifact at measurement time). macOS 27.0, arm64 Apple M1
Pro, 10 logical CPUs, 16 GiB RAM; Apple Swift 6.4. `.build/debug` objects
from this checkout were used. To reproduce them after the Evidence commit,
verify that tracked source and package inputs have the same bytes as the
measurement commit and that no untracked source inputs exist, then let SwiftPM
validate/rebuild its input graph before the direct `swiftc` link. No simulator, network, or
Product build was used. Other machine load was not fixed, so these
distributions are local observations, not a performance guarantee.

```sh
git diff --quiet 38fef033c4bb2d905d22333b6cb705947ada21b6 -- Package.swift Package.resolved Sources
test -z "$(git ls-files --others --exclude-standard -- Package.swift Package.resolved Sources)"
swift build --product hamii
swiftc -I .build/debug \
  adr/authoring-policy-enforcement/spikes/actor-policy-parity/artifacts/policy-change-waiver/Probe.swift \
  .build/debug/HamiiFormat.o .build/debug/HamiiApplication.o .build/debug/HamiiCore.o \
  -o /tmp/hamii-policy-change-waiver-probe
/tmp/hamii-policy-change-waiver-probe > \
  adr/authoring-policy-enforcement/spikes/actor-policy-parity/artifacts/policy-change-waiver/result.json
```

The executable is temporary. It creates and removes a temporary Canonical
project outside the checkout. `result.json` was written only after exit 0.
The source/manifest guard and SwiftPM build both passed in a clean rerun;
policy-change, waiver, and production-boundary results matched `result.json`
exactly. Timings from that rerun were not substituted into the original 40
trials.

## Confirmed in this fixture

- A document with one tokenless Stack validates with
  `requireTokenSpacing=false`. Flipping the in-memory candidate to `true`
  yields `token.spacingRequired@layer_root`.
- An unrelated `createPage` through `MutationEngine.apply` is rejected for
  Human and Agent by the same rule/entity pair as direct
  `DocumentValidator.validate(candidate)`. The input revision remains 0.
  This confirms in-memory full-candidate validation, not a persisted invalid
  project's end-to-end mutation route.
- `CanonicalRepository.commit` refuses to persist a policy edit that would
  introduce that violation. The prior policy and revision remain; an unrelated
  `ProjectService` mutation from the still-valid observation succeeds.
- A direct external edit to `hamii.json` that sets the strict flag makes the
  stored project invalid. Both `CanonicalRepository.observe` and
  `ProjectService.mutate` reject at the load/observation boundary with
  `token.spacingRequired`. The service does not reach candidate mutation
  validation in this case. Direct editing is not a supported hamii workflow.

## Spike-only waiver comparison

The candidate has two tokenless Stacks and an empty-label Button. These
filters run on typed diagnostics after `DocumentValidator.validate`; no
waiver format, mutation path, or storage code was added.

| Prototype | Remaining typed violations | Observation |
| --- | --- | --- |
| None | `token.spacingRequired@layer_root`, `token.spacingRequired@layer_other_stack`, `accessibility.controlLabel@layer_bad_button` | Full candidate remains blocked. |
| Rule + entity (`token.spacingRequired`, `layer_root`) | `token.spacingRequired@layer_other_stack`, `accessibility.controlLabel@layer_bad_button` | No leakage to another entity or rule in this fixture; Human/Agent filtered results match. |
| Global rule (`token.spacingRequired`) | `accessibility.controlLabel@layer_bad_button` | Suppresses the second Stack's same-rule violation without explicit entity authorization. |

The global prototype did not suppress the different accessibility rule; the
negative evidence is its same-rule, different-entity leakage. No prototype
establishes who can grant a waiver, how it is audited, or how it survives
policy and entity changes.

## Candidate validation timing

Wall time around `DocumentValidator.validate`, milliseconds. Each condition
had 5 warmups and 40 measured trials. Off/on candidates differ only in the
policy flag and are otherwise valid: one tokenized root Stack and 10 or 1000
Text children (11 or 1001 layers total). Conditions were interleaved each
trial. p95 uses nearest rank; the full 40-value arrays are in `result.json`.

| Candidate | n | p50 ms | p95 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| 11 layers, off | 40 | 0.052833 | 0.064542 | 0.074583 |
| 11 layers, on | 40 | 0.052688 | 0.056125 | 0.057750 |
| 1001 layers, off | 40 | 3.053187 | 3.148000 | 3.198833 |
| 1001 layers, on | 40 | 3.078771 | 3.217292 | 3.612000 |

This measures only in-memory candidate validation. It excludes Canonical
observation, decoding, mutation construction, persistence, and process startup.
The small differences do not justify an SLA or an optimization decision.

## Unknown / not implemented

- A production policy-change workflow that keeps pre-existing violations
  visible while allowing safe unrelated edits is not present. Waiver
  authorization, scope, audit, and lifetime remain undecided.
- The proposed waiver filters are not connected to `ProjectService` or
  `CanonicalRepository`; a filtered list does not authorize mutation.
- Other rule types, deeper layer trees, and concurrent actor mutation were
  not measured here. Actor parity in the full service path is a separate
  matrix in this Spike.
