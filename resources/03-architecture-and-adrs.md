# Architecture and Decision Records: Ledger API

Version 1.0. Read `02-SRS.md` first; this document explains how the system is built and why.

---

## 1. Architecture overview

One Go binary, one SQL Server database.

```
                        ┌──────────────────────────── ledger (Go process) ────────────────────────────┐
 client ── HTTP ──►     │  Gin router                                                                 │
                        │   ├─ middleware: request-id, logging, recover, api-key, body-limit          │
                        │   └─ handlers ──► services ──► repositories ──► database/sql ──► SQL Server │
                        │                                                                             │
                        │  Worker pool (N goroutines) ──► claims transfer_jobs ──► posting service    │
                        │  Rate-sync job (M5, ticker) ──► RateProvider ──► fx_rates                   │
                        └─────────────────────────────────────────────────────────────────────────────┘
```

### Layers

| Layer | Responsibility | Must not |
|-------|----------------|----------|
| `httpapi` (Gin handlers, middleware) | Bind and validate input, call a service, map errors to HTTP | Contain business rules or SQL |
| `service` | Business rules, orchestration, transaction boundaries, domain errors | Know about HTTP or Gin |
| `repository` (interfaces in `domain`, implementations in `store/mssql`) | SQL and nothing else; take a `context.Context` and an executor (`*sql.DB` or `*sql.Tx`) | Decide business policy |
| `worker` | Claim jobs, call the posting service, handle retries and leases | Contain posting SQL |
| `fx` | Rate lookup, conversion math (`math/big`), `RateProvider` interface and sync job | Call HTTP from the domain |

Dependencies point inward: handlers depend on services, services depend on repository **interfaces**, implementations depend on `database/sql`.

### Repository layout

```
ledger/
├── cmd/
│   ├── api/main.go               # wiring, config, graceful shutdown
│   └── invariants/main.go        # invariant checker CLI (FR-OPS-005)
├── internal/
│   ├── config/                   # env parsing and validation
│   ├── domain/                   # types, enums, errors, repository interfaces, money
│   ├── httpapi/                  # router, handlers, middleware, error mapping, DTOs
│   ├── service/                  # accounts, transfers, funding, reversal, statement, fx
│   ├── store/mssql/              # repository implementations (+ store/mssql/sproc in M5)
│   ├── worker/                   # pool, claim loop, retry policy
│   ├── fx/                       # conversion, rate lookup, provider interface, fake, sync job
│   └── testutil/                 # testcontainers setup, fixtures, invariant helpers
├── migrations/                   # goose SQL files, numbered per milestone
├── docs/                         # this folder
├── docker-compose.yml            # SQL Server for local dev
├── Makefile                      # run, test, migrate, lint, bench
└── .github/workflows/ci.yml
```

### Technology choices

| Concern | Choice |
|---------|--------|
| Web framework | Gin |
| Database driver | `github.com/microsoft/go-mssqldb` via `database/sql` |
| Data access | Plain SQL; no ORM. `sqlx` is optional for scanning |
| Migrations | goose |
| Logging | `log/slog` JSON handler |
| Tests | `testing`, `testify` (optional), testcontainers-go with SQL Server module |
| Money math | `int64` plus `math/big` for FX |
| Config | Environment variables parsed at startup |

---

## 2. Key flows

### 2.1 Submit a transfer (M2 onward)

```
POST /v1/transfers  (Idempotency-Key)
  1. middleware: auth, request id, body limit
  2. handler: bind JSON, validate shape
  3. service: load source and destination accounts (read), validate rules
  4. service: [FX only] pre-check rate exists, is fresh, amount will not round to zero
  5. repository, ONE transaction:
       a. SELECT source account row WITH (UPDLOCK, ROWLOCK)     -- serialize debits per account
       b. compute available = SUM(entries) - SUM(ACTIVE holds)
       c. if available < amount  -> ROLLBACK, INSUFFICIENT_FUNDS
       d. INSERT transfers (PENDING)   -- unique idempotency_key may fail (duplicate)
       e. INSERT holds (ACTIVE)
       f. INSERT transfer_jobs (QUEUED)
     COMMIT
  6. on unique violation (2627/2601) on idempotency_key: load existing, compare request_hash,
     return replay (200) or IDEMPOTENCY_KEY_REUSED (422)
  7. respond 202 Accepted + Location
```

