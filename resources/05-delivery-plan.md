# Delivery Plan: Ledger API

Version 1.0. Five milestones, ordered by risk. Each ends with a working, tested, demonstrable API; you can stop after any of them. No calendar dates are set; sizes are relative (S, M, L).

## 0. Working agreements

- **One task at a time.** Branch per task (`m2/t04-job-claim`), small commits, a PR even when working alone.
- **Cite IDs.** Commit messages and test names carry requirement and test-case IDs, for example `feat(transfers): hold on submission [FR-HLD-001, TC-M2-02]`.
- **Invariants gate every merge.** CI runs the invariant checker after the integration and concurrency suites.
- **Learn on purpose.** Each milestone has a "learning log" deliverable: a short note in `docs/notes/` recording what you tried, what the plan or lock behavior showed, and what surprised you.
- **Do not build ahead.** Columns noted as "created early" in the data model are the only exception.
- **Definition of done (task):** requirement implemented, listed test cases written and green, invariant checker green, docs updated if behavior or contract changed, learning log updated if the task was a learning task.
- **Definition of done (milestone):** all milestone requirements pass their acceptance criteria, CI green, `docs/` consistent, tag `vX` (`m1`, `m2`, and so on) pushed.

## 1. Test environment (applies to every milestone)

- Integration tests use testcontainers-go with a SQL Server container (`mcr.microsoft.com/mssql/server`, version 2022 or later; the container requires accepting the EULA through its `ACCEPT_EULA=Y` environment setting). One container per test package; each test creates its own accounts and currencies to avoid cross-test interference, or truncates between tests.
- Test setup applies the real goose migrations.
- Helpers in `internal/testutil`: `NewDB(t)`, `NewAccount(t, currency, opening)` (funds via a deposit), `RunInvariants(t, db)` (executes the SRS/data-model invariant queries and fails on any row), `WaitForTerminal(t, transferID)`.
- Concurrency tests use `sync.WaitGroup` plus a start barrier (a closed channel) so goroutines begin together; always run with `-race`.
- The clock and the rate provider are injected so tests are deterministic.

---

## M1: Core ledger (size L)

**Goal:** prove the posting and locking foundation synchronously: accounts, funding, same-currency transfers, idempotency, auth.
**Requirements:** FR-AUTH-001 to 004, FR-CUR-001 to 003, FR-ACC-001 to 005, FR-FND-001 to 004, FR-TRF-001 to 005 and 007 to 008 and 010, FR-IDM-001 to 005, FR-OPS-001 to 006, INV-1 to INV-4, INV-6, INV-9, INV-10.
**Contract note:** `POST /v1/transfers` returns `201` with status `POSTED` in M1 (PRD P4).

### Tasks

| ID | Task | Size | Learning objective |
|----|------|------|--------------------|
| T-M1-01 | Repo scaffold: module, layout from the architecture doc, Makefile (`run`, `test`, `lint`, `migrate`), `docker-compose.yml` with SQL Server, CI skeleton (format, vet, lint, test, build) | S | LO-9 |
| T-M1-02 | `config` package: env parsing, validation, fail fast on missing required vars | S | LO-9 |
| T-M1-03 | `db` package: `database/sql` with go-mssqldb, pool settings, `WithTx` helper with bounded deadlock (1205) retry, readiness ping | M | LO-10, LO-2 |
| T-M1-04 | Migrations 0001 to 0004 via goose; `make migrate`; testutil that applies them in testcontainers | M | LO-4 |
| T-M1-05 | Middleware: request id, slog JSON logging, panic recovery, 64 KB body limit, API key (constant-time) | M | LO-11 |
| T-M1-06 | Domain errors, central mapper, JSON error shape per the SRS table | S | LO-11 |
| T-M1-07 | Currencies endpoints (list, create with system accounts atomically) | S | LO-4 |
| T-M1-08 | Accounts endpoints (create, get with balances, list with keyset pagination) | M | LO-6 |
| T-M1-09 | Idempotency: canonical JSON, SHA-256 hash, duplicate-error handling (2627/2601), replay and reuse logic | M | LO-4 |
| T-M1-10 | Money package: `Amount` helpers, validation range, exponent lookup | S | LO-13 |
| T-M1-11 | Synchronous posting: lock debited account row (`UPDLOCK, ROWLOCK`), compute balance, insert transfer and entries in one transaction; deposits, withdrawals, transfers | L | LO-1, LO-2 |
| T-M1-12 | Transfer read and list endpoints | S | LO-6 |
| T-M1-13 | `cmd/invariants` checker with the SQL from the data model | M | LO-4 |
| T-M1-14 | Graceful shutdown, `/healthz`, `/readyz` | S | LO-12 |
| T-M1-15 | Learning log: observe blocking with two sessions (`UPDLOCK` vs none) and the write-skew race when the lock is removed; record in `docs/notes/isolation.md` | S | LO-1, LO-2 |

