<!-- /AGENTS.md -->

# Repository working rules

## Project context

Fill in these fields; remove inapplicable entries.

- Mission: [One sentence.]
- Product contract: [Authoritative requirements file(s), such as README.md or spec/.]
- Supported environments: [Languages, runtimes, platforms, and versions.]
- Setup: [Canonical command using committed lockfiles.]
- Quality gates: [Canonical format, lint, type, test, and build commands.]
- Generation: [Sources, outputs, and regeneration command, if any.]
- Language rules: [Languages for identifiers, comments, documentation, and collaboration.]
- Workflow: [Branch, review, merge, release, and publication conventions.]

## Authority

- Read applicable nested AGENTS.md files before editing their directories.
- AGENTS.md defines working rules; the product contract defines intended behavior.
- Give each definition one authoritative source. Code and executable configuration define implementation details; tests verify contracts; decision records explain rationale.
- Plans, exploratory notes, examples, and hypotheses are not accepted requirements. Re-evaluate old ideas and promote accepted decisions into authoritative documentation.
- Resolve conflicts explicitly. Intentional behavior changes require contract and verification updates.
- Update generated artifacts through their source or generator, then regenerate. Mark generated files clearly. Keep human-readable documentation useful without duplicating maintenance.

## Design

- Make the smallest coherent change satisfying the current requirement.
- Prefer explicit code, simple control flow, focused functions, deletion, and consolidation.
- Introduce abstractions only for a real repeated concept or system boundary. Avoid speculative frameworks, extension points, adapters, registries, and compatibility layers.
- Separate deterministic logic from external effects where useful; do not force an architectural pattern.
- Give mutable state and side effects one clear owner. Derive values instead of synchronizing duplicate state.
- Use coherent domain types and closed-state representations to make invalid states difficult to express.
- Long-lived asynchronous operations need ownership, cancellation, and stale-result rules.
- Judge complexity by state, ownership, concurrency, and control flow, not line count. The existing file layout is not a contract.

## Implementation

- Use the language normally. Prefer standard facilities and existing dependencies.
- Validate untrusted input at narrow boundaries and convert it into precise domain values.
- Handle failures explicitly, preserve useful context, and expose unsafe or incomplete outcomes. Do not silently swallow errors or hide unclear partial success behind fallback behavior.
- Use the shortest precise name: nouns for concepts, verbs for actions, and state or question names for booleans. Make mutation and I/O visible.
- Avoid vague names and catch-all modules. Keep imports explicit; add re-exports only for an intentional public API.

## Evidence and refactoring

- Distinguish observed facts, hypotheses, and unknowns. Never promote an inference, proposal, or placeholder into an established fact.
- When uncertain external behavior affects correctness, inspect relevant version-specific documentation or run a discriminating experiment.
- Understand existing mechanisms before adding retries, delays, recovery paths, or state.
- Structural refactors preserve behavior, including timing, ordering, cancellation, and asynchronous boundaries, unless deliberately changed.
- Keep unrelated cleanup separate. Reassess remaining work when earlier changes make it unnecessary.

## Comments and headers

- Explain invariants, assumptions, ownership, external constraints, and non-obvious decisions. Comments must add information beyond names, types, and code.
- Repository-authored files supporting comments use a repository-relative path header beginning with / in native comment syntax.
- Required first-line directives precede the header. Keep touched headers accurate; exempt generated or tool-owned files where necessary. Never invent comments for unsupported formats.

## Tests and quality

- Test observable behavior and stable contracts, including rejection paths and regressions, at the lowest useful level.
- Keep tests deterministic. Use focused fakes and real integration tests where external behavior cannot be represented faithfully.
- Update meaningful tests for changed behavior. Avoid placeholder tests and assertions preserving obsolete architecture.
- Run affected canonical gates before completion. CI invokes the same repository-local commands.
- Keep verification non-mutating; separate fixes and generation from checks.
- Fix underlying problems. Do not weaken checks, grow diagnostic baselines, add unchecked casts, or suppress diagnostics merely to pass.
- Report failures and unavailable checks accurately. Distinguish automated, manual, and platform-specific validation.

## Dependencies and workflow

- Install from committed lockfiles. Update manifests and lockfiles together through the package manager; never hand-edit lockfiles.
- Add dependencies only for a concrete need.
- Keep setup idempotent and separate from validation. Existing lifecycle automation calls repository-local entry points and does not regenerate lockfiles.
- Pull request titles MUST follow the Conventional Commits specification.
- Follow repository workflow. Do not bypass hooks or rules to evade failures.
- Keep secrets, credentials, caches, build output, and local runtime state out of source control.

## Completion

Confirm contract alignment, update authoritative sources, regenerate affected outputs, and run affected gates. Check for dead state, stale names, duplicate representations, obsolete tests, and unnecessary compatibility code.

Report what changed, why, actual validation results, and unresolved limits.
