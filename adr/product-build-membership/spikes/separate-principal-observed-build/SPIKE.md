# Separate principal observed build Spike

## Related Decision

[Product Build Membership Evidence](../../ADR.md) requires the receipt-pinned source bytes and executed compiler-input evidence to remain outside Product build code's control before `selectedBuildMember` can be issued. This Spike tests whether a separate verifier principal and an Endpoint Security observer can provide that boundary.

## Hypothesis

A verifier principal that owns the pinned source topology and OS event collector, separate from a builder principal running Xcode and Product scripts, may prevent the builder from changing either the source bytes or evidence used for the selected compiler invocation.

## Questions

- Is a usable Endpoint Security client entitlement and observer execution permission available in this environment?
- Can a second principal be used noninteractively for the builder while the verifier owns the source and collector?
- If both prerequisites exist, can the verifier reject source-path substitution, evidence forgery, and a Run Script that launches its own `swiftc`?

## Prototype Scope

First preflight the two environment prerequisites without changing accounts, installation, permissions, or Product data. Only if both exist, use disposable Food Truck C1 inputs to test source topology protection, Xcode build behavior, OS event lineage, compiler source opens, and forged Product evidence.

## Out of Scope

Production adapter implementation, enabling `selectedBuildMember`, alternate same-UID isolation schemes, and a general comparison of privileged deployment architectures. A viable privileged topology would require a separate decision on distribution and operations before production adoption.

## Measurements

Record the current toolchain and signing context, exact noninteractive entitlement/principal checks, exit status and relevant error category, and whether the protected source and observer can be exercised. If prerequisites exist, record the selected build outcome, source access denial, event lineage and completeness, attack outcomes, and cold/warm timing with trial counts. Separate measured results from inferred guarantees.

## Success Criteria

Both prerequisites are available. The builder can write only its DerivedData/temp locations and complete the selected build, but cannot write/rename/rebind/unmount protected source paths or alter/signal the verifier collector. Verifier-owned current-run OS events uniquely bind a legitimate selected compiler invocation and its open of the protected pinned source to the requested selection and blob. Forged logs/file lists/inventory and a Run Script launched `swiftc` do not cause a false positive. Missing events, ambiguous lineage, mismatched selection, observer interruption, and warm no-op remain `unverifiable`.

## Failure Criteria

With both prerequisites available, the builder can alter protected source or collector state, a malicious invocation cannot be distinguished from the selected compile task, or any unknown/ambiguous state produces a positive. Missing entitlement, observer privilege, or second principal is an environment blocker, not a failed security property.

## Result

**Blocked: protected positive acquisition environment unavailable.** Three independent read-only checks agreed on the following bounded observations on this macOS/Xcode 27 host:

| Prerequisite | Observed result | Limit |
| --- | --- | --- |
| Verifier signing | Two valid local code-signing identities; one Apple Development, no Developer ID Application. None alone grants Endpoint Security access. | Identity names and team identifiers are omitted. |
| Endpoint Security entitlement | Seventeen readable, locally cached provisioning profiles; zero contain `com.apple.developer.endpoint-security.client`, and zero contain `com.apple.developer.system-extension.install`. No entitlement/profile file or Endpoint Security client implementation was found in this repository. | The scan did not query the Apple Developer portal or establish whether a future grant is possible. |
| Observer installation/permission | `systemextensionsctl list` reported zero installed extensions. Current UID is 501; `sudo -n true` could not obtain noninteractive administrator rights. | Full Disk Access and `es_new_client` were not exercised; their runtime result is unknown. |
| Separate builder principal | Local account enumeration found one current ordinary UID and no other ordinary UID at or above 500. A system `nobody` UID exists, but `sudo -n -u nobody /usr/bin/id -u` and `sudo -n -u root /usr/bin/id -u` each returned exit 1 with `a password is required`. | No account was created, credentials requested, or alternative privileged helper/VM used. |

The checks used `security find-identity -v -p codesigning` with count-only output, `security cms -D -i` over the readable cached profiles with count-only entitlement extraction, `id`, `dscl`, `sudo -n`, `systemextensionsctl list`, `rg` over repository files, and `xcodebuild -version`. They made no repository, account, permission, or signing changes. The current source verifier's `swiftc -frontend -dump-parse` is unrelated to this selected-build observer preflight.

Apple's [Endpoint Security entitlement documentation](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.endpoint-security.client) says the entitlement must be requested and that a client without it receives `ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED`; [client creation documentation](https://developer.apple.com/documentation/endpointsecurity/es_new_client%28_%3A_%3A%29) describes the runtime permission requirements. These sources explain the prerequisite; they do not prove the unattempted local `es_new_client` result.

No Food Truck build, source-topology attack, observer event capture, fake `swiftc` attack, or performance trial was run. Thus the source and evidence security properties remain **Unknown**, rather than failed or confirmed. Apple's [EXEC](https://developer.apple.com/documentation/endpointsecurity/es_event_type_notify_exec) and [OPEN](https://developer.apple.com/documentation/endpointsecurity/es_event_type_notify_open) notifications are potential inputs, but an OPEN event alone does not establish compiler consumption of the protected bytes or selected target/module/configuration membership. Event gaps and malicious Run Script launched compilers still require a fail-closed discrimination test if the prerequisites become available.

## Conclusion

This host cannot run the candidate under the available noninteractive rights and locally cached entitlements. That is an environment **Blocked** result, not a security-property **Failure** and not evidence that Endpoint Security can never support the design. Do not enable production `selectedBuildMember`, infer a positive from EXEC/OPEN alone, or fall back to a same-UID workaround. The production `protectedBuildAcquisitionUnavailable` gate remains in force, and the parent ADR stays `Implementation Required`.

If a signed entitled verifier and separate builder principal later become available, resume with a verifier-owned immutable source topology and observer, explicitly test source write/parent rename/symlink replacement/unmount, collector tampering, forged text/file lists, a Run Script launched `swiftc`, event gaps, lineage ambiguity, warm no-op, and selected-build setting mismatch. A viable privileged topology would require a separate decision on distribution, permission, and operating cost before production use.

## Artifacts

None yet.
