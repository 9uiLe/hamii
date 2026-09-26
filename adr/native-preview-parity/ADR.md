# Native Preview と生成アプリの意味的一致

## Context

Host と Generator は同じ Target Plan の別実装であり、差を測らないと supported semantics を保証できない。

## Decision to Make

どの conformance 指標と gate で Host と生成アプリの差を許容するか。

## Constraints

Pixel 完全一致を無条件に要求しない。Capability loss と revision/fixture/OS を揃える。

## Options

bounds/a11y/event/visual の複合 gate、手動 review のみ、screenshot pixel gate。

## Current Hypothesis

**未確定:** 複数指標の gate が必要と考えるが閾値は未検証。

## Unknowns

font antialiasing、system UI 差、interaction/state trace の許容値。

## Required Evidence

- [Host/source conformance](spikes/host-source-conformance/SPIKE.md)

## Decision Criteria

Spike の結果を用いて選択肢を比較し、判断を先に commit する。必要な実装・検証と Current Architecture への反映を終えるまで削除しない。

## Status

Spike Required
