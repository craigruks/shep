# Dependency Update

## Contract
You will produce: updated dependencies with passing tests and no breaking changes.
You will NOT: change application logic or refactor code unrelated to the update.
The output enables: staying current on dependencies without manual upgrade effort.

## Validation
Run `pnpm install && pnpm exec vitest run` and ensure all tests pass before committing.

## Scope
Update the specified packages. Fix any type errors or API changes introduced by the update.