### Test cases

| ID | Scenario | Covers |
|----|----------|--------|
| TC-M1-01 | Requests without or with a wrong API key get `401`; health endpoints open | FR-AUTH-001, 003 |
| TC-M1-02 | Create currency creates exactly two system accounts; duplicate code returns `409` | FR-CUR-002 |
| TC-M1-03 | Create account; get returns zero balances; unknown id returns `404`; bad currency returns `422` | FR-ACC-001, 002 |
| TC-M1-04 | Deposit raises ledger balance; withdrawal with insufficient funds returns `422 INSUFFICIENT_FUNDS` and writes nothing | FR-FND-001, 002 |
| TC-M1-05 | Same-currency transfer posts 2 entries summing to zero; balances move; response is `201 POSTED` | FR-TRF-004, 005 |
| TC-M1-06 | Validation table: zero or negative amount, amount above 10^15, same account, system account, wrong currency, unknown account | FR-TRF-002, FR-ACC-004 |
| TC-M1-07 | Missing idempotency key returns `400`; replay returns `200` with `Idempotent-Replayed`; same key with different body returns `422 IDEMPOTENCY_KEY_REUSED` | FR-IDM-001 to 003 |
| TC-M1-08 | **Concurrency:** 50 parallel requests with one key create exactly one transfer and one set of entries | FR-IDM-004, INV-6, SM-3 |
| TC-M1-09 | **Concurrency:** account holds balance for 10 transfers of amount A; 100 parallel transfers; exactly 10 succeed, 90 get `INSUFFICIENT_FUNDS`, final balance is 0, never negative | FR-TRF-003, INV-2, SM-2 |
| TC-M1-10 | **Concurrency:** 50 transfers A to B and 50 B to A in parallel; all that fit succeed; no deadlock errors reach clients; invariants hold | NFR-REL-003 |
| TC-M1-11 | Direct `UPDATE`/`DELETE` on `ledger_entries` is rejected by the trigger | INV-3 |
| TC-M1-12 | Entry with a currency different from its account's is rejected by the composite foreign key | INV-10 |
| TC-M1-13 | List endpoints paginate with cursor and filters; no duplicates or gaps across pages | FR-ACC-003, FR-TRF-008 |
| TC-M1-14 | SIGTERM during in-flight requests: requests complete, process exits within the timeout | FR-OPS-004 |
| TC-M1-15 | Unit tests: canonical JSON stability (key order, whitespace), validation helpers | FR-IDM-003 |

### Acceptance criteria

1. All M1 requirements demonstrably pass (TC-M1-01 to TC-M1-15 green under `-race`).
2. After TC-M1-08 to TC-M1-10 the invariant checker reports zero violations.
3. `make run` plus `curl` can create accounts, fund them, and transfer money from a clean database in under five minutes of setup.
4. Learning log exists for T-M1-15.

---

## M2: Async and holds (size L)

**Goal:** replace synchronous posting with the hold, job, worker model.
**Requirements:** FR-TRF-006, FR-TRF-009, FR-HLD-001 to 004, FR-JOB-001 to 008, NFR-REL-001, 002, 004, NFR-PERF-002, 004, INV-7.
**Contract note:** from M2, `POST /v1/transfers`, deposits, and withdrawals return `202 PENDING` (PRD P4). Clients poll `GET /v1/transfers/{id}`.

### Tasks

