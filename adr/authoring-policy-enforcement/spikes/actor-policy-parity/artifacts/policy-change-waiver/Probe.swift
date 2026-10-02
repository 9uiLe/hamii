import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat

// Spike-only executable. The waiver functions below are prototypes over typed
// diagnostics; they do not alter the persisted format or the production writer.
func document(layerCount: Int, tokenized: Bool) -> Document {
    var result = Document(name: "Policy Probe")
    let scope = result.scopes[0].id
    var children: [Layer] = []
    for index in 0..<layerCount {
        children.append(Layer(id: EntityID("layer_text_\(index)"), kind: .text,
                              name: "Text \(index)", text: "Text"))
    }
    var root = Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: children)
    root.layout.axis = .vertical
    if tokenized {
        let token = EntityID("token_spacing")
        result.tokens = [DesignToken(id: token, name: "Spacing", kind: .spacing,
                                     ownerScopeID: scope, value: .literal("8"))]
        root.layout.spacingTokenID = token
    }
    result.screens = [Screen(id: EntityID("screen_main"), name: "Main", scopeID: scope, root: root)]
    return result
}

func key(_ diagnostic: Diagnostic) -> String {
    "\(diagnostic.rule)@\(diagnostic.entityID?.rawValue ?? "none")"
}

func rejection(_ candidate: Document, author: Author) -> [Diagnostic]? {
    do {
        _ = try MutationEngine.apply(.createPage(name: "Unrelated"), to: candidate,
                                     expectedRevision: candidate.revision, author: author,
                                     agent: AgentHarness(profileName: "Probe", maximumMutations: 10))
        return nil
    } catch AuthoringError.validation(let diagnostics) {
        return diagnostics
    } catch {
        return nil
    }
}

func times(_ candidate: Document, trials: Int) -> [Double] {
    var results: [Double] = []
    for _ in 0..<trials {
        let start = DispatchTime.now().uptimeNanoseconds
        let diagnostics = DocumentValidator.validate(candidate)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(diagnostics.isEmpty, "Benchmark fixture must be valid")
        results.append(Double(elapsed) / 1_000_000)
    }
    return results
}

var before = document(layerCount: 1, tokenized: false)
before.authoringHarness.requireTokenSpacing = false
let beforeDiagnostics = DocumentValidator.validate(before)
var after = before
after.authoringHarness.requireTokenSpacing = true
let afterDiagnostics = DocumentValidator.validate(after)
let humanRejection = rejection(after, author: .human)
let agentRejection = rejection(after, author: .agent)

var waiver = document(layerCount: 0, tokenized: false)
var otherStack = Layer(id: EntityID("layer_other_stack"), kind: .stack, name: "Other Stack")
otherStack.layout.axis = .vertical
waiver.screens[0].root.children = [otherStack,
    Layer(id: EntityID("layer_bad_button"), kind: .button, name: "Bad Button", text: "")]
waiver.authoringHarness.requireTokenSpacing = true
waiver.authoringHarness.requireAccessibleControls = true
let all = DocumentValidator.validate(waiver)
let scoped = all.filter { !($0.rule == "token.spacingRequired" && $0.entityID == EntityID("layer_root")) }
let global = all.filter { $0.rule != "token.spacingRequired" }
let scopedHuman = rejection(waiver, author: .human)?.filter {
    !($0.rule == "token.spacingRequired" && $0.entityID == EntityID("layer_root"))
}
let scopedAgent = rejection(waiver, author: .agent)?.filter {
    !($0.rule == "token.spacingRequired" && $0.entityID == EntityID("layer_root"))
}