### 2.2 Worker posting (M2 onward)

```
loop (per worker goroutine):
  claim:  WITH next AS (SELECT TOP (1) ... FROM transfer_jobs WITH (UPDLOCK, READPAST, ROWLOCK)
                        WHERE (status='QUEUED' AND available_at<=now) OR (status='PROCESSING' AND locked_until<now)
                        ORDER BY id)
          UPDATE next SET status='PROCESSING', locked_until=now+lease, locked_by=@worker, attempts=attempts+1
          OUTPUT inserted.*
  process in ONE transaction:
     - SELECT transfer WITH (UPDLOCK, ROWLOCK) WHERE id=@id; if status <> 'PENDING' -> mark job DONE, commit, next
     - [cross-currency] resolve rate, compute D (round half even)
     - INSERT ledger_entries (2 or 4; or negation of original for REVERSAL)
     - UPDATE holds SET status='CAPTURED' WHERE transfer_id=@id AND status='ACTIVE'
     - UPDATE transfers SET status='POSTED', destination_amount, fx_rate, fx_rate_id, posted_at
     - [REVERSAL] UPDATE original SET status='REVERSED' WHERE id=@orig AND status='POSTED'
     - UPDATE transfer_jobs SET status='DONE'
  on permanent failure: transaction that sets transfer FAILED + reason, hold RELEASED, job DONE
  on transient error:  job back to QUEUED, available_at = now + backoff; at max attempts: DEAD + FAILED(PROCESSING_ERROR) + hold RELEASED
```

### 2.3 Reversal (M3)

Same pipeline as 2.1 with `transfer_type = REVERSAL`, `reverses_transfer_id` set, source = the original's destination, destination = the original's source, amount = the original's destination amount. The filtered unique index on `reverses_transfer_id` (non-failed rows only) makes duplicate reversals fail at insert time.

### 2.4 Cross-currency posting (M4)

Source customer `-S` (X), `FX_CLEARING(X)` `+S` (X), `FX_CLEARING(Y)` `-D` (Y), destination customer `+D` (Y). Each currency sums to zero, so the clearing accounts absorb the FX position (and any rounding difference) with no extra rounding account.

---

## 3. Concurrency strategy

This section is the heart of the learning project.

1. **Only debits from customer accounts need a lock.** A debit is the only operation that can violate INV-2. Credits, system accounts, and clearing accounts take no account-row lock, which avoids turning `EXTERNAL` and `FX_CLEARING` rows into global hotspots.
2. **The lock is on the account row** (`SELECT ... WITH (UPDLOCK, ROWLOCK)`), taken before the balance `SUM`. Every writer that checks a balance takes it first, so check-then-insert cannot interleave for the same account. This remains correct under both locking `READ COMMITTED` and `READ_COMMITTED_SNAPSHOT`.
3. **One lock per transaction** in the normal paths (only the debited customer account), so lock-order deadlocks cannot form between two transfers. Where a path ever needs two account locks, acquire them in ascending account-id order.
4. **Deadlocks still get handled.** Error 1205 is retried at the transaction level (bounded, with jitter) on the request path, and via job backoff on the worker path.
5. **State transitions are atomic conditional updates**, for example `UPDATE transfers SET status='POSTED' WHERE id=@id AND status='PENDING'`; zero rows affected means someone else won.
6. **Queue claiming uses `READPAST`** so workers skip rows locked by other workers rather than blocking.
7. **Isolation:** the default `READ COMMITTED` is used, deliberately, with explicit hints doing the serialization work. Experiments with `SERIALIZABLE`, `SNAPSHOT`, and `READ_COMMITTED_SNAPSHOT` are part of the M2 and M3 learning tasks, recorded in `docs/notes/isolation.md`.

---

## 4. Architecture Decision Records

Format: Context, Decision, Alternatives considered, Consequences.

### ADR-001: Gin as the HTTP framework
- **Context:** The developer is already learning Gin; the project should reinforce it.
- **Decision:** Use Gin for routing, binding, and middleware.
- **Alternatives:** `chi` or the standard library `net/http` (lighter, closer to the platform).
- **Consequences:** Gin's `Context` must not leak below the handler layer; services take `context.Context` from `c.Request.Context()`. Binding and validation use Gin's validator tags plus explicit service-level rules.