| ID | Task | Size | Learning objective |
|----|------|------|--------------------|
| T-M2-01 | Migration 0005: `holds`, `transfer_jobs`, holds-aware balance view | S | LO-4 |
| T-M2-02 | Submission path: lock, check available (ledger minus holds), insert transfer, hold, and job in one transaction; return `202` plus `Location` | M | LO-1, LO-2 |
| T-M2-03 | Extract the posting logic into a `Poster` interface used by workers (the same repository interface M5 reimplements) | M | LO-9 |
| T-M2-04 | Job repository: claim CTE with `UPDLOCK, READPAST, ROWLOCK` and `OUTPUT`; complete; requeue with backoff; mark dead | L | LO-3, LO-5 |
| T-M2-05 | Worker pool: N goroutines, poll with jitter, per-job context deadline, lease handling | M | LO-12 |
| T-M2-06 | Error classification (transient vs permanent), retry policy, dead-letter handling | M | LO-3 |
| T-M2-07 | Atomic state transitions (`UPDATE ... WHERE status = 'PENDING'`) and idempotent processing (FR-JOB-006) | M | LO-5 |
| T-M2-08 | Graceful shutdown with workers (release leases on abandon); `/readyz` includes worker health | S | LO-12 |
| T-M2-09 | Extend the invariant checker (INV-7, job consistency queries) | S | LO-4 |
| T-M2-10 | Learning log: compare locking `READ COMMITTED`, `READ_COMMITTED_SNAPSHOT`, and `SNAPSHOT` on the submission path; observe `READPAST` behavior with two sessions; record in `docs/notes/isolation.md` | M | LO-1, LO-3 |
| T-M2-11 | Baseline benchmark for NFR-PERF-002 and 004 (see section 6) | S | LO-7 |

### Test cases

| ID | Scenario | Covers |
|----|----------|--------|
| TC-M2-01 | Submission returns `202`, creates transfer `PENDING`, `ACTIVE` hold, `QUEUED` job atomically (fault-injection test: failing job insert leaves no transfer or hold) | FR-TRF-006, FR-HLD-001, FR-JOB-001 |
| TC-M2-02 | Hold lowers available balance but not ledger balance; account endpoint reports `held_amount` | FR-HLD-004 |
| TC-M2-03 | Balance 100; submit 60 then 60: second returns `INSUFFICIENT_FUNDS` immediately | FR-TRF-003 |
| TC-M2-04 | Worker posts: transfer `POSTED`, hold `CAPTURED`, job `DONE`, entries sum to zero | FR-HLD-002, INV-4, INV-7 |
| TC-M2-05 | Permanent-failure injection: transfer `FAILED`, hold `RELEASED`, available restored (the full set of reasons arrives in M4; use a test hook here) | FR-JOB-005 |
| TC-M2-06 | Transient-error injection (simulated 1205): job requeued with backoff, then succeeds; attempts recorded | FR-JOB-004 |
| TC-M2-07 | Retries exhausted: job `DEAD`, transfer `FAILED PROCESSING_ERROR`, hold `RELEASED` | FR-JOB-005 |
| TC-M2-08 | **Concurrency:** 1,000 jobs, 4 workers: each transfer posted exactly once; no job processed twice | FR-JOB-002, NFR-REL-001 |
| TC-M2-09 | **Crash recovery:** kill a worker after entries inserted but before commit (test hook), and after commit but before job update; after lease expiry the transfer ends `POSTED` exactly once | FR-JOB-003, 006, NFR-REL-002 |
| TC-M2-10 | **Concurrency:** 100 parallel submissions against an account with funds for 10: exactly 10 accepted, final state consistent after workers drain | SM-2, INV-2 |
| TC-M2-11 | Idempotent replay of a `PENDING` and of a `POSTED` transfer returns the current state | FR-IDM-002 |
| TC-M2-12 | Graceful shutdown mid-processing: in-flight jobs complete or leases are released; restart finishes the rest | FR-JOB-007 |
| TC-M2-13 | State machine: attempts to move a `FAILED` or `POSTED` transfer to `POSTED` or `FAILED` again change nothing | FR-TRF-009 |

### Acceptance criteria

1. TC-M2-01 to TC-M2-13 green under `-race`; invariant checker clean after every concurrency and crash test.
2. SM-4 met (crash recovery) and SM-2 re-met under async.
3. Baseline benchmark recorded for NFR-PERF-002 and 004.
4. Learning log covers isolation comparison and `READPAST`.

---

## M3: Reversals and statements (size M)

