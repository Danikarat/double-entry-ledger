# Ledger API: Project Documentation

A double-entry ledger API written in Go (Gin) on Microsoft SQL Server. It is a portfolio-grade learning project: the product is real enough to be credible, and the main goal is fluency in **MSSQL** and **Go**.

## Reading order

| # | Document | Purpose | Read it when |
|---|----------|---------|--------------|
| 1 | [01-PRD.md](01-PRD.md) | What we are building and why; scope; milestones; success metrics | Before anything else |
| 2 | [02-SRS.md](02-SRS.md) | Numbered functional and non-functional requirements, invariants, error model | While implementing any feature |
| 3 | [03-architecture-and-adrs.md](03-architecture-and-adrs.md) | System design, concurrency strategy, code layout, and every major decision as an ADR | Before designing a package or query |
| 4 | [04-data-model.md](04-data-model.md) | Full target T-SQL schema, indexes, constraints, canonical queries | When writing migrations or SQL |
| 5 | [openapi.yaml](openapi.yaml) | HTTP contract for the final (M5) API | When writing handlers or tests |
| 6 | [05-delivery-plan.md](05-delivery-plan.md) | Five milestones, tasks, acceptance criteria, test cases | Every working session |

## Conventions

- **Requirement IDs** look like `FR-TRF-012`, `NFR-PERF-002`, `INV-3`, `ADR-007`, `TC-M2-04`. Use them in commit messages, PR titles, test names and code comments (for example `// FR-IDM-003`).
- **Source of truth order** when documents disagree: SRS, then Data model, then OpenAPI, then Architecture. Fix the lower-priority document in the same change.
- **Milestone tags** (`M1` to `M5`) mark when a requirement, table or endpoint lands. Do not build ahead of the current milestone, except where a document says a column is created early.
- **Money is always an integer in minor units.** There is no floating point anywhere in money paths (INV-9).
- **Definition of done** for any task: requirement implemented, tests written (with the TC IDs from the delivery plan), invariant checker green, docs updated if behavior changed.

## Using these documents with a coding assistant

Give the assistant `docs/` as context, name the milestone you are on, and ask for one task from `05-delivery-plan.md` at a time. Ask it to cite requirement IDs in its changes. Review SQL by hand: locking and isolation behavior is the learning goal, so do not accept SQL you cannot explain.
