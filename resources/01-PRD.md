# Product Requirements Document (PRD): Ledger API

| | |
|---|---|
| Status | Approved for build (v1.0) |
| Owner | Product (PM) with the developer as engineering owner |
| Project type | Portfolio-grade learning project |
| Stack | Go, Gin, Microsoft SQL Server, Docker |

## 1. Summary

Ledger API is a REST service that holds money in accounts, moves it between them (including across currencies), and keeps a complete, immutable, double-entry record of every movement. Transfers are accepted quickly and processed asynchronously, funds are reserved with holds while a transfer is pending, mistakes are corrected by reversals, and every balance can be proven correct from the ledger.

It is deliberately built to exercise the hard parts of MSSQL (transactions, isolation, locking hints, queue patterns with `READPAST`, window functions, constraints, filtered indexes, stored procedures, execution plans) and idiomatic Go (project layout, context propagation, concurrency, graceful shutdown, testing).

## 2. Problem and opportunity

**Problem (for the builder):** the developer has strong Python and PostgreSQL experience but wants verifiable depth in MSSQL and in production-style Go. Tutorials do not exercise concurrency and correctness under load, which is where the learning is.

**Opportunity:** a ledger is the smallest domain where correctness is non-negotiable and measurable (money must be conserved), so every technical decision has an observable pass/fail outcome.

## 3. Goals

| ID | Goal | Measured by |
|----|------|-------------|
| G1 | Achieve working fluency in MSSQL | LO-1 to LO-8 below are each demonstrated in code and tests |
| G2 | Achieve working fluency in production-style Go with Gin | LO-9 to LO-14 below are each demonstrated |
| G3 | Produce a portfolio-grade repository | README, architecture docs, CI green, benchmark published (see section 9) |
| G4 | Prove correctness, not just features | Invariant suite (SRS section 6) passes after every concurrency test |

### Learning objectives

| ID | Objective | Where it is exercised |
|----|-----------|-----------------------|
| LO-1 | Transactions, isolation levels, and what MSSQL's default (locking `READ COMMITTED`) does vs `READ_COMMITTED_SNAPSHOT` | M1 transfers, ADR-004 |
| LO-2 | Locking hints: `UPDLOCK`, `ROWLOCK`, `READPAST`; lock ordering and deadlock handling (error 1205) | M1 to M3 |
| LO-3 | Queue pattern in SQL: claim rows with `UPDLOCK, READPAST, ROWLOCK`, leases, retries, dead-lettering | M2 |
| LO-4 | Constraints as guardrails: `CHECK`, composite foreign keys, filtered unique indexes, `INSTEAD OF` triggers | M1 to M3 |
| LO-5 | `OUTPUT` clause, CTE-based `UPDATE`, atomic conditional state transitions | M2, M3 |
| LO-6 | Window functions (running balance), keyset pagination | M3 |
| LO-7 | Indexing: covering indexes with `INCLUDE`, filtered indexes, reading execution plans | M3, M5 |
| LO-8 | T-SQL stored procedures, error handling with `TRY/CATCH`/`THROW`, comparison with app-side transactions | M5 |
| LO-9 | Idiomatic project layout (`cmd/`, `internal/`), dependency injection by interfaces | M1 |
| LO-10 | `database/sql` with `go-mssqldb`, context deadlines, connection pool tuning | M1 |
| LO-11 | Gin middleware, binding and validation, central error mapping | M1 |
| LO-12 | Concurrency: worker pools, tickers, graceful shutdown, cancellation | M2, M5 |
| LO-13 | Exact money arithmetic with integers and `math/big` | M4 |
| LO-14 | Testing: table-driven, testcontainers integration tests, concurrency tests, property tests | all |

## 4. Users and use cases

| Persona | Description | Key needs |
|---------|-------------|-----------|
| **API consumer** | A developer or service integrating with the ledger | Predictable contract, idempotent writes, clear errors, a way to learn a transfer's final status |
| **Operator** | Whoever runs the service (the developer) | Health endpoints, structured logs, an invariant checker, safe shutdown, manual FX rate control |
| **Reviewer** | A hiring manager or peer reading the repo | Clear docs, decision records, proof of correctness, benchmark evidence |