**Goal:** correct history safely and report on it.
**Requirements:** FR-REV-001 to 007, FR-STM-001 to 004, NFR-PERF-003, 005, INV-5, INV-8.

### Tasks

| ID | Task | Size | Learning objective |
|----|------|------|--------------------|
| T-M3-01 | Migration 0006: filtered unique index `ux_transfers_reverses` | S | LO-4 |
| T-M3-02 | Reversal submission: validate original, create `REVERSAL` transfer with hold on the returning customer party, map duplicate-index error to `ALREADY_REVERSED` | M | LO-4, LO-5 |
| T-M3-03 | Reversal posting: negate original entries, flip the original to `REVERSED` in the same transaction | M | LO-5 |
| T-M3-04 | Expose `reverses_transfer_id` and `reversed_by_transfer_id` on transfer resources | S | |
| T-M3-05 | Statement endpoint: window function with `ROWS UNBOUNDED PRECEDING`, keyset pagination, opening and closing balance | M | LO-6 |
| T-M3-06 | Data generator for 100,000 entries on one account; capture and compare execution plans for balance and statement queries (with and without the covering index; windowed-whole vs opening-balance-plus-page approach) | M | LO-7 |
| T-M3-07 | Invariant checker: INV-5 and INV-8 queries | S | LO-4 |
| T-M3-08 | Learning log: execution-plan notes in `docs/notes/query-plans.md` | S | LO-7 |

### Test cases

| ID | Scenario | Covers |
|----|----------|--------|
| TC-M3-01 | Reverse a posted transfer: reversal `POSTED`, original `REVERSED`, balances restored, entries are the exact negation | FR-REV-001, 004, 006, INV-8 |
| TC-M3-02 | Reverse a `PENDING`, `FAILED`, `REVERSED`, or `REVERSAL` transfer returns `409 TRANSFER_NOT_REVERSIBLE` | FR-REV-002 |
| TC-M3-03 | **Concurrency:** 20 parallel reversals of one transfer with different keys: exactly one non-failed reversal exists, others get `ALREADY_REVERSED` | FR-REV-003, INV-5 |
| TC-M3-04 | Recipient already spent the money: reversal returns `INSUFFICIENT_FUNDS` at submission and the original stays `POSTED` | FR-REV-005 |
| TC-M3-05 | A reversal that fails (injected) allows a later retry because the filtered index ignores failed rows | FR-REV-003 |
| TC-M3-06 | Reverse a deposit and a withdrawal (involving the `EXTERNAL` account): correct entries and balances | FR-REV-004 |
| TC-M3-07 | Statement: running balance equals cumulative sum across multiple pages and date windows | FR-STM-001 to 003 |
| TC-M3-08 | Statement `opening_balance` plus sum of page amounts equals `closing_balance` | FR-STM-004 |
| TC-M3-09 | Statement includes reversal lines with correct `transfer_type` | FR-STM-002 |
| TC-M3-10 | Performance: NFR-PERF-003 and 005 measured on the 100,000-entry dataset and recorded | NFR-PERF-003, 005 |

### Acceptance criteria

1. TC-M3-01 to TC-M3-10 green; invariant checker clean (including INV-5 and INV-8).
2. `docs/notes/query-plans.md` shows at least two compared plans with a conclusion.
3. Reversal race (TC-M3-03) passes repeatedly (run 20 times in a loop without failure).

---

## M4: FX (size L)

**Goal:** cross-currency transfers with exact arithmetic.
**Requirements:** FR-FX-001 to 008, NFR-TST-004, INV-1 (per currency, now exercised), INV-9.

### Tasks

| ID | Task | Size | Learning objective |
|----|------|------|--------------------|
| T-M4-01 | Migration 0007: `fx_rates`, FK on `transfers.fx_rate_id`, `vw_ledger_readable` | S | LO-4 |
| T-M4-02 | `fx` package: conversion with `math/big` rationals, exponents, round half even; table-driven and property tests | M | LO-13, LO-14 |
| T-M4-03 | Rate repository and endpoints (create, current, history) | M | LO-6 |
| T-M4-04 | Submission pre-checks: rate exists, fresh (`LEDGER_FX_MAX_AGE`), amount will not round to zero | M | |
| T-M4-05 | Cross-currency posting: four entries via clearing accounts, rate snapshot, destination amount | L | LO-5 |
| T-M4-06 | Posting-time failures: `FX_RATE_UNAVAILABLE`, `FX_RATE_STALE`, `AMOUNT_TOO_SMALL` (permanent, hold released) | M | |
| T-M4-07 | Cross-currency reversal (uses original amounts, no rate lookup) | S | |
| T-M4-08 | Measure contention on clearing accounts under FX load; record in the learning log | S | LO-2 |

