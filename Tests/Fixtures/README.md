# Canonical Format v1 layer baseline

`format-v1-layer.json` was encoded by the production `Layer` from source commit
`e652031ea92fdd6a51997818bc4590389b40a90a` using the Canonical JSON encoder
settings (`sortedKeys`, `prettyPrinted`, `withoutEscapingSlashes`, trailing LF).

SHA-256: `0ea0d46d3f78f83de37f6586ed7e6215851b24f14d5ea3deeca3012f7a838d80`

The fixture covers all seven Format v1 layer kinds, binding and fallback, event,
asset reference, stack layout and tokens, multi-child scroll, nested component
slot content, interaction, accessibility, native intent, target overrides, and
a currently accepted cross-kind asset reference. The test requires exact bytes
for both construction and decode/re-encode.