Primary use cases:
1. Create accounts in supported currencies and fund them (deposit) or draw them down (withdrawal).
2. Transfer money between customer accounts, including across currencies at a recorded FX rate.
3. Submit a transfer safely more than once (idempotency) and poll for its result.
4. Reverse a posted transfer without altering history.
5. Read balances (ledger, held, available) and a statement with a running balance.
6. Manage FX rates manually and, optionally, sync them from an external provider.

## 5. Scope

### In scope (v1)

- Accounts (customer and system), currencies with minor-unit exponents
- Deposits and withdrawals through a per-currency `EXTERNAL` system account (so money can enter and leave the system)
- Transfers with a lifecycle: `PENDING`, `POSTED`, `FAILED`, `REVERSED`
- Holds that reserve funds while a transfer is pending (available vs ledger balance)
- Asynchronous processing with MSSQL as the queue (worker pool, leases, retries, dead-letter)
- Reversals via compensating entries
- Multi-currency transfers with FX conversion via per-currency `FX_CLEARING` accounts; rates managed manually and synced from an external provider
- Idempotency keys on all money-moving requests
- Statement endpoint with running balance
- API-key authentication
- Health endpoints, structured logging, graceful shutdown, invariant checker
- Stored-procedure re-implementation of transfer posting (M5) for comparison

### Out of scope (explicit non-goals for v1)

| Item | Why | Possible v2 |
|------|-----|-------------|
| User accounts, JWT, per-user ownership | Generic auth plumbing; API key is enough to show a security posture | Yes |
| Webhooks and push notifications | A second delivery pipeline teaching the same lessons as the first | Yes (reuse the job-table pattern) |
| External message broker (RabbitMQ, Redis) | MSSQL-as-queue is a learning goal | Yes, behind a `JobQueue` interface |
| Pending transfers with explicit confirm and cancel | Replaced by the async pipeline | Maybe |
| Fees, interest, scheduled or recurring transfers | Not needed to exercise the learning goals | Maybe |
| FX triangulation and inverse-rate derivation | Direct pairs only | Yes |
| Hold expiry TTL | Every hold is tied to a job that always reaches a terminal state | No |
| Multi-tenancy, KYC/AML, regulatory reporting | Not a real product | No |
| Deployment manifests, tracing, metrics stack | Quality bar is portfolio-grade, not production-grade | Stretch |

## 6. Feature overview by milestone

| Milestone | Theme | Headline outcome |
|-----------|-------|------------------|
| **M1** Core ledger | Foundation | Accounts, deposits, same-currency transfers posted synchronously, idempotency, API-key auth, concurrency test passes |
| **M2** Async and holds | Reliability model | `202 Accepted` flow, holds, job queue and workers, retries, graceful shutdown |
| **M3** Reversals and statements | History and reporting | Reversal flow with race-safe semantics, statement with running balance, indexing and query-plan work |
| **M4** FX | Multi-currency | Rates, clearing accounts, cross-currency transfers, exact rounding rule |
| **M5** External rates and polish | Portfolio quality | `RateProvider` sync job, stored-procedure comparison, CI, OpenAPI, README, published benchmark |

Detailed tasks and acceptance criteria are in `05-delivery-plan.md`. Each milestone ends with a working, tested API.

## 7. Key product decisions

These came out of the requirements interview and are binding for v1. Each has a full ADR in `03-architecture-and-adrs.md`.

| # | Decision |
|---|----------|
| 1 | Purpose: portfolio-grade learning project, not a production product |
| 2 | Auth: static API keys via middleware; JWT and ownership deferred |
| 3 | Multi-currency with FX conversion (not single-currency, not same-currency-only) |
| 4 | FX rates: manual entry as the base, external provider as an optional sync source |
| 5 | Account types: customer accounts never go negative; system accounts may |
| 6 | Transfer lifecycle with holds and reversals |
| 7 | Asynchronous processing; clients poll `GET /transfers/{id}` |
| 8 | MSSQL as the queue (`UPDLOCK, READPAST, ROWLOCK`) |
| 9 | Delivery in five milestones, ordered by risk |
| 10 | Go owns the money-moving logic first; a stored-procedure version is built in M5 and compared |
| 11 | Money as integer minor units; FX rates `DECIMAL(18,8)`; round half to even |
| 12 | Documents in Markdown in `docs/`, OpenAPI as YAML |
| 13 | Portfolio-grade quality bar (CI, testcontainers, invariant tests, benchmark) |

