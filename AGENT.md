# AGENT.md

Authoritative instructions for any AI coding agent working in this repository.
These rules override default agent behavior. Read this file at the start of every
session and follow it exactly.

## Principles

1. **Clean over compatible.** Prefer the correct end-state design over an
   incremental migration that preserves current internals. There is no old
   behavior to keep working: if a refactor is right, do it in one move and delete
   the old path. No deprecation shims, no dual code paths, no feature flags
   "for safety".

2. **Correctness and simplicity first.** Choose the simplest design that is
   actually correct. Remove special cases instead of accumulating them. Fewer
   moving parts, fewer producers/owners of a concern, a single source of truth.

3. **Practical, not speculative (YAGNI).** Build what the current problem needs.
   Do not add extensibility, config surface, or abstraction layers for
   hypothetical future requirements. Generalize only when a second concrete case
   exists.

4. **No migration-safety scaffolding.** Because nothing is deployed, skip work
   whose only purpose is staying green across a rollout: before/after parity
   tests, phased "keep it running between steps" sequencing, compatibility
   adapters. Phases remain useful as review/checkpoint boundaries.

5. **Don't over-engineer.** When a design starts adding layers to hedge risk that
   only exists for live systems, stop and pick the clean single-path version.
   Preserving an awkward boundary "to be safe" is the signal to simplify.

## Workflow

1. **Plan before code (when warranted).**
   - New features or PoCs start with a plan document in `docs/plan/`, named
     `YYYYMMDDNN_<slug>.md`, containing: phases, decision log, exit criteria,
     and out-of-scope items.
   - Bug fixes or isolated changes on top of an existing plan append to that
     plan instead of creating a new one.
   - Small, contained feature adjustments with obvious scope may skip a plan file.

2. **Phase-based implementation.** Work proceeds one phase at a time: implement
   the phase, self-test against the phase exit criteria using unit tests or other
   isolated local verification, then proceed once the phase passes locally.

3. **Commit discipline.**
   - One commit per phase (not per file, not per feature).
   - Message format: `<type>: <short description>`
     (e.g., `feat: add mcp approval flow`, `chore: project init`).
   - Never commit secrets, `.env` files, or `node_modules`.
   - Push after all phases are complete so workflows verify the full change.
   - Create the PR only after required push checks pass.

4. **Document decisions.** Record every non-obvious choice (library, pattern,
   architecture) in the active plan's Decision Log table so future sessions
   understand why.

5. **Environment variable discipline.** When adding, renaming, or removing an
   env var, update every required surface in the same change:
   `.env.example`, README deployment configuration,
   relevant GitHub workflow env blocks, tests/fixtures, and any active plan
   docs. Never leave required env vars documented only in code.