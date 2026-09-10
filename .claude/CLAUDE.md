# Project Instructions

## Core priorities

Work as a senior engineer maintaining an existing production codebase.

Priority order:

1. Correctness and data integrity
2. Security
3. Backward compatibility
4. Minimal scope of change
5. Maintainability
6. Performance
7. Style improvements

Do not trade reliability for shorter, more elegant, or more fashionable code.
Preserve production behavior unless the task explicitly requires changing it.
Prefer verified repository evidence over assumptions.

## Before changing code

For every non-trivial task:

1. Inspect the relevant implementation.
2. Search callers, consumers, configuration, tests, and related code.
3. Establish current behavior before changing it.
4. Identify compatibility, migration, security, operational, and data-integrity risks.
5. Search for existing helpers and equivalent behavior.
6. Identify the canonical owner of the responsibility.
7. Prefer the smallest complete change that solves the actual problem.
8. Determine validation before editing.

If a fact can be verified from source, configuration, Git history, logs, manifests,
dependencies, tests, or runtime output, verify it instead of guessing.

Do not invent paths, APIs, configuration keys, environment variables, database
fields, command-line parameters, runtime behavior, release metadata, scheduler
definitions, credential targets, or exit-code semantics.

## Change discipline

Preserve unrelated behavior and user-owned uncommitted changes.

Do not rewrite/reformat unrelated code, silently change defaults, introduce
unnecessary dependencies, remove compatibility behavior outside scope, or broaden
a narrow task into a repository-wide rewrite.

Inspect the final diff and preserve unrelated modifications in files you touch.

## Architecture and modularity

Repository direction:

    thin entrypoints -> cohesive domain modules -> canonical implementations -> tests

Project-wide invariants:

- Root operational `.ps1` files are orchestration entrypoints.
- Substantial reusable/domain logic belongs in focused `modules/BRAVO.<Domain>/` modules.
- Do not create new monoliths or move a monolith unchanged into one giant `.psm1`.
- Target root entrypoints at `<= 250` lines; `> 350` requires architectural justification.
- Never create a new `1000+` line entrypoint.
- Reusable policy/logic must have one canonical implementation.
- Search before adding helpers; reuse/extract instead of copy/paste.
- Do not create generic `Common` / `Utils` / `Helpers` dumping-ground modules merely to reduce line count.
- Preserve canonical configuration loading, logging, credentials, integrity, scheduler, and exit-code ownership.
- Prefer explicit parameters/return objects over new hidden `$global:` / `$script:` state.

Detailed policy: `.claude/rules/05-architecture.md`

Use the `safe-refactor` skill for behavior-preserving structural work when applicable.

## Refactoring

Refactoring is incremental and behavior-preserving by default. Before moving
high-risk operational logic, establish enough characterization evidence to detect
regressions. Preserve externally observable parameters, defaults, exit codes,
logs, paths, state formats, scheduler/service/network behavior, and cleanup semantics.

Do not combine broad refactoring with unrelated features, fixes, release promotion,
optimization, or formatting.

## PowerShell baseline

Windows PowerShell 5.1 compatibility is mandatory unless project policy explicitly changes.
Do not introduce PowerShell 7-only syntax or behavior. Avoid caller current-directory
assumptions and preserve `Set-StrictMode`, array, encoding, JSON, native-process,
`$LASTEXITCODE`, Scheduled Tasks, and exception semantics.

Detailed policy: `.claude/rules/powershell.md`

## Bugs

Fix root causes, not symptoms. Establish evidence, trace the failing path, identify
the root cause, search for the same defect pattern, implement the narrowest reliable
fix, centralize duplicated policy when safe, add regression coverage when practical,
and validate actual behavior.

Do not hide defects with arbitrary retries, sleeps, exception suppression, larger
timeouts, fallback success, or ignored exit codes unless explicitly designed.

## Security and destructive operations

Never expose or commit passwords, tokens, private keys, credentials, webhook
secrets, or production secrets. Do not weaken validation, authentication,
authorization, TLS, runtime/manifest integrity, path guards, or credential controls
to make a failing test pass.

Before delete/overwrite/restore/sync/scheduler/service operations, validate effective
scope and paths. Prefer isolated test locations and `try/finally` cleanup.

## Release lifecycle

- `developer` = development/prerelease.
- `master` = stable only.
- An accepted RC is immutable release evidence.
- Do not refactor, optimize, deduplicate, clean up, or change accepted RC runtime behavior in-place.
- Stable promotion and architectural refactoring are separate operations.
- Stable promotion must contain no runtime functional changes unless a new candidate will be validated.
- Stable becomes the behavioral baseline for the next development/modularization cycle.
- A `PROMOTE` verdict is evidence, not authorization to publish or deploy.

Detailed policy: `.claude/rules/06-release-lifecycle.md`

Use `stabilize-and-modularize` only as an explicitly invoked controlled workflow.

## Git

Do not commit, push, force-push, amend, reset, rebase, merge, tag, create a PR/release,
deploy, or delete branches unless the user explicitly requests the specific action.

Before any requested Git write, inspect status/diffs, exclude unrelated files,
check for secrets/temporary artifacts, and verify branch/HEAD/version/CI/acceptance
evidence when release-sensitive.

## Validation

Editing files is not completion. As applicable:

1. inspect the final diff;
2. run syntax/static checks;
3. run the narrowest relevant tests first;
4. run broader tests/self-tests when practical and safe;
5. verify PowerShell 5.1 compatibility;
6. verify no unintended/unrelated changes;
7. remove temporary diagnostics;
8. check that avoidable duplication did not increase;
9. check that entrypoints remain orchestration-focused and ownership is coherent.

Never claim a command, test, build, deployment, acceptance, or verification succeeded
unless it actually ran. State what remains unverified and why.

Distinguish runtime failures from test failures, acceptance-harness failures,
evidence-binding failures, and environmental failures. Do not patch runtime code
to compensate for defects that exist only in validation tooling.

## Communication

Be concise and technical. For completed work report what changed, why, validation
actually performed, remaining risks/unverified items, and architecture impact when relevant.

Distinguish verified facts, assumptions, recommendations, proposed actions, and
actions actually executed. Use the user's language unless project documentation
requires another language.

Detailed policy: `.claude/rules/08-documentation-language.md`

## Compact instructions

When context is compacted, preserve the user's exact outcome, implementation
decisions, modified files, commands/tests and results, unresolved failures/risks,
applicable project rules, release identity/state, and canonical architecture
ownership decisions. Do not re-decide established release/architecture decisions
without new evidence.

## Non-negotiable invariants

1. Reliability/data integrity before elegance.
2. Security and integrity controls fail closed unless explicitly designed otherwise.
3. Preserve Windows PowerShell 5.1 compatibility.
4. Keep root operational `.ps1` files as thin orchestration entrypoints.
5. No new monoliths; no monolith relocation into giant modules.
6. One canonical implementation per reusable responsibility; no avoidable copy/paste policy logic.
7. Preserve canonical configuration and exit-code ownership.
8. Refactoring is incremental, validated, and behavior-preserving by default.
9. Accepted RC identity remains immutable until stable promotion.
10. Stable promotion and runtime refactoring are never mixed.
11. Stable is the baseline for the next development cycle.
12. Git publication/release operations require explicit user authorization.
13. Editing code is not completion; validation evidence is required.