### ADR-002: SQL Server as the only datastore, plain SQL with `database/sql`
- **Context:** Learning MSSQL is a primary goal.
- **Decision:** All state lives in SQL Server. No ORM; hand-written parameterized SQL.
- **Alternatives:** An ORM such as GORM; PostgreSQL.
- **Consequences:** More boilerplate, but every lock and plan is visible. Keep SQL in `store/mssql`, one function per query, with comments on locking intent.

### ADR-003: Double-entry, append-only ledger with derived balances
- **Context:** Balances must be provable and history immutable.
- **Decision:** Balances are `SUM(amount)` over `ledger_entries`; there is no stored balance column. An `INSTEAD OF UPDATE, DELETE` trigger enforces append-only (INV-3).
- **Alternatives:** Stored balance column updated with each entry; event sourcing with snapshots.
- **Consequences:** Always correct, simple to audit; reads get slower as entries grow, mitigated by a covering index (`account_id, id INCLUDE amount`). Balance snapshots are a documented stretch (R3).

### ADR-004: Per-account row lock for debits; no lock for credits or system accounts
- **Context:** Check-then-insert on a `SUM` is a race (write skew) without serialization.
- **Decision:** Take `UPDLOCK, ROWLOCK` on the debited customer account's row before computing available balance and creating the hold (section 3).
- **Alternatives:** `SERIALIZABLE` isolation (range locks, deadlock-prone); `sp_getapplock`; a stored balance row with optimistic concurrency.
- **Consequences:** Debits on one account serialize; different accounts run in parallel; clearing and `EXTERNAL` accounts are never lock hotspots. Deadlock retry is still required.

### ADR-005: Money as integer minor units, rates as `DECIMAL(18,8)`, round half to even
- **Context:** Exactness across currencies with different exponents.
- **Decision:** `BIGINT` and `int64` for amounts; a `currencies.exponent` table; FX math with `math/big` rationals, rounding once, half to even (INV-9, FR-FX-005).
- **Alternatives:** `DECIMAL(19,4)` with a decimal library; floating point (rejected outright).
- **Consequences:** Exact sums and trivial equality; raw values are less readable, so a `vw_ledger_readable` view exists for humans.

### ADR-006: Transfer lifecycle with holds
- **Context:** Funds must be reserved between acceptance and posting.
- **Decision:** `PENDING` transfers carry an `ACTIVE` hold created in the same transaction; available = ledger minus holds; the hold is captured or released with the final state change.
- **Alternatives:** Debit immediately and refund on failure; no reservation (race between submission and posting).
- **Consequences:** The no-overdraft check happens synchronously at submission, so clients get `INSUFFICIENT_FUNDS` immediately instead of an asynchronous failure.

### ADR-007: Asynchronous posting; clients poll
- **Context:** The pipeline exists to teach queues and concurrency.
- **Decision:** `POST /transfers` returns `202`; a worker posts; clients poll `GET /transfers/{id}`.
- **Alternatives:** Synchronous posting only; webhooks; server-sent events.
- **Consequences:** Needs a status model, idempotency, and retry policy. Webhooks are v2 and would reuse ADR-008's pattern. M1 stays synchronous to prove the posting logic first (PRD P4).

### ADR-008: MSSQL as the queue (`transfer_jobs`)
- **Context:** Avoid a second system and the dual-write problem.
- **Decision:** A `transfer_jobs` table; workers claim rows with `UPDLOCK, READPAST, ROWLOCK` in a CTE `UPDATE ... OUTPUT`; leases, retries with backoff, and a `DEAD` state.
- **Alternatives:** RabbitMQ or Redis; in-process channels only.
- **Consequences:** The job row commits atomically with the transfer and hold. Throughput is bounded by the database, which is acceptable here. A `JobQueue` interface keeps a broker migration possible.

### ADR-009: Idempotency via unique key plus request hash
- **Context:** Safe retries are essential for money movement.
- **Decision:** `idempotency_key` is a unique column on `transfers`; `request_hash` (SHA-256 of method, path, canonical body) detects reuse with different input. Duplicate insert errors (2627/2601) are the arbiter for concurrent duplicates.
- **Alternatives:** Separate idempotency table with response caching; in-memory cache.
- **Consequences:** Replays return the current resource state (`200` plus `Idempotent-Replayed`), not a frozen copy of the first response. Keys never expire in v1.

