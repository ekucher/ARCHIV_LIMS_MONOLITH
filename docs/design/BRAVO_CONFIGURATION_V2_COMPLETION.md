# BRAVO Configuration v2 — completion status and remaining scope

> **TARGET / NOT YET FULLY IMPLEMENTED.** This document describes the
> remaining work required to close FEAT-001 (`TODO_FEATURES.md`) /
> P3.1 (`ROADMAP.md`). It is a status and scope reference, not an
> implementation ticket, and it is intentionally shorter than a full
> implementation spec. It does not authorize any code change on its
> own.

## Current state (verified against `developer`)

P0 Configuration Foundation is completed and merged into `developer`
(`docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md`, CHANGELOG.md
"Не випущено (developer)" → "P0 Configuration Foundation (PR B/C)").

Completed in Foundation:

- canonical built-in defaults (`Get-BRAVODefaultConfiguration`);
- deterministic deep merge (`Merge-BRAVOConfiguration`) — recursive
  hashtable merge, **arrays fully replace the default array (not
  merged element-by-element)**, and **an explicit empty array `@()`
  is already accepted as a valid, intentional override** — verified
  directly in `modules/BRAVO.Configuration/BRAVO.Configuration.psm1`
  (merge-engine comments and array-handling branch);
- `maintenanceSettings.Limits.ExcludedDrives` default is **already**
  `@()` in the canonical built-in defaults — verified in the same
  module;
- raw configuration resolution (`Resolve-BRAVORawConfiguration`);
- derivation extraction (`Resolve-BRAVOConfigurationDerivation`) —
  discovery/derivation runs after merge, not before;
- optional `BRAVO.config` (no-config pipeline works from built-in
  defaults + `BRAVO.local.config` alone);
- explicit `-ConfigPath` vs AUTO intent contract, consistently applied
  across `BRAVO_SETUP.ps1`, Task Scheduler task definitions, and
  `BRAVO_CONFIGURATOR.ps1`;
- compatibility projection for legacy consumers;
- post-merge security-invariant re-validation (an effective
  configuration that weakens a security-critical setting through
  `BRAVO.local.config` is rejected, not silently accepted).

Effective precedence today:

```text
DEFAULT < BRAVO.config (optional) < BRAVO.local.config (optional)
```

`VERSION.json` currently declares `"configSchemaVersion": 1`.

### `BRAVO.local.config` today — restricted-language, but still evaluated

`BRAVO.local.config` is an optional data-shaped override file
(dot-path → value hashtable). Its production loader, verified in
`BRAVO_CONFIG_LOADER.ps1` (`Read-BRAVOLocalConfigurationOverrides`),
does this:

```powershell
$localOverrideScript = [scriptblock]::Create($localOverrideText)
$localOverrideScript.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false)
$localOverrideData = & $localOverrideScript
```

This means, precisely:

- the text is compiled to a `ScriptBlock`;
- `CheckRestrictedLanguage` with **empty** allowed-command and
  allowed-variable lists validates that the block contains no cmdlet
  calls, no function calls, and no variable/environment references —
  those are rejected before the block is ever invoked;
- **this is NOT a literal-only guarantee.** PowerShell's restricted
  data-language grammar still permits some expression forms even with
  empty allow-lists (for example arithmetic and range-style
  expressions). Because the validated `ScriptBlock` is subsequently
  invoked, any such permitted expression is *evaluated*, not merely
  extracted as a literal;
- **the validated `ScriptBlock` is then invoked** (`& $localOverrideScript`)
  to produce the hashtable.

So today's contract is: **restricted-language / data-shaped input —
no commands, no functions, no variable/environment references —
validated before evaluation, but the validated `ScriptBlock` is still
invoked, and the restricted grammar it accepts is not limited to pure
literals.** This is not the same guarantee as "parse without ever
executing" and it is not equivalent to an explicit literal-only AST
whitelist — it is a strong, narrow, empty-allowlist restricted
execution, not a non-executing AST-only extraction. It is a real and
effective control (arbitrary command/function/variable use is
rejected before it can run), but it is architecturally different from
the Configuration v2 target below, and this document must not blur
that distinction.