### Test cases

| ID | Scenario | Covers |
|----|----------|--------|
| TC-M4-01 | Conversion table: exponents (2 to 0, 0 to 2, 2 to 3), halfway cases round to even, very small and very large amounts | FR-FX-005, NFR-TST-004 |
| TC-M4-02 | Property test: for random amounts and rates, result matches an independent big-rational reference implementation | FR-FX-005 |
| TC-M4-03 | Cross-currency transfer posts four entries; each currency sums to zero; clearing balances correct; rate and destination amount snapshotted | FR-FX-003, 004, 006, INV-1 |
| TC-M4-04 | No rate for the pair returns `422 FX_RATE_UNAVAILABLE` at submission; nothing persisted | FR-FX-006 |
| TC-M4-05 | Stale rate returns `422 FX_RATE_STALE`; `LEDGER_FX_MAX_AGE=0` disables the check | FR-FX-006 |
| TC-M4-06 | Amount rounding to zero returns `422 AMOUNT_TOO_SMALL` | FR-FX-006 |
| TC-M4-07 | Rate removed or aged between submission and posting (test hook): transfer `FAILED` with the matching reason and hold released | FR-FX-007 |
| TC-M4-08 | Rate changes between submission and posting: the transfer uses and records the rate at posting | FR-FX-004 |
| TC-M4-09 | Reverse a cross-currency transfer: entries are the exact negation, original amounts used even though the rate changed | FR-REV-004, INV-8 |
| TC-M4-10 | **Concurrency:** 200 mixed same- and cross-currency transfers across 10 accounts; after drain, INV-1 holds for every currency and no customer is negative | INV-1, INV-2 |
| TC-M4-11 | Rate endpoints: latest effective rate wins; future-dated rates ignored until effective; history paginates | FR-FX-001, 002 |
| TC-M4-12 | Inverse pair not derived: only the direct pair is used | FR-FX-008 |

### Acceptance criteria

1. TC-M4-01 to TC-M4-12 green; invariant checker clean per currency.
2. Property test runs at least 10,000 cases in CI.
3. No float types in money paths (lint rule or grep check in CI) (INV-9).

---

## M5: External rates and polish (size L)

**Goal:** the optional provider, the stored-procedure comparison, and portfolio-grade finish.
**Requirements:** FR-PRV-001 to 005, NFR-MNT-001 to 003, NFR-TST-003, SM-5 to SM-8.

### Tasks

| ID | Task | Size | Learning objective |
|----|------|------|--------------------|
| T-M5-01 | Choose the provider (resolve open question Q1); write ADR-017 recording the choice, terms, and limits | S | |
| T-M5-02 | `RateProvider` interface, `FakeProvider`, real provider adapter with timeouts and bounded retries | M | LO-9 |
| T-M5-03 | Sync job: ticker with context cancellation, skip unchanged rates, log and count failures, integrated with graceful shutdown | M | LO-12 |
| T-M5-04 | Migration 0008: `usp_post_transfer` with `TRY/CATCH`, `THROW`, same locking and posting semantics as the Go version | L | LO-8 |
| T-M5-05 | Stored-procedure repository implementation behind the same interface; switch via config (`LEDGER_STORE=go|sproc`); run the entire integration suite against both | M | LO-8, LO-9 |
| T-M5-06 | Benchmark harness and published results for Go vs stored procedure (section 6) | M | LO-7, LO-8 |
| T-M5-07 | CI complete: lint, vet, `-race` tests, coverage gate (NFR-TST-003), OpenAPI lint, build, invariant run | M | |
| T-M5-08 | Validate `openapi.yaml` against actual responses with contract tests; fix drift | M | |
| T-M5-09 | README: overview, architecture diagram, quickstart, curl walkthrough, design highlights, benchmark table, comparison write-up, v2 roadmap | M | |
| T-M5-10 | Finalize learning logs (`isolation.md`, `query-plans.md`, `go-vs-sproc.md`) and map each LO to evidence (SM-5) | S | |

