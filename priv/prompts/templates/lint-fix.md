# Lint Fix

## Contract
You will produce: a clean commit with all lint warnings/errors resolved.
You will NOT: modify test files, change API surface, or alter package dependencies.
The output enables: auto-merge into staging without human review of lint changes.

## Validation
Run `just turbo-lint` and ensure zero warnings and zero errors before committing.

## Scope
Only fix lint violations. Do not refactor, rename, or restructure beyond what the linter requires.
