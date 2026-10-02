# Reviewer lenses

Use only the lenses the change touches. The example questions are templates: adapt them to the diff instead of pasting them.

## Index
1. Purpose & scope 2. Correctness & edge cases 3. Design & responsibility 4. Tests 5. Types & API contracts
6. Performance 7. Security 8. Operations & incidents 9. Compatibility & migration 10. UI/UX 11. Non-engineers (PM / leadership)

## 1. Purpose & scope
- Why now? Which issue or background?
- What unrelated changes are in this PR? Can they be split out?
- What was deliberately left out? (explicit out-of-scope)

## 2. Correctness & edge cases
- null/undefined/empty/0/negative/huge input?
- Concurrency, double submit, retries?
- Time zones, date boundaries, locales
- Partial state left behind on error?

## 3. Design & responsibility
- Does this belong in this layer / file?
- Why build new instead of using the existing similar mechanism? (ties to the rejected-alternatives ledger)
- Premature abstraction? Or growing copy-paste?

## 4. Tests
- Why are there no / no changed tests?
- Do the tests check behaviour rather than implementation?
- Has a case that should fail actually been seen failing?
- Were CI and local checks (lint / typecheck / tests) run?

## 5. Types & API contracts
- Are public type / signature changes reflected at every call site? (check `← outside diff` in the summary)
- Why is each `as` / `any` / non-null assertion safe?
- Does the API response or DB schema change shape? Are clients updated?

## 6. Performance
- I/O inside loops, N+1, unnecessary re-renders
- What happens at 100× the data?
- Bundle size impact of new dependencies

## 7. Security
- Input validation and authorization on the server side?
- No PII or tokens in logs?
- Maintenance status and license of new dependencies

## 8. Operations & incidents
- How will anyone notice a problem? (logs, metrics)
- Feature flag to switch it off? Rollback procedure?
- If there is a data migration, is it reversible?

## 9. Compatibility & migration
- Old clients, caches, existing data
- Deploy-order constraints (DB → API → frontend …)

## 10. UI/UX
- Loading, error and empty states
- Accessibility (keyboard, labels)
- Narrow viewports

## 11. Non-engineers (PM / leadership)
- What changes for the user?
- What is the risk? When can it ship?
- One sentence, no jargon?