## Remaining gaps (what Config v2 still requires)

`BRAVO.config` itself is **not yet** a data-only format. It remains a
1300+ line executable PowerShell script (`param(ConfigRoot,
RuntimeRoot)`, `$global:` assignments, literal hashtable blocks mixed
with executable setup logic) — verified directly in `BRAVO.config`.
Only the *local override* layer (`BRAVO.local.config`) is currently
restricted-language/validated-before-invoke. The primary configuration
file is not, and even the local-override reader still invokes the
validated `ScriptBlock` rather than extracting data without ever
running it.

Not yet implemented:

- a fully DATA-only `BRAVO.config` format (no `param()`, no
  `$global:` assignment, no executable statements — literal data
  only), read by a parser that never invokes it as code;
- a true non-executing declarative parser (see "Safe declarative
  parser requirement" below) — today's restricted-language-then-invoke
  approach is a stepping stone, not the final target;
- a canonical `BRAVO.config.local` file name/contract as the long-term
  target machine-local override file (see naming note below — this
  does not exist in the runtime today);
- `configSchemaVersion = 2` and the schema/validation contract that
  goes with it (unknown-key rejection, type validation) enforced
  through the v2 declarative load path, with dedicated v2 regression
  coverage — the underlying merge semantics (array replace, explicit
  `@()`, the `ExcludedDrives` default) already exist in Foundation and
  do not need to be reinvented, only carried through and re-proven on
  the v2 load path;
- a migration path from the current executable `BRAVO.config` /
  restricted-language `BRAVO.local.config` pair to the v2 DATA-only
  pair;
- updater/upgrade preservation acceptance for the v2 format (an
  update must not silently discard or corrupt a v2 local override);
- the full Configuration v2 Definition-of-Done regression matrix
  (unknown keys, type mismatch, array replacement, nullable values,
  security-downgrade rejection, legacy-vs-v2 equivalence on control
  fixtures) re-run against the v2 declarative load path specifically —
  today's self-test already proves array-replace/explicit-`@()`/
  security-downgrade for the *current* Foundation merge engine; what's
  missing is proving the same contract survives the v2 parser/schema
  cutover, not inventing the contract itself.

## Target architecture

```text
Built-in defaults      (canonical, complete, part of the package — not a file)
    <
BRAVO.config            (optional, DATA-only, site/deployment override, configSchemaVersion 2)
    <
BRAVO.config.local      (optional, DATA-only, machine-local override, highest precedence)
```

Built-in defaults are the canonical, complete product/package
defaults — they are not "stored in `BRAVO.config`". `BRAVO.config` in
the v2 target is an **optional site/deployment-level override** layer
on top of those defaults, and `BRAVO.config.local` is a further
**optional machine-local override** layer with the highest precedence.
Do not describe target `BRAVO.config` as "package defaults", "the
primary configuration layer", or "package-versioned primary
configuration" — that would misrepresent where defaults actually live
and blur the site/deployment vs machine-local distinction between the
two override files.

Both configuration files are DATA, not CODE. The production runtime
must not execute either file as a PowerShell script.

### Safe declarative parser requirement (target — not today's behavior)

The v2 parser must:

1. parse PowerShell text to AST / an equivalent declarative
   representation;
2. validate only allowed literal data structures;
3. extract values as DATA;
4. **never invoke the resulting configuration `ScriptBlock`**;
5. never dot-source the configuration file;
6. never use `& $scriptBlock` (or equivalent invocation) for
   production Configuration v2 files;
7. fail closed on any unsupported syntax;
8. allow no cmdlets;
9. allow no function calls;
10. allow no variable/environment references;
11. allow no arbitrary expressions.

Today's `CheckRestrictedLanguage` + `& $scriptBlock` pattern used for
`BRAVO.local.config` gives useful precedent toward points 8–10 (no
cmdlets, no function/command calls, no variable/environment
references) but does **not** prove points 7 or 11, and **violates
point 4**:

- point 4 (never invoke) — **violated**: the validated block is
  invoked (`& $localOverrideScript`);
- point 7 (fail closed on any unsupported syntax, via the v2 parser's
  own literal/data-node whitelist) — **not proven** by this mechanism;
  `CheckRestrictedLanguage` enforces PowerShell's own restricted-
  language grammar, not a v2-specific fail-closed literal-AST
  whitelist;
- point 11 (no arbitrary expressions) — **not proven**: as noted
  above, the restricted grammar still permits some expression forms
  (e.g. arithmetic/range expressions), and those are evaluated on
  invocation.

It is not, itself, the Configuration v2 parser target, and it must
not be described as already satisfying the full 7–11 contract. It is
precedent that the no-command/no-function/no-variable restriction
half of the approach works; the v2 work is to additionally (a)
replace "validate then invoke" with "parse/extract without invoking"
(points 1–4) and (b) add an explicit fail-closed literal/data-node
whitelist that rejects arbitrary expression forms outright (points 7
and 11), not merely rely on PowerShell's restricted-language grammar.

A true non-executing AST-only precedent already exists elsewhere in
this codebase, for a narrower purpose:
`Test-BRAVORuntimeSecuritySettings` (`BRAVO_RUNTIME_GUARD.ps1`) reads
specific security-switch literals out of `BRAVO.config` via
`[Management.Automation.Language.Parser]::ParseFile` — AST parsing —
**without ever invoking `BRAVO.config`**, specifically because loading
`BRAVO.config` as code would mean executing arbitrary PowerShell
before the security check runs (see `SECURITY.md`, "Перемикачі
безпеки"). That function only extracts a small fixed set of literal
values for one purpose (pre-execution security-switch verification);
it is not a general-purpose configuration reader. It demonstrates the
non-invoking approach is already proven feasible in this codebase, not
that Config v2 itself is already built.

### `BRAVO.config` target (v2)

- an optional, DATA-only **site/deployment override** on top of
  built-in defaults — not where defaults are stored;
- carries `configSchemaVersion: 2`;
- remains optional (the no-config pipeline from built-in defaults
  must keep working, as it does today).

### `BRAVO.config.local` target (v2)

- an optional, DATA-only **machine-local override**, with the highest
  precedence of the three layers;
- dot-path → value (or equivalent structured v2 shape — exact shape is
  part of the schema v2 design, not fixed by this document);
- is the v2 successor to today's `BRAVO.local.config`, not a renaming
  of it in place, and not merely "site-local" — it is specifically the
  machine-local layer, distinct from the `BRAVO.config` site/deployment
  layer above it.

### Current vs target naming — do not confuse these

```text
CURRENT (production today):
    BRAVO.local.config
    BRAVO.local.config.example
    — restricted-language / data-shaped, validated before invoke
      (CheckRestrictedLanguage then & $scriptBlock — see above),
      already shipped, already documented in README.md /
      BRAVO_SETUP.md / OPERATIONS.md.

TARGET (Configuration v2, not yet implemented):
    BRAVO.config.local
    — does not exist in the runtime yet. Operator-facing documentation
      must keep instructing operators to use BRAVO.local.config until
      v2 ships and a migration path is documented.
```

Operator-facing documentation (`README.md`, `BRAVO_SETUP.md`,
`OPERATIONS.md`) must not be changed to reference
`BRAVO.config.local` as something an operator should create today.

### Legacy `BRAVO.local.config` transition

- `BRAVO.local.config` is not deleted the moment v2 ships; it remains
  readable/supported for a migration window;
- a migration procedure (dry-run, backup, rollback — mirroring the
  FEAT-001 target model in `TODO_FEATURES.md`) converts an existing
  `BRAVO.local.config` into the v2 shape;
- legacy and v2 must produce an equivalent effective configuration on
  control fixtures during the transition window.

### Schema v2

- explicit `configSchemaVersion: 2` marker, validated on load;
- unknown keys fail validation (fail-closed, not warn-and-ignore);
- invalid types fail validation;
- arrays fully replace the corresponding default array — **already
  the Foundation merge-engine behavior today**; schema v2 must carry
  this through the new declarative load path and re-prove it, not
  reimplement it;
- an explicit empty array (`@()`) is a valid, intentional override —
  **already accepted today** in the Foundation merge engine; schema
  v2 must preserve this and add v2-load-path regression coverage;
- `Limits.ExcludedDrives` default is `@()` — **already the built-in
  default today**; schema v2 must not regress this.

### Migration

- `BRAVO_CONFIG_MIGRATE.ps1` (or the equivalent canonical migration
  entrypoint, per repository entrypoint conventions) converts only
  explicitly-identified site-specific fields;
- discovered/generated values never become permanent overrides through
  migration;
- the pre-migration file is preserved as a backup, not deleted.

### Updater preservation

- an in-place update/upgrade of the toolkit must never silently
  overwrite, discard, or corrupt `BRAVO.config.local` (or, during the
  transition window, `BRAVO.local.config`);
- this must be covered by an explicit regression case, not just
  documented as an expectation.

### Regression / Definition-of-Done requirements

Before Configuration v2 can be marked complete in `ROADMAP.md`, the
following must exist and pass:

- unknown-key rejection test (new for v2);
- type-mismatch rejection test (new for v2);
- array-replace-not-merge test **on the v2 declarative load path**
  (the underlying semantic already exists and is already tested for
  today's Foundation merge engine — this item is about re-proving it
  survives the v2 parser cutover, not inventing it);
- nullable-value handling test (new for v2);
- explicit-empty-array-is-a-valid-override test **on the v2
  declarative load path** (same caveat as array-replace above);
- security-downgrade rejection test (mirrors the already-implemented
  P0 Foundation invariant, re-verified against the v2 schema path);
- legacy-vs-v2 equivalence test on at least one non-trivial control
  fixture;
- non-invocation proof: a test demonstrating that a malicious or
  malformed v2 configuration file cannot cause code execution even if
  it contains syntactically-plausible PowerShell beyond literal data —
  i.e. proving property 4 of the safe parser requirement, not just
  that invalid syntax is rejected;
- updater preservation acceptance (does not require real-server
  acceptance to be documented as "done" for the code-level regression,
  but real-server acceptance is required before this is described as
  production-proven, per repository validation policy).

### Recommended PR split

Mirrors the P0 Foundation precedent (PR A/B/C) in spirit, but adds a
dedicated migration PR and separates the safe parser from the loader
cutover so the highest-risk piece (never invoking untrusted config
text) can be reviewed and tested in isolation before anything depends
on it.

**Ordering constraint (why migration comes before cutover):** an
existing installation may still have an executable legacy `BRAVO.config`
at the moment any of these PRs lands. If the production loader is cut
over to the v2-only declarative parser (PR C below) before a supported
migration path exists, that installation's legacy `BRAVO.config` would
fail to load with no available conversion route — a merged, released
intermediate state that stops working for existing deployments. The
migration/compatibility work must therefore be available *before* the
production loader cutover, not after it.

**PR A — Safe declarative AST/data parser**

- safe non-executing parser;
- AST/data extraction;
- fail-closed syntax contract;
- parser unit tests, including the non-invocation proof above;
- no production loader cutover yet — existing `BRAVO.config` /
  `BRAVO.local.config` behavior is unchanged by this PR.

**PR B — Migration / compatibility preparation**

- migration entrypoint (`BRAVO_CONFIG_MIGRATE.ps1` or the repository's
  canonical equivalent);
- legacy executable `BRAVO.config` → v2 DATA-only conversion path;
- `BRAVO.local.config` → `BRAVO.config.local` conversion path;
- dry-run, backup, rollback;
- legacy-vs-v2 equivalence tests on control fixtures;
- exercises the PR A parser against real/representative legacy input
  without cutting the *production* loader over to it — the production
  loader still uses today's executable-`BRAVO.config`/restricted-
  language-`BRAVO.local.config` path in this PR;
- result: by the end of this PR, every installation that will later be
  cut over already has a supported, tested way to produce a valid v2
  configuration pair before PR C makes v2 the only path the loader
  accepts.

**PR C — Loader cutover + schema v2 + `BRAVO.config.local`**

- production loader switches to the PR A non-executing parser for the
  v2 path;
- DATA-only `BRAVO.config` (v2 format);
- canonical `BRAVO.config.local`;
- `configSchemaVersion = 2`;
- `DEFAULT < BRAVO.config < BRAVO.config.local` precedence;
- schema validation (unknown keys/types fail closed);
- re-proves array-replace, explicit `@()`, and the `ExcludedDrives`
  default on the new load path;
- safe to land because PR B already shipped the migration path — an
  installation still on legacy executable `BRAVO.config` has a
  supported, already-available conversion route before this cutover
  reaches it, instead of after.

**PR D — Updater / docs / final Definition-of-Done closure**

- updater preservation regression;
- operator-facing documentation updated to describe v2 as available
  (not yet as the only supported path);
- final regression matrix completed;
- real-server acceptance scheduled separately per repository
  validation policy;
- `ROADMAP.md` P3.1 only moves to DONE after this PR.

Do not combine the loader cutover (PR C) with the parser foundation
(PR A) in one change — that would make the highest-risk piece (parser
correctness/non-invocation) harder to review in isolation from the
lower-risk piece (schema/precedence wiring). Do not combine the loader
cutover (PR C) with the migration/compatibility work (PR B) either —
combining them would re-create the same unsafe intermediate state this
ordering is meant to avoid, by making it impossible to ship the
migration path as an independently verifiable, already-available step
before the cutover depends on it.

Each PR should independently pass the narrowest relevant self-test
subset plus a full `BRAVO_SELF_TEST.ps1` run before merge, and must be
green on the full required-check set before merge to `developer`/
`master` — `RELEASE_POLICY.md` (branch-protection section) lists the
current required checks: "Parser / BOM / JSON", "PSScriptAnalyzer",
"BRAVO_SELF_TEST.ps1", "Secret scanning (gitleaks)", "GitGuardian
Security Checks". (Do not cite `.claude/rules/*` here — that directory
is a local, untracked agent-tooling convention, not a committed
repository policy a contributor checking out this commit can read.)

## Final target contract (for reference — not yet fully implemented)

```text
Built-in defaults are complete (part of the package, not a file).
BRAVO.config is an optional site/deployment override.
BRAVO.config.local is an optional machine-local override.
DEFAULT < BRAVO.config < BRAVO.config.local
Configuration files are DATA, not CODE.
Production runtime never invokes Configuration v2 config files as code.
configSchemaVersion = 2
Limits.ExcludedDrives default = @()
Arrays replace, not merge.
Explicit @() is a valid override.
Unknown keys fail validation.
Invalid types fail validation.
Runtime derivation happens after raw merge.
Secrets remain outside config.
```

Of this contract, today the following already hold in production:

- built-in defaults are complete;
- `BRAVO.config` is optional;
- `DEFAULT < BRAVO.config < BRAVO.local.config` (current file name;
  the v2 file is `BRAVO.config.local`, not yet shipped);
- runtime derivation happens after raw merge;
- secrets remain outside config (Windows Credential Manager);
- `Limits.ExcludedDrives` default is `@()` — already true today, not
  a v2-only gap;
- arrays replace, not merge — already true today in the Foundation
  merge engine, not a v2-only gap;
- explicit `@()` is a valid override — already true today, not a
  v2-only gap.

What remains target-only (not yet true in production):

- `BRAVO.config` itself is DATA, not CODE (it is still an executable
  script today);
- the runtime never *invokes* configuration files as code — today's
  `BRAVO.local.config` reader validates-then-invokes, which is
  narrower than "never invoke";
- `configSchemaVersion = 2`;
- `BRAVO.config.local` exists as a shipped file name;
- unknown-key / type validation enforced through the v2 schema;
- the full v2 Definition-of-Done regression matrix, including the
  non-invocation proof, run against the v2 load path specifically.

## See also

- `docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md` — historical
  architecture gate for the completed P0 Foundation work.
- `TODO_FEATURES.md`, FEAT-001 — original feature request and detailed
  backlog notes.
- `ROADMAP.md`, P3.1 — canonical current priority/status.
- `CHANGELOG.md`, "Не випущено (developer)" — as-built record of what
  actually shipped for P0 Foundation, including deviations from the
  original design.