### Test cases

| ID | Scenario | Covers |
|----|----------|--------|
| TC-M5-01 | Sync job with `FakeProvider` inserts rates with source `PROVIDER:fake`; unchanged rates are skipped | FR-PRV-002 |
| TC-M5-02 | Provider error: logged and counted, no row inserted, transfers continue; staleness rules apply after the max age | FR-PRV-003, FR-FX-006 |
| TC-M5-03 | Manual rate with a later `effective_at` beats a provider rate, and vice versa | FR-PRV-005 |
| TC-M5-04 | Sync job stops on shutdown without leaking goroutines | FR-OPS-004 |
| TC-M5-05 | **Entire M1 to M4 integration suite passes with `LEDGER_STORE=sproc`** | NFR-MNT-002, SM-8 |
| TC-M5-06 | Contract tests: sampled responses validate against `openapi.yaml` | NFR-MNT-003 |
| TC-M5-07 | CI fails if coverage drops below the gate or if lint or OpenAPI validation fails (verify once with a deliberate failure) | NFR-TST-003, NFR-MNT-001 |

### Acceptance criteria

1. Every requirement in the SRS has a passing test or a documented reason (traceability check).
2. Both store implementations pass the same suite; comparison write-up published.
3. README benchmark table filled for all NFR-PERF targets with the hardware noted; any missed target is explained or the target adjusted in the SRS with a note.
4. All learning objectives LO-1 to LO-14 map to evidence (SM-5).
5. A reviewer can clone, run `make up migrate run`, and follow the README walkthrough in under 15 minutes.

---

## 6. Benchmarks

Run on a fixed, documented machine; record CPU, RAM, Docker settings, and SQL Server version.

| ID | Scenario | Measures | Targets |
|----|----------|----------|---------|
| B1 | 50 concurrent clients submit transfers between 1,000 accounts for 60 s | p50/p95/p99 submission latency, throughput | NFR-PERF-002 |
| B2 | Same load; measure submission-to-`POSTED` time | End-to-end p95 with 4 workers | NFR-PERF-004 |
| B3 | One account with 100,000 entries: `GET /accounts/{id}` | p95 latency | NFR-PERF-003 |
| B4 | Same account: statement pages of 50 lines | p95 latency | NFR-PERF-005 |
| B5 | 100 submissions racing for one account's balance | Correctness (zero violations) and timing | NFR-PERF-001 |
| B6 | Go vs stored procedure on B1/B2 | Throughput, latency, CPU | Comparison write-up |

Always run the invariant checker after each benchmark.

## 7. CI definition (target state at M5)

| Stage | Command |
|-------|---------|
| Format | `gofmt -l .` must output nothing |
| Vet and lint | `go vet ./...`, `golangci-lint run` |
| Test | `go test ./... -race -coverprofile=cover.out` (Docker available for testcontainers) |
| Coverage gate | Script fails if `internal/` coverage is below the threshold (NFR-TST-003) |
| Invariants | `go run ./cmd/invariants` against the test database after the suite |
| OpenAPI | Lint `docs/openapi.yaml` with an OpenAPI linter |
| Build | `go build ./...` |
| Float guard | Grep or lint rule rejecting `float32`/`float64` in money and FX packages (INV-9) |

A minimal version of this pipeline (format, vet, test, build) is created in T-M1-01 and grown each milestone.

## 8. v2 backlog (documented, not planned)

Webhooks (reusing the job-table pattern); JWT auth with users and per-account ownership; external broker behind `JobQueue`; balance snapshots for very large ledgers; FX inverse and triangulation; fees; scheduled transfers; Prometheus metrics and tracing; deployment manifests.

## 9. Risk watch-list for the build

| Risk | Early signal | Response |
|------|--------------|----------|
| M2 takes much longer than planned | Claim query and crash tests still flaky after the planned effort | Ship M2 with a single worker first, then add concurrency |
| FX rounding bugs | Property test disagreement | Stop feature work; fix with the reference implementation before continuing |
| Deadlocks under load | 1205 errors above retry budget | Re-read ADR-004 lock rules; check for any path taking two account locks |
| Scope fatigue | Skipping learning logs or tests to "move faster" | Cut scope from the end (M5 extras) rather than quality from the start |