### Product decisions made while writing the documents

The PM made these calls to close gaps; they are flagged so the owner can overrule them.

| # | Gap found | Decision |
|---|-----------|----------|
| P1 | Customer accounts cannot go negative, so with no funding path every balance would stay zero | Add deposits and withdrawals against a per-currency `EXTERNAL` system account (FR-FND) |
| P2 | The interview assumed a rounding remainder account; with four-entry FX posting the remainder is already absorbed in the clearing accounts | No rounding account in v1; per-currency zero-sum still holds (INV-1) |
| P3 | Hold expiry was discussed, but async processing guarantees every hold ends | Replace hold expiry with job leases, retries and dead-lettering |
| P4 | Milestone M1 is synchronous but M2 makes the API asynchronous | One intentional contract change: `POST /transfers` returns `201 POSTED` in M1 and `202 PENDING` from M2 on. Response body shape is identical |
| P5 | FX rate timing was unspecified | Rate is resolved when the transfer is posted (not at submission) and snapshotted on the transfer |

## 8. Assumptions and dependencies

- A single developer builds this part-time; no external stakeholders or deadlines.
- SQL Server 2022 (or later) runs in Docker locally and in CI. The Developer edition container is sufficient. Check Microsoft's licensing terms for your use.
- An external FX rate provider is needed only in M5. Choosing one is an open question (section 10); everything else works with manual rates.

## 9. Success metrics

| ID | Metric | Target |
|----|--------|--------|
| SM-1 | Invariant suite after each concurrency test | 0 violations |
| SM-2 | Concurrency test: 100 simultaneous submissions against one account | Accepted count is exactly `floor(balance / amount)`; no negative balance |
| SM-3 | Duplicate submission test: 50 parallel requests with one idempotency key | Exactly 1 transfer and 1 set of ledger entries |
| SM-4 | Crash recovery: worker killed mid-job | Transfer posted exactly once after lease expiry |
| SM-5 | Learning coverage | Every LO has at least one test or ADR citing it |
| SM-6 | CI | Green on every merge to main; coverage gate met (NFR-TST-003) |
| SM-7 | Benchmark | Results published in the README against the targets in NFR-PERF |
| SM-8 | Stored-procedure comparison | Same test suite passes on both implementations; write-up with throughput numbers |

## 10. Risks and open questions

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|------------|
| R1 | Scope is large for a "not too fancy" project | High | High | Milestones are each shippable; stopping after M3 still yields a credible project |
| R2 | Hot rows (clearing and `EXTERNAL` accounts) become a contention bottleneck | Medium | Medium | Credits and clearing postings take no account-row lock (ADR-004); measure in M4 |
| R3 | Balance computed by `SUM` becomes slow as entries grow | Medium | Low | Covering index in M1; measure in M3; balance snapshots are a documented stretch |
| R4 | Async plus holds plus reversals interact in subtle ways | Medium | High | State machine in SRS 4.4 is exhaustive; reversal and race tests are in M3 |
| R5 | External FX provider changes or limits | Medium | Low | Provider hidden behind an interface; manual rates always work |
| R6 | Rounding bugs across currencies with different exponents | Medium | High | Property tests; JPY (exponent 0) seeded for tests |

Open questions:

| ID | Question | Owner | Needed by |
|----|----------|-------|-----------|
| Q1 | Which external FX provider to use (free tier, terms, rate limits)? An ADR is required when chosen | Developer | Start of M5 |
| Q2 | Benchmark hardware baseline to record in the README | Developer | M5 |

## 11. Glossary

| Term | Meaning |
|------|---------|
| Minor unit | Smallest unit of a currency (pesewa, cent, yen). Amounts are integers of these |
| Exponent | Number of decimal places of the major unit (GHS 2, JPY 0) |
| Ledger entry | One signed, immutable line affecting one account in one currency |
| Ledger balance | Sum of an account's ledger entries |
| Hold | A reservation of funds against an account for a pending transfer |
| Available balance | Ledger balance minus active holds |
| System account | An account owned by the platform (`EXTERNAL`, `FX_CLEARING`); may be negative |
| Clearing account | System account that sits between two currencies in an FX transfer |
| Idempotency key | Client-chosen key making a write safe to retry |
| Lease | Time-limited claim a worker holds on a job |
| Reversal | A new transfer whose entries exactly negate an earlier transfer's |
