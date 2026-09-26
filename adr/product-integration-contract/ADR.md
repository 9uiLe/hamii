# Pending: Product Integration Contract の実証

- **Status:** 未確定 / Needs Validation
- **Decision needed:** Inputs/Events/Bindings/Tokens/States/Native/A11y intent のどの粒度で repository-aware AI に渡せば、異なる product architecture に安全に適応できるか。
- **Current constraint:** MVVM/TCA/DI/Router は IR に入れない。AI の変更は reviewable diff、unknown mapping は Needs Resolution。
- **Options:** component 単位 contract、screen 単位 contract、dependency graph 付き contract。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** Contract schema と Integration Harness/AI workflow が docs/code に反映され、受入基準を通過したら削除する。