// Real CanonicalRepository boundary: a policy edit that makes old layers
// invalid cannot be committed through hamii's current writer.
let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("hamii-policy-probe-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: scratch) }
let repository = CanonicalRepository(root: scratch)
_ = try repository.create(name: "Policy Probe")
let initial = try repository.observe()
var valid = initial.document
valid.screens = [before.screens[0]]
valid.screens[0].scopeID = valid.scopes[0].id
valid.revision += 1
let validObservation = try repository.commit(valid, expected: initial)
var invalidPolicyEdit = validObservation.document
invalidPolicyEdit.authoringHarness.requireTokenSpacing = true
invalidPolicyEdit.revision += 1
var invalidPolicyCommitRule: String? = nil
do {
    _ = try repository.commit(invalidPolicyEdit, expected: validObservation)
} catch CanonicalError.invalid(let diagnostics) {
    invalidPolicyCommitRule = diagnostics.first(where: { $0.rule == "token.spacingRequired" })?.rule
}
let afterRejectedEdit = try repository.observe()
let unrelatedAfterRejection = try ProjectService(repository: repository)
    .mutate(.createPage(name: "Unrelated"),
            expectedState: afterRejectedEdit.statePrecondition, author: .human)

// External byte edit is not a supported hamii policy-change workflow, but it
// exposes the loader boundary for an invalid persisted document.
let manifestURL = scratch.appendingPathComponent("hamii.json")
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
var modifiedManifest = manifest
var harness = modifiedManifest["authoringHarness"] as! [String: Any]
harness["requireTokenSpacing"] = true
modifiedManifest["authoringHarness"] = harness
try JSONSerialization.data(withJSONObject: modifiedManifest, options: [.sortedKeys])
    .write(to: manifestURL)
var loaderRule = "none"
var serviceRule = "none"
do {
    _ = try repository.observe()
} catch CanonicalError.invalid(let diagnostics) {
    loaderRule = diagnostics.first(where: { $0.rule == "token.spacingRequired" })?.rule ?? "otherInvalid"
} catch {
    loaderRule = "otherError:\(type(of: error))"
}
do {
    _ = try ProjectService(repository: repository).mutate(.createPage(name: "Unrelated Again"),
        expectedState: afterRejectedEdit.statePrecondition, author: .human)
} catch CanonicalError.invalid(let diagnostics) {
    serviceRule = diagnostics.first(where: { $0.rule == "token.spacingRequired" })?.rule ?? "otherInvalid"
} catch {
    serviceRule = "otherError:\(type(of: error))"
}

let trialCount = 40
var smallOff = document(layerCount: 10, tokenized: true)
smallOff.authoringHarness.requireTokenSpacing = false
var smallOn = smallOff
smallOn.authoringHarness.requireTokenSpacing = true
var largeOff = document(layerCount: 1000, tokenized: true)
largeOff.authoringHarness.requireTokenSpacing = false
var largeOn = largeOff
largeOn.authoringHarness.requireTokenSpacing = true

// Warm each branch, then interleave conditions to limit time/load drift.
for fixture in [smallOff, smallOn, largeOff, largeOn] {
    for _ in 0..<5 { precondition(DocumentValidator.validate(fixture).isEmpty) }
}
var measurements: [String: [Double]] = [
    "small_off_ms": [], "small_on_ms": [], "large_off_ms": [], "large_on_ms": []]
for _ in 0..<trialCount {
    measurements["small_off_ms"]! += times(smallOff, trials: 1)
    measurements["small_on_ms"]! += times(smallOn, trials: 1)
    measurements["large_off_ms"]! += times(largeOff, trials: 1)
    measurements["large_on_ms"]! += times(largeOn, trials: 1)
}

let payload: [String: Any] = [
    "policyChange": [
        "offInitialValid": beforeDiagnostics.isEmpty,
        "onDiagnostic": afterDiagnostics.map(key),
        "humanRejected": humanRejection != nil,
        "agentRejected": agentRejection != nil,
        "humanMatchesDirect": humanRejection?.map(key) == afterDiagnostics.map(key),
        "agentMatchesDirect": agentRejection?.map(key) == afterDiagnostics.map(key),
        "originalRevision": after.revision
    ],
    "waiverPrototype": [
        "none": all.map(key),
        "scopedRuleEntity": scoped.map(key),
        "globalRule": global.map(key),
        "scopedHumanEqualsAgent": scopedHuman?.map(key) == scopedAgent?.map(key),
        "scopedHumanEqualsDirect": scopedHuman?.map(key) == scoped.map(key)
    ],
    "productionBoundary": [
        "invalidPolicyCommitRule": invalidPolicyCommitRule ?? "none",
        "policyStillOffAfterRejectedCommit": !afterRejectedEdit.document.authoringHarness.requireTokenSpacing,
        "revisionUnchangedAfterRejectedCommit": afterRejectedEdit.document.revision == validObservation.document.revision,
        "unrelatedMutationAfterRejectedCommitAccepted": unrelatedAfterRejection.revision == validObservation.document.revision + 1,
        "externalInvalidManifestObserveRule": loaderRule,
        "externalInvalidManifestServiceRule": serviceRule
    ],
    "measurement": [
        "trialsPerCondition": trialCount,
        "warmupsPerCondition": 5,
        "smallLayerCount": 11,
        "largeLayerCount": 1001,
        "metric": "DocumentValidator.validate wall-time milliseconds",
        "raw": measurements
    ]
]
let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