### ADR-010: Reversal by compensating entries
- **Context:** History must never be edited.
- **Decision:** A reversal is a new `REVERSAL` transfer that negates the original's entries and flips the original to `REVERSED`. A filtered unique index allows only one non-failed reversal per original.
- **Alternatives:** Edit or delete entries; a `voided` flag on entries.
- **Consequences:** The returning party must have funds, so a reversal can be rejected for `INSUFFICIENT_FUNDS`. Cross-currency reversals use original amounts, never a new rate (FR-REV-004).

### ADR-011: FX through per-currency clearing accounts, rate resolved at posting
- **Context:** Each currency's ledger must still sum to zero.
- **Decision:** Four entries per cross-currency transfer via `FX_CLEARING(X)` and `FX_CLEARING(Y)`. The rate is looked up when posting and snapshotted on the transfer. Direct pairs only.
- **Alternatives:** Lock the rate at submission (quote model); triangulate via a base currency; a dedicated rounding account.
- **Consequences:** The rate can change between submission and posting; the transfer response shows the rate actually used. Clearing accounts accumulate the house FX position and may be negative. No rounding account is needed (PRD P2).

### ADR-012: Typed domain errors mapped in one place
- **Context:** Consistent API errors and testable business rules.
- **Decision:** `domain` defines sentinel and typed errors (`ErrInsufficientFunds`, `ErrDuplicateTransfer`, and so on). One function in `httpapi` maps them to the SRS error table. Handlers never choose status codes for domain errors ad hoc.
- **Alternatives:** Status codes decided in services; string matching.
- **Consequences:** Adding an error means one domain type, one mapping line, and one table row in the SRS.

### ADR-013: API-key authentication
- **Context:** Show a security posture without building user management.
- **Decision:** `X-API-Key` middleware with constant-time comparison against `LEDGER_API_KEYS`.
- **Alternatives:** No auth; JWT with users and ownership.
- **Consequences:** No per-user authorization. v2 can replace the middleware without touching handlers.

### ADR-014: Go implementation first, stored procedure in M5, compared
- **Context:** Both Go depth and T-SQL depth are goals.
- **Decision:** Build all posting logic in Go (M1 to M4). In M5, reimplement the posting transaction as a stored procedure (`usp_post_transfer`) behind the same repository interface and run the same suite against both. Publish a comparison.
- **Alternatives:** Stored procedures from the start; Go only.
- **Consequences:** The test suite must target the interface, not the implementation. The comparison covers throughput, latency, lines of code, debuggability, and testability.

### ADR-015: Pluggable `RateProvider`
- **Context:** External rates are optional and may change.
- **Decision:** A `RateProvider` interface; a sync job depending only on it; a `FakeProvider` for tests; the concrete provider chosen at the start of M5 (record as ADR-017 then).
- **Alternatives:** Hard-coded HTTP client in the service.
- **Consequences:** Provider outages degrade freshness, not correctness (FR-PRV-003).

### ADR-016: Funding through an `EXTERNAL` system account per currency
- **Context:** Customer accounts cannot go negative, so money needs a source and a sink.
- **Decision:** Deposits and withdrawals are transfers against the currency's `EXTERNAL` system account, which may go negative. Its balance equals the net amount of money inside the system, negated.
- **Alternatives:** Allow an "admin credit" that creates entries without a counterparty (breaks INV-1).
- **Consequences:** INV-1 holds with no special cases, and the `EXTERNAL` balance is a built-in reconciliation figure.

---

## 5. Cross-cutting concerns

| Concern | Approach |
|---------|----------|
| Context and timeouts | Every repository call takes `ctx`. Request-path DB calls use a per-request deadline (default 5 s). Worker jobs use a per-job deadline equal to the lease minus a safety margin |
| Connection pool | `SetMaxOpenConns` from config, `SetMaxIdleConns` equal to it, `SetConnMaxLifetime` of 30 minutes; tuned and documented during M1 |
| Transactions | A small helper `WithTx(ctx, db, fn)` handles begin, commit, rollback, and deadlock retry; services never call `Begin` directly |
| Time | Server-side `SYSUTCDATETIME()` for persisted timestamps so all writers share one clock |
| Request validation | Shape validation in handlers; business validation in services; constraints in the database as a last line |
| Testing seams | Repositories are interfaces; the clock and the rate provider are injected; testcontainers provide a real database for integration tests |
| Migrations in tests | Test setup applies the same goose migrations as production |
