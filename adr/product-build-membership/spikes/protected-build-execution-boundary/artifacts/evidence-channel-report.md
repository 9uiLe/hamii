# Evidence-channel red-team: controlled artifacts

## Scope

Read-only review of committed `adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts/{evaluate.py,join.py}` at the current hamii repository. All generated files are under `/tmp/hamii-evidence-channel-AfQddk`. The original Food Truck checkout and hamii repository were not edited. No production Xcode acquisition adapter exists yet. No Xcode Run Script was executed in this probe; these are controlled scratch log/file-list/JSON artifacts, not observed behavior of a malicious Product build.

## Inputs and commands

Source receipt/artifact: committed `source-evidence.json` for C1 `3cf70a8775a8d528d27b560185ed6d1116557b99`; tracked source `App/General/FlowLayout.swift` blob `92c12dc1f8ed077e2384d99792310648b9c8f718`. Previously measured raw log and DerivedData inputs are `/tmp/hamii-bridge-build-5_rduf7f/{first-build.log,warm-build.log,first-DerivedData}`. They were read, never modified.

```sh
python3 adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts/evaluate.py \
  --source adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts/source-evidence.json \
  --build adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts/build-inventory.json \
  --out /tmp/hamii-evidence-channel-AfQddk/baseline
python3 /tmp/hamii-evidence-channel-AfQddk/probe.py
python3 adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts/evaluate.py \
  --source adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts/source-evidence.json \
  --build /tmp/hamii-evidence-channel-AfQddk/broken-provenance-build-inventory.json \
  --out /tmp/hamii-evidence-channel-AfQddk/broken-provenance-evaluate
```

`probe.py` is the full reproducible control. The initial run failed only because the historical full JSON had `<DERIVED_DATA>` normalization rather than an absolute path. The script was corrected to resolve that placeholder to `first-DerivedData`; the corrected run exited 0. `probe-results.json` contains all verdicts and hashes.

## Measured scratch controls

| Control | Result | Meaning |
| --- | --- | --- |
| Fake `builtin-SwiftDriver` text appended to copy of successful warm log | Original warm log had 0 driver lines; forged copy had 1 line matching a simple `builtin-SwiftDriver`/module/`@` scanner. | Plain text occurrence cannot prove execution. This did not execute a Product Run Script or fool a production parser. |
| Stale file-list reuse | A first-build `Food_Truck_All.SwiftFileList` remained readable and contained the pinned source even though warm build had no executed SwiftDriver. | A filesystem search after a warm run can find old inputs; current-run binding is necessary. |
| Kit list mutation | Original `FoodTruckKit` list had 0 target-source occurrences; scratch `kit-forged.SwiftFileList` had 1 appended exact path. | Writable list bytes can change apparent membership. |
| Duplicate physical input | Scratch `app-duplicate.SwiftFileList` contained 2 target-source lines. | Parser must retain duplicate logical paths for `ambiguous`, not deduplicate. |
| DerivedData replacement | `os.replace` changed a copied file-list SHA-256 while retaining the pinned source line; before/after digests are in `probe-results.json`. | Same-UID scratch writer can replace this ordinary file; no isolation was tested. |
| Forged normalized warm invocation | Committed pure `join.py`: baseline warm `unverifiable`; after copying a first-build invocation into warm JSON, `selectedBuildMember`. | Join trusts the normalized inventory by design. Only a trusted acquisition boundary can supply it. |
| Forged normalized Kit input | Baseline explicit Kit `missingFromSelection`; after adding exact tracked input record, `selectedBuildMember`. | Join cannot establish provenance of caller-supplied records. |
| Duplicate normalized invocation/input | Both yield `ambiguous`. | Committed join catches duplicate records when present. |
| Missing raw provenance | Scratch compact inventory changed all `rawLog` and `fileList` paths to nonexistent paths; committed `evaluate.py` still exited 0 and returned `c1App: selectedBuildMember`. | The Spike artifact adapter does not read/authenticate raw logs or file lists. This is an explicit limit of that Spike, not production behavior. |

## Conclusion and limits

**Observed:** ordinary copied log/file-list artifacts can be forged or replaced in this scratch environment. The committed artifact-only adapter accepts internally consistent compact JSON even with nonexistent raw provenance paths; the pure join is not an acquisition or authentication layer. **Inferred:** a future production adapter that treats same-UID writable plain-text log/file-list content as executed-invocation authority could emit false positives; the positive path needs a protected evidence channel or must return `unverifiable`. **Unknown:** whether an actual hostile Xcode Run Script can inject a line into the parent `xcodebuild` output stream or race a selected current-run SwiftFileList under a particular isolation scheme. This control did not execute such a script or test OS isolation. No production build-membership output exists to test yet.
