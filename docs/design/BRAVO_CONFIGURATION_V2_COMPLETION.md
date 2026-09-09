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
- post-merge security-invariant re-validation
  (`Test-BRAVOEffectiveSecurityInvariants` in `BRAVO_CONFIG_LOADER.ps1`):
  under the default `Enforce` policy, an effective configuration that
  weakens a security-critical setting through `BRAVO.local.config` is
  rejected, not silently accepted; the supported `Warn` mode
  (`BRAVO_RUNTIME_INTEGRITY_MODE=Warn`) and the explicit
  `BRAVO_ALLOW_WEAKENED_SECURITY=1` override both warn and continue
  instead of rejecting, and are not corner cases to gloss over — an
  operator running either mode is not getting unconditional rejection.

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
10. allow no variable/environment references, **except** the three
    PowerShell intrinsic literal constants `$true`, `$false`, and
    `$null` — these are required to represent Boolean and nullable
    configuration values, and must be recognized explicitly by
    AST/token identity as literal DATA values, never resolved from
    session/environment state. All other variable forms remain
    rejected: `$env:...`, `$global:...`, `$script:...`, `$local:...`,
    arbitrary `$foo`, `${...}`, and any other variable reference;
11. allow no arbitrary expressions.

Today's `CheckRestrictedLanguage` + `& $scriptBlock` pattern used for
`BRAVO.local.config` gives useful precedent toward points 8–10 (no
cmdlets, no function/command calls, no arbitrary variable/environment
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
- a migration procedure (dry-run, staged conversion — mirroring the
  FEAT-001 target model in `TODO_FEATURES.md`) converts an existing
  `BRAVO.local.config` into a staged, inactive `BRAVO.config.local`
  candidate (see "Migration: conversion vs activation" below); backup
  and rollback apply to the later activation transaction, not to
  producing the staged candidate itself;
- legacy and v2 must produce an equivalent effective configuration on
  control fixtures during the transition window.

### Legacy/v2 security boundary during transition

While the loader accepts both formats during the migration window, the
two paths must stay strictly separated:

- a v2-shaped file (`configSchemaVersion: 2`) is only ever parsed and
  extracted as DATA — it is never invoked as code, including when it
  fails validation;
- a file using the legacy format uses only the existing, already-
  reviewed legacy compatibility path (today's executable
  `BRAVO.config` / restricted-language-then-invoke
  `BRAVO.local.config`);
- an invalid or malformed v2 file **fails closed** — it is rejected,
  and must never be silently retried through the legacy executable
  path. A file does not become executable merely because its v2
  parsing failed.

### Active configuration-set mode (format detection contract)

The loader may classify individual files, but before merging or
invoking any layer it must determine **one coherent active
configuration mode** for the installation. It must never
independently choose legacy for one active layer and v2 for another
and silently merge the mixed result.

**Format detection is always non-executing.** Classifying
`BRAVO.config` as legacy or v2 must never execute the file to
discover its format — detection uses static inspection (e.g. an
explicit `configSchemaVersion` marker found via AST/non-executing
parse), consistent with the fail-closed rule above: an invalid v2
file is never silently retried as legacy execution, and a file is
never executed merely to determine what it is.

**Supported active modes:**

| # | `BRAVO.config` | `BRAVO.local.config` | `BRAVO.config.local` | Result | Precedence |
|---|---|---|---|---|---|
| A | absent | absent | absent | SUPPORTED — built-in-only (format-neutral) | `DEFAULT` |
| B | recognized legacy | absent | absent | SUPPORTED — LEGACY MODE | current legacy precedence, unchanged |
| C | recognized legacy | present | absent | SUPPORTED — LEGACY MODE | current legacy precedence, unchanged during the migration window |
| D | absent | present | absent | SUPPORTED — LEGACY MODE (already-supported built-in + local override path) | `DEFAULT < BRAVO.local.config` |
| E | valid v2 | absent | absent | SUPPORTED — V2 MODE | `DEFAULT < BRAVO.config` |
| F | valid v2 | absent | valid v2 | SUPPORTED — V2 MODE | `DEFAULT < BRAVO.config < BRAVO.config.local` |
| G | absent | absent | valid v2 | SUPPORTED — V2 MODE (site-level override remains optional) | `DEFAULT < BRAVO.config.local` |

**Explicitly forbidden mixed modes — fail closed, no implicit precedence:**

| Combination | Result |
|---|---|
| legacy `BRAVO.config` + `BRAVO.config.local` | UNSUPPORTED MIXED MODE — FAIL CLOSED. Never execute the legacy primary and then merge a v2 local override. |
| v2 `BRAVO.config` + `BRAVO.local.config` | UNSUPPORTED MIXED MODE — FAIL CLOSED. Never parse the v2 primary and then invoke a legacy local override. |
| `BRAVO.local.config` + `BRAVO.config.local` both present | CONFLICT — FAIL CLOSED. There is no implicit "new filename wins", "legacy filename wins", or "newest file wins" rule; the operator/updater must explicitly complete migration or roll back. |
| `BRAVO.config` claims v2 (`configSchemaVersion: 2`) but fails v2 validation | FAIL CLOSED — never falls back to legacy execution (see "Legacy/v2 security boundary during transition" above). |
| `BRAVO.config` format is unknown/ambiguous | FAIL CLOSED. |

`BRAVO.local.config` is the legacy-only machine-local filename during
the transition window; `BRAVO.config.local` is the v2-only
machine-local filename. If both are present this is a configuration
**conflict**, not a precedence question — the two filenames are
format-specific, not synonyms with an implicit tie-break.

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

### Migration: conversion vs activation

Migration has two distinct stages that must not be conflated:

```text
CONVERSION:
legacy config -> validated staged v2 candidate

ACTIVATION:
staged v2 candidate -> active production v2 configuration
```

**Conversion / staging (available starting PR B):**

- `BRAVO_CONFIG_MIGRATE.ps1` (or the equivalent canonical migration
  entrypoint, per repository entrypoint conventions) converts only
  explicitly-identified site-specific fields;
- discovered/generated values never become permanent overrides through
  migration;
- the source legacy file(s) are read but never modified by conversion;
- the converted candidate is written to an inactive staging
  location — a pathname the current production loader does not
  consume — never to the active `BRAVO.config` / `BRAVO.config.local`
  production filenames;
- the staged candidate is validated with the PR A non-executing parser
  and compared against the legacy effective configuration for
  equivalence before it is treated as a valid candidate;
- a staged candidate may be discarded and regenerated at any time
  without affecting the active installation; the pre-migration source
  file is left untouched, not merely "preserved as a backup";
- conversion alone never changes what the production loader reads.

**Activation (available starting PR D, explicitly gated — see
"Migration activation and rollback" below):**

- promotes a validated staged candidate into the active configuration
  at the effective active primary path (see "Effective active primary
  path" below) — not necessarily the fixed `BRAVO.config` /
  `BRAVO.config.local` filenames;
- requires the PR C dual-format reader to already be present in the
  running installation;
- is a distinct, later, explicitly-gated operation — conversion alone
  (PR B) grants no ability to activate;
- the staged candidate metadata records enough identity to prevent
  activation against the wrong target, at minimum: AUTO-vs-EXPLICIT
  `-ConfigPath` intent, the exact resolved effective primary path, the
  effective configuration directory, the legacy local path if present,
  the target v2 local path if applicable, a source baseline/hash (or
  equivalent drift identity), and a candidate identity/hash — exact
  field names are an implementation detail, not fixed by this
  document.

### Effective active primary path (AUTO vs EXPLICIT)

Migration and activation must be defined in terms of the **effective
active primary configuration path**, not an assumption that the
primary is always `<ConfigRoot>\BRAVO.config`. The existing
`-ConfigPath` AUTO/EXPLICIT contract (`BRAVO_SETUP.ps1`, Task
Scheduler task definitions, `BRAVO_CONFIGURATOR.ps1`) already
distinguishes two modes, and migration must preserve that distinction:

**AUTO mode** — the operator did not explicitly supply `-ConfigPath`:

```text
effective primary path = <ConfigRoot>\BRAVO.config
```

if a primary override exists at all (it remains optional).

**EXPLICIT mode** — the operator explicitly supplied
`-ConfigPath <path>` (for example `C:\BRAVO\CONFIGS\SERVER1.config`):
the exact resolved path is operator intent and **must remain the
active primary path across migration**. It must not silently become
`<RuntimeRoot>\BRAVO.config` or `<ConfigRoot>\BRAVO.config`.

**Preferred canonical activation model — preserve the path, change the
format:**

```text
legacy data/code at exact effective path
    -> migration ->
v2 DATA at the SAME exact effective path
```

The filename/path does not determine legacy vs v2 — format/schema
detection does (see "Active configuration-set mode" above), and PR C
is already defined as a dual-format reader. Activation therefore
should normally **not** require retargeting scheduled tasks or
launchers. Guiding principle: **migration changes the format/content
of the active configuration, not the operator's explicit primary-path
intent.**

The v2 machine-local override follows the same effective-configuration
directory as today: for an explicit primary path
`C:\BRAVO\CONFIGS\SERVER1.config`, the corresponding
`BRAVO.config.local` (when used) resolves from
`C:\BRAVO\CONFIGS\BRAVO.config.local`, per the v2 local-filename
contract — it is not silently relocated to `RuntimeRoot`. For AUTO/
no-primary mode, the documented `ConfigRoot`-based behavior applies.
`RuntimeRoot` is not necessarily `ConfigRoot`, and `ConfigRoot` is not
necessarily the directory implied by the package location; migration
must preserve the effective configuration location.

After activation, every existing persisted consumer must still resolve
the active v2 configuration: a scheduled task's exact `-ConfigPath`, a
manual launcher's exact `-ConfigPath`, and any other persisted
consumer remain unchanged, because the same effective primary path now
contains v2 DATA. If a future implementation instead chooses path
retargeting, that is a different, higher-risk design and MUST
atomically update every persisted consumer inside the rollback-
protected activation transaction (see "Migration activation and
rollback" below) — retargeting is not the preferred/default design.

### Updater preservation

- an in-place update/upgrade of the toolkit must never silently
  overwrite, discard, or corrupt either v2 override file —
  `BRAVO.config` (site/deployment override) or `BRAVO.config.local`
  (machine-local override) — nor, during the transition window, the
  legacy `BRAVO.local.config`. Both v2 files are user-owned override
  layers, not package-provided content, and the package must never
  reset them to shipped defaults on update;
- a legacy executable `BRAVO.config` must never be silently replaced
  by a packaged v2 `BRAVO.config` before backup/migration/compatibility
  handling has safely dealt with it — an update must not overwrite a
  site's existing configuration file merely because the package ships
  a new default file;
- this must be covered by explicit regression cases, not just
  documented as an expectation, including at minimum:
  1. a v2 `BRAVO.config` survives an update unchanged;
  2. a v2 `BRAVO.config.local` survives an update unchanged;
  3. a legacy `BRAVO.local.config` survives the transition/update
     unchanged until explicitly migrated;
  4. a legacy executable `BRAVO.config` is never silently replaced by
     a package-provided v2 file.

Routine in-place package updates (not a migration activation) never
change the active configuration-set mode; the backup/rollback
transaction described in "Migration activation and rollback" below
applies specifically to migration activation, not to every update.

### Migration activation and rollback (PR D)

Activation promotes a validated staged v2 candidate (see "Migration:
conversion vs activation" above) into the live configuration set, at
the effective active primary path (see "Effective active primary
path" above) — it does not assume the primary is always
`<ConfigRoot>\BRAVO.config`. It operates on the complete configuration
set as one transaction, never file-by-file best effort, and must
survive abrupt interruption (process kill, host crash, reboot, power
loss), not only caught in-process failures.

**Activation path guard (runs before anything else):** before
changing any active file, activation verifies:

- the current effective primary path still matches the staged
  migration target's recorded effective primary path;
- AUTO/EXPLICIT `-ConfigPath` intent has not changed since staging;
- the source legacy configuration has not drifted since the candidate
  was generated (baseline/hash match);
- the expected local-configuration identity has not changed;
- the candidate belongs to this exact activation target.

Any mismatch **fails closed** — activation does not proceed, and the
operator must regenerate/revalidate the candidate.

**Durable write-ahead activation journal.** Because a caught
`try`/`catch`/`finally` cannot protect against process termination,
host crash, reboot, or power loss between file mutations, activation
uses a durable, write-ahead journal stored outside the files being
promoted, in a protected runtime/state location (the exact permanent
path is an implementation detail for the canonical migration-state
root, not fixed by this document). The journal conceptually records:
an activation ID; target host/installation identity; AUTO/EXPLICIT
`-ConfigPath` intent; the exact active primary path; active local-path
state; backup-set identity; candidate-set identity; the current
activation phase/state; and timestamps/version/schema as appropriate.
Exact field names are an implementation detail.

**Required transaction order:**

1. validate the current active legacy set;
2. validate the complete staged v2 candidate;
3. run the activation path guard above;
4. create a backup of the complete active set, and verify the backup;
5. durably create the activation journal — **if journal creation or
   persistence fails, no active file may change**;
6. only then begin promoting candidate files, recording a write-ahead
   phase transition before each destructive step (for example:
   Prepared, PrimaryPromotionStarted, PrimaryPromoted,
   LocalPromotionStarted, LocalPromoted,
   LegacyLocalRetirementStarted, Verifying, Committed — exact phase
   names are implementation detail, the state-machine semantics are
   required);
7. ensure no conflicting legacy/v2 local filenames remain active (see
   "Active configuration-set mode" above — activation must not leave a
   forbidden mixed mode in place);
8. load through the v2 path;
9. verify effective-configuration equivalence and required invariants,
   including that persisted consumers (scheduled tasks, launchers)
   still resolve a valid configuration at the effective primary path;
10. mark migration adoption confirmed, write the `Committed` journal
    phase, and only then permit deferred cleanup of old migration
    artifacts/backups per policy — recovery evidence is not erased
    prematurely.

**Rollback.** If any step fails — whether caught or discovered on
recovery — the complete previous configuration set is restored:
rollback is set-level, restoring one coherent prior mode (for example,
"legacy primary + legacy local" is restored together if that was the
pre-migration state), never a partial mixed result. A rollback must
never leave both `BRAVO.local.config` and `BRAVO.config.local` active
at once, unless one of them resides only in an explicitly inactive
backup/staging area.

**Crash/reboot recovery is independent of process memory.** Recovery
must work correctly from a brand-new process and must not depend on
`catch`/`finally`, in-memory variables, or the original PowerShell
process still running. Before the ordinary configuration-mode
classification/merge path consumes active files, a migration recovery
preflight checks for an incomplete activation journal; if one exists,
recovery runs first — the normal loader must never simply encounter a
half-promoted mixed configuration and treat it as an ordinary operator
error. Policy is **rollback-first**: for any incomplete/uncommitted
activation, the complete previous active configuration set is restored
from the verified backup, then the restored set is revalidated as one
coherent supported mode (see "Active configuration-set mode" above).
Only after recovery completes may normal loading continue.

**Recovery failure fails closed.** If recovery cannot safely restore
the prior complete configuration set, it fails closed: it does not
guess precedence, does not delete the journal or backups, does not
partially continue, surfaces a specific migration-recovery error, and
preserves forensic/recovery evidence.

**Single writer.** Activation and recovery must not run concurrently.
One installation may have at most one active migration transaction at
a time, using the repository's canonical machine-wide locking/state
approach when implemented; if another activation/recovery already owns
the transaction, a new one fails closed as busy rather than starting a
second migration.

**Recovery is idempotent.** Recovery must be safe to run repeatedly —
if recovery itself is interrupted, the next recovery invocation must
still converge safely, and no repeated recovery attempt may corrupt
the last verified backup.

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
- fail-closed-no-fallback proof: a test demonstrating that a file
  declaring `configSchemaVersion: 2` that fails v2 validation is
  rejected outright and never silently falls back to the legacy
  executable loader;
- active-configuration-set-mode coverage (see "Active
  configuration-set mode" above), covering all seven supported
  combinations and all five fail-closed combinations enumerated there;
- migration staging/activation coverage:
  - PR B staging leaves every live configuration file byte-for-byte
    unchanged;
  - a staged v2 candidate is not discoverable by the legacy production
    loader;
  - PR D activation promotes a complete, coherent v2 set;
  - an activation failure restores the complete previous legacy set;
  - rollback cannot leave both local filenames active at once;
  - invalid v2 never falls back to legacy execution, re-verified at
    the configuration-set level, not just the single-file level;
  - EXPLICIT external `-ConfigPath` migration preserves the exact
    path; a scheduled task command line containing
    `-ConfigPath "<explicit path>"` is unchanged after successful
    path-preserving activation; a manual launcher using an explicit
    effective config path remains valid; v2 primary is loaded from
    that exact explicit path after activation; the v2 local override
    is resolved beside the effective configuration per the v2
    local-file contract;
  - activation rejects a staged candidate when the effective
    `-ConfigPath` or source baseline changed after staging (the
    activation path guard above);
  - AUTO mode remains canonical and unaffected by the EXPLICIT-path
    guard;
  - interruption/crash-recovery coverage: abrupt interruption injected
    (1) after journal creation but before any active-file mutation,
    (2) after primary promotion but before local promotion, (3) during
    or after v2 local promotion, (4) before/after legacy local
    retirement, (5) after all file promotions but before v2
    verification, (6) after verification but before the `Committed`
    marker, and (7) while updating the durable journal itself — after
    a simulated restart/recovery each case must prove: recovery does
    not depend on old process memory; one coherent supported
    configuration mode is restored; no mixed legacy/v2 mode becomes
    visible to normal loading; the explicit effective `-ConfigPath` is
    preserved; scheduled/persisted consumers still target a valid
    configuration; backup/journal remain if recovery fails; and
    successful recovery is idempotent;
  - recovery idempotency: recovery itself is interrupted, and the next
    recovery invocation still converges safely without corrupting the
    last verified backup;
- updater preservation acceptance (does not require real-server
  acceptance to be documented as "done" for the code-level regression,
  but real-server acceptance is required before this is described as
  production-proven, per repository validation policy).

### Recommended PR split

Mirrors the P0 Foundation precedent (PR A/B/C) in spirit, but adds a
dedicated migration PR, separates the safe parser from the loader
cutover, and splits "v2 becomes available" from "legacy is finally
removed" into two separately-gated stages — so the highest-risk pieces
(never invoking untrusted config text, and stranding an unmigrated
installation) can each be reviewed and tested in isolation before
anything depends on them.

**Ordering constraint (why migration comes before cutover):** an
existing installation may still have an executable legacy `BRAVO.config`
at the moment any of these PRs lands. If the production loader stopped
accepting the legacy format (final cutover, see PR E below) before a
supported migration path exists, that installation's legacy
`BRAVO.config` would fail to load with no available conversion route —
a merged, released intermediate state that stops working for existing
deployments. The migration/compatibility work must therefore be
available *before* the final cutover, not after it.

**Migration availability is not migration completion:** shipping PR B
makes a migration path *available*; it does not prove any specific
deployed installation has actually run it. A direct upgrade to a
release containing PR C or later can still encounter a server whose
primary configuration file is the legacy executable `BRAVO.config`,
regardless of how long PR B has existed. The loader must therefore
continue to accept and correctly load the legacy format itself,
through explicit format/schema detection, for as long as the migration
window is open — until the separately-gated final cutover (PR E)
removes legacy support, not merely because conversion tooling exists
upstream. Nor does PR B *activate* anything: it produces staged,
inactive v2 candidates only (see "Migration: conversion vs
activation" above) — an installation is not migrated merely because a
candidate has been generated for it; it is migrated only after PR D's
gated activation succeeds.

**PR A — Safe declarative AST/data parser**

- safe non-executing parser;
- AST/data extraction;
- fail-closed syntax contract;
- parser unit tests, including the non-invocation proof above;
- no production loader cutover yet — existing `BRAVO.config` /
  `BRAVO.local.config` behavior is unchanged by this PR.

**PR B — Migration / compatibility preparation (inactive staging only)**

- migration entrypoint (`BRAVO_CONFIG_MIGRATE.ps1` or the repository's
  canonical equivalent);
- legacy executable `BRAVO.config` → v2 DATA-only conversion path,
  writing to an inactive staging location only — never to the active
  `BRAVO.config` filename;
- `BRAVO.local.config` → `BRAVO.config.local` conversion path, writing
  to an inactive staging location only — never to the active
  `BRAVO.config.local` filename;
- dry-run, staged-candidate validation, discard/regenerate;
- legacy-vs-v2 equivalence tests on control fixtures, run against the
  staged candidate;
- exercises the PR A parser against real/representative legacy input
  without cutting the *production* loader over to it and without
  activating the staged candidate — the production loader still uses
  today's executable-`BRAVO.config`/restricted-language-
  `BRAVO.local.config` path in this PR, unchanged and untouched;
- **hard invariant: PR B has no activation/promote capability.** It
  cannot replace, overwrite, or rename staged output into the active
  `BRAVO.config` / `BRAVO.config.local` filenames, and exposes no
  command that can make the staged pair live. See "Migration:
  conversion vs activation" above;
- because PR B never touches the active configuration set, production
  backup/rollback is not required merely to produce or discard a
  staged candidate — that transaction belongs to migration activation
  (PR D, see "Migration activation and rollback" above);
- result: by the end of this PR, every installation that will later be
  cut over already has a supported, tested way to *produce and
  validate* a v2 migration candidate — entirely inactive — before PR C
  introduces the v2 load path, and well before PR D's gated activation
  or PR E's final cutover removes legacy support entirely.

**PR C — v2 loader introduction (dual-format, not a v2-only cutover)**

- production loader gains a non-executing v2 declarative load path
  (via the PR A parser) *in addition to*, not instead of, the existing
  legacy load path — this PR introduces v2 support, it does not remove
  legacy support;
- explicit, deterministic format/schema detection selects the v2
  parser for a v2-shaped file and the existing legacy path for an
  unconverted installation — the loader does not assume every
  installation has migrated merely because PR B shipped a migration
  tool;
- DATA-only `BRAVO.config` (v2 format) and canonical
  `BRAVO.config.local` become valid, recognized inputs;
- `configSchemaVersion = 2`;
- `DEFAULT < BRAVO.config < BRAVO.config.local` precedence for
  installations already on v2;
- schema validation (unknown keys/types fail closed) for v2 input;
- re-proves array-replace, explicit `@()`, and the `ExcludedDrives`
  default on the new load path;
- **fail-closed rule:** a file that declares itself v2
  (`configSchemaVersion: 2`) but fails v2 validation must be rejected
  outright — it must never silently fall back to the legacy executable
  loader. Format selection is explicit and deterministic; a v2 parse
  failure is never treated as "try legacy instead";
- legacy executable `BRAVO.config` / restricted-language
  `BRAVO.local.config` remain supported through the loader's legacy
  path during the migration window — PR C does not make v2 "the only
  accepted loader path"; that is a separate, later gate (see PR E).

**PR D — Path-preserving activation/adoption gate + durable crash recovery + updater preservation + docs/DoD prep**

- migration activation logic implementing the atomic promote/verify/
  rollback transaction (see "Migration activation and rollback"
  above), including the activation path guard, the durable write-ahead
  journal, and rollback-first crash/reboot recovery independent of
  process memory — this is the first PR authorized to move a staged v2
  candidate into the active configuration set;
- activation preserves the effective active primary path (AUTO or
  EXPLICIT `-ConfigPath`, see "Effective active primary path" above)
  rather than assuming `<ConfigRoot>\BRAVO.config`, so persisted
  consumers (scheduled tasks, launchers) remain valid without
  retargeting;
- updater preservation regression (see "Updater preservation" above —
  covers `BRAVO.config`, `BRAVO.config.local`, and legacy
  `BRAVO.local.config`);
- operator-facing documentation updated to describe v2 as available
  (not yet as the only supported path);
- final regression matrix completed, including the non-invocation
  proof, the fail-closed-no-fallback-on-invalid-v2 case, and the
  active-configuration-set-mode matrix (see "Active configuration-set
  mode" above and the regression list above);
- a documented, testable mechanism for confirming migration adoption —
  for example a combination of: confirmed conversion state, an updater
  preflight that safely migrates before activating the new runtime, a
  fail-safe automatic migration using the non-executing migration
  parser, or an explicit deployment/migration marker with rollback;
- real-server acceptance scheduled separately per repository
  validation policy;
- `ROADMAP.md` P3.1 remains IN PROGRESS after this PR — dual-format
  support is complete and adoption-tracking exists, but the legacy
  executable loader has not yet been removed.

**PR E — Final legacy-loader removal / v2-only production cutover**

- production runtime stops accepting the legacy executable
  `BRAVO.config` / restricted-language `BRAVO.local.config` load path
  entirely;
- may land only after PR D proves path-preserving activation, durable
  crash recovery, explicit `-ConfigPath` preservation, and migration
  adoption confirmation, all satisfied and regression-tested — simply
  having the migration executable on disk (PR B) or the dual-format
  loader (PR C) is not sufficient justification on its own;
- after this PR, production runtime must never execute `BRAVO.config`
  or `BRAVO.config.local` as PowerShell code, and no legacy load path
  remains;
- `ROADMAP.md` P3.1 only moves to DONE after this PR.

Do not combine the v2 loader introduction (PR C) with the parser
foundation (PR A) in one change — that would make the highest-risk
piece (parser correctness/non-invocation) harder to review in
isolation from the lower-risk piece (schema/precedence wiring). Do not
combine PR C with the migration/compatibility work (PR B) either —
combining them would re-create the same unsafe intermediate state this
ordering is meant to avoid, by making it impossible to ship the
migration path as an independently verifiable, already-available step
before v2 support depends on it. Do not combine the migration/
adoption-gating work (PR D) with the final legacy-loader removal
(PR E) either — collapsing them would remove the separately-testable
adoption gate this split exists to provide, and would make "migration
tooling exists" indistinguishable from "this installation has
migrated," which is exactly the conflation this document must avoid.

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
