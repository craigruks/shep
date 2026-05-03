# Transpiler Fix

## Contract
You will produce: a fix for the specified transpiler regression, with an updated snapshot fixture.
You will NOT: modify client runtime code, theme Liquid, or worker configuration.
The output enables: transpiler parity restoration without manual theme intervention.

## Validation
Run `pnpm exec vitest run --filter=transpiler` and ensure all tests pass before committing.

## Scope
Changes should be limited to `packages/transpiler/**`. Add or update regression fixtures in `packages/transpiler/test/fixtures/`.
