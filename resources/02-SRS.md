# Software Requirements Specification (SRS): Ledger API

Version 1.0. Companion to `01-PRD.md`. Terms are defined in the PRD glossary.

Requirement keywords: **MUST** is mandatory, **SHOULD** is expected unless there is a documented reason, **MAY** is optional.
Each requirement has a milestone tag (M1 to M5) for when it lands.

---

## 1. Purpose and scope

This document specifies the externally observable behavior, data rules, and quality attributes of the Ledger API. It is the contract the implementation and test suite are written against. Design rationale lives in `03-architecture-and-adrs.md`; the schema in `04-data-model.md`; the HTTP shape in `openapi.yaml`.

## 2. System context

```
 API consumer ──HTTPS/JSON──► Ledger API (Gin) ──► SQL Server
                                  │   ▲
                                  │   └── Worker pool (same process) polls transfer_jobs
                                  └──► (M5) FX rate provider over HTTPS (outbound only)
```

- One deployable Go binary: HTTP server, worker pool, and (M5) rate-sync job.
- One database: SQL Server. No other stateful dependency.
- Clients are trusted callers holding an API key.

## 3. Assumptions and constraints

- Single database instance; no multi-region or sharding.
- All timestamps are UTC, stored as `DATETIME2(3)`, serialized as RFC 3339.
- IDs for accounts and transfers are UUIDs; ledger entries and holds use `BIGINT IDENTITY`.
- Amounts in the API are JSON integers of minor units, in the range 1 to 10^15 inclusive (keeps values exact in JavaScript clients).
- Go 1.22 or newer; SQL Server 2022 or newer.

## 4. Domain rules

### 4.1 Accounts

- **Types:** `CUSTOMER` and `SYSTEM`. System accounts have a `system_role`: `EXTERNAL` (the outside world for deposits and withdrawals) or `FX_CLEARING` (sits between currencies).
- Exactly one `EXTERNAL` and one `FX_CLEARING` account exist per currency, created when the currency is created.
- Each account has exactly one currency, fixed for life.
- `CUSTOMER` accounts MUST never have a negative ledger balance or a negative available balance (INV-2). `SYSTEM` accounts MAY go negative.
- Accounts are never deleted or closed in v1.

### 4.2 Money

- All amounts are integer minor units (`BIGINT` in the database, `int64` in Go). Per-currency exponent comes from the `currencies` table.
- No floating-point types are used for amounts or FX arithmetic (INV-9).
- A ledger entry amount is signed: negative debits the account, positive credits it.

### 4.3 Posting patterns

Every posted transfer writes ledger entries that sum to zero **per currency**.

| Case | Entries |
|------|---------|
| Same-currency transfer, deposit, or withdrawal | 2 entries: source `-A`, destination `+A` |
| Cross-currency transfer (source amount `S` in currency X, destination amount `D` in currency Y) | 4 entries: source customer `-S` (X); `FX_CLEARING(X)` `+S` (X); `FX_CLEARING(Y)` `-D` (Y); destination customer `+D` (Y) |
| Reversal | The exact negation of the original transfer's entries (same accounts, same currencies, opposite signs) |

Deposits use the `EXTERNAL` account of the account's currency as the source; withdrawals use it as the destination.

### 4.4 Transfer state machine

| From | To | Trigger |
|------|----|---------|
| (none) | `PENDING` | Submission accepted (M2+). In M1 the transfer is created directly as `POSTED` |
| `PENDING` | `POSTED` | Worker posts ledger entries successfully |
| `PENDING` | `FAILED` | Permanent failure, or retries exhausted |
| `POSTED` | `REVERSED` | A reversal transfer of it reaches `POSTED` |

No other transitions are allowed. `FAILED` and `REVERSED` are terminal. A `REVERSAL` transfer itself follows `PENDING` to `POSTED` or `FAILED` and can never be reversed.

Failure reasons (`failure_reason`, set if and only if status is `FAILED`):

| Reason | Meaning |
|--------|---------|
| `FX_RATE_UNAVAILABLE` | No rate exists for the pair at posting time |
| `FX_RATE_STALE` | The latest rate is older than the maximum age |
| `AMOUNT_TOO_SMALL` | Converted amount rounds to zero |
| `PROCESSING_ERROR` | Retries exhausted on transient errors (job moved to `DEAD`) |

### 4.5 Balances

- **Ledger balance** = sum of the account's ledger entries.
- **Held amount** = sum of the account's `ACTIVE` holds (always 0 before M2).
- **Available balance** = ledger balance minus held amount.
- Fund checks always use the **available** balance.

### 4.6 Holds (M2 onward)

A hold reserves funds on a `CUSTOMER` account that will be debited. It is created in the same database transaction as the transfer and its job. It becomes `CAPTURED` when the transfer posts and `RELEASED` when it fails. `SYSTEM` accounts never carry holds.

---

## 5. Functional requirements

### 5.1 Authentication (FR-AUTH)

| ID | Requirement | M |
|----|-------------|---|
| FR-AUTH-001 | Every `/v1` endpoint MUST require an `X-API-Key` header matching one of the configured keys. Otherwise respond `401 UNAUTHORIZED`. | M1 |
| FR-AUTH-002 | Key comparison MUST be constant-time. Keys MUST NOT appear in logs or error bodies. | M1 |
| FR-AUTH-003 | `/healthz` and `/readyz` MUST NOT require a key. | M1 |
| FR-AUTH-004 | All configured keys have equal privileges in v1. | M1 |

### 5.2 Currencies (FR-CUR)

| ID | Requirement | M |
|----|-------------|---|
| FR-CUR-001 | Migrations MUST seed `GHS` (2), `USD` (2), `EUR` (2), `GBP` (2), and `JPY` (0), each with its `EXTERNAL` and `FX_CLEARING` system accounts. | M1 |
| FR-CUR-002 | `POST /v1/currencies` MUST create a currency and its two system accounts atomically. Code is three uppercase letters; exponent 0 to 4; both immutable. Duplicate code returns `409 CONFLICT`. | M1 |
| FR-CUR-003 | `GET /v1/currencies` MUST list currencies with their exponents. | M1 |

### 5.3 Accounts (FR-ACC)

| ID | Requirement | M |
|----|-------------|---|
| FR-ACC-001 | `POST /v1/accounts` MUST create a `CUSTOMER` account from `{name, currency}`. Name is 1 to 200 characters; currency must exist. Returns `201`. | M1 |
| FR-ACC-002 | `GET /v1/accounts/{id}` MUST return the account plus `ledger_balance`, `held_amount`, `available_balance` (integers, minor units). Unknown id returns `404 NOT_FOUND`. | M1 |
| FR-ACC-003 | `GET /v1/accounts` MUST list accounts with keyset pagination (`limit` default 50, max 200; opaque `cursor`), filterable by `currency` and `type`. | M1 |
| FR-ACC-004 | System accounts MUST NOT be usable as the source or destination of `POST /v1/transfers`; attempts return `422 ACCOUNT_NOT_ELIGIBLE`. | M1 |
| FR-ACC-005 | There is no endpoint to update or delete an account in v1. | M1 |

### 5.4 Funding: deposits and withdrawals (FR-FND)

| ID | Requirement | M |
|----|-------------|---|
| FR-FND-001 | `POST /v1/accounts/{id}/deposits` with `{amount, currency, reference?}` MUST create a `DEPOSIT` transfer from the currency's `EXTERNAL` account to the account. Requires `Idempotency-Key`. | M1 |
| FR-FND-002 | `POST /v1/accounts/{id}/withdrawals` MUST create a `WITHDRAWAL` transfer from the account to the `EXTERNAL` account and MUST check available funds (`422 INSUFFICIENT_FUNDS`). Requires `Idempotency-Key`. | M1 |
| FR-FND-003 | `currency` in the body MUST equal the account's currency, else `422 CURRENCY_MISMATCH`. | M1 |
| FR-FND-004 | Deposits and withdrawals follow the same lifecycle, status codes, and failure handling as transfers (FR-TRF). Only customer accounts are eligible. | M1 |

### 5.5 Transfers (FR-TRF)

| ID | Requirement | M |
|----|-------------|---|
| FR-TRF-001 | `POST /v1/transfers` with `{source_account_id, destination_account_id, amount, currency, reference?}` MUST create a transfer. `amount` is in minor units of the source account's currency. Requires `Idempotency-Key`. | M1 |
| FR-TRF-002 | Validation: `amount` integer in 1 to 10^15; `currency` equals the source account's currency (`CURRENCY_MISMATCH`); both accounts exist (`404`); accounts differ (`SAME_ACCOUNT`); both are `CUSTOMER` accounts (`ACCOUNT_NOT_ELIGIBLE`); `reference` at most 200 characters. Validation errors return `422` (malformed JSON returns `400 INVALID_REQUEST`). | M1 |
| FR-TRF-003 | If the source's available balance is less than `amount`, respond `422 INSUFFICIENT_FUNDS` and persist nothing. The check and the hold MUST happen under the source account's row lock (INV-2). | M1 |
| FR-TRF-004 | Same-currency transfers MUST set `destination_amount = amount` and post 2 entries. | M1 |
| FR-TRF-005 | **M1 only:** the transfer MUST be posted inside the request and the response MUST be `201` with status `POSTED`. | M1 |
| FR-TRF-006 | **M2 onward:** the API MUST create the transfer as `PENDING` together with its hold and job in one transaction and respond `202 Accepted` with a `Location` header for `GET /v1/transfers/{id}`. The response body shape is the same as in M1. | M2 |
| FR-TRF-007 | `GET /v1/transfers/{id}` MUST return the transfer with status, failure reason, amounts, currencies, FX rate (if any), `reverses_transfer_id`, `reversed_by_transfer_id`, and timestamps. | M1 |
| FR-TRF-008 | `GET /v1/transfers` MUST list transfers with keyset pagination, filterable by `account_id` (either side), `status`, `type`, `from`, `to`. | M1 |
| FR-TRF-009 | Status changes MUST follow the state machine in section 4.4 and each transition MUST be an atomic conditional update (for example `UPDATE ... WHERE status = 'PENDING'`) so concurrent actors cannot both win. | M2 |
| FR-TRF-010 | Transfer types are `TRANSFER`, `DEPOSIT`, `WITHDRAWAL`, `REVERSAL`. | M1 |

### 5.6 Idempotency (FR-IDM)

| ID | Requirement | M |
|----|-------------|---|
| FR-IDM-001 | `Idempotency-Key` MUST be required on `POST /v1/transfers`, deposits, withdrawals, and reversals. Missing returns `400 IDEMPOTENCY_KEY_REQUIRED`. Format: 1 to 100 characters from `A-Z a-z 0-9 _ - : .`. | M1 |
| FR-IDM-002 | A repeat of the same key with the same canonical request MUST NOT create a new transfer. It returns `200` with the current transfer resource and header `Idempotent-Replayed: true`. | M1 |
| FR-IDM-003 | The same key with a different request MUST return `422 IDEMPOTENCY_KEY_REUSED`. "Same request" means an equal SHA-256 of the HTTP method, path, and canonical (sorted-key, whitespace-free) JSON body. | M1 |
| FR-IDM-004 | Concurrent duplicates MUST result in exactly one created transfer; the unique constraint is the arbiter, and losers fetch and return the winner (INV-6). | M1 |
| FR-IDM-005 | Keys are retained indefinitely in v1. | M1 |

### 5.7 Holds (FR-HLD)

| ID | Requirement | M |
|----|-------------|---|
| FR-HLD-001 | On submission of a debit from a `CUSTOMER` account, an `ACTIVE` hold for the full source amount MUST be created in the same transaction as the transfer and job. | M2 |
| FR-HLD-002 | The hold becomes `CAPTURED` in the same transaction that posts the transfer, and `RELEASED` in the same transaction that fails it. | M2 |
| FR-HLD-003 | `ACTIVE` holds MUST exist only for `PENDING` transfers (INV-7). | M2 |
| FR-HLD-004 | `GET /v1/accounts/{id}` MUST report `held_amount` and `available_balance` reflecting active holds. | M2 |

### 5.8 Asynchronous processing (FR-JOB)

| ID | Requirement | M |
|----|-------------|---|
| FR-JOB-001 | A `transfer_jobs` row MUST be created in the same transaction as its transfer. | M2 |
| FR-JOB-002 | Workers MUST claim jobs atomically using `UPDLOCK, READPAST, ROWLOCK` so no two workers process the same job. The worker count is configurable (default 4). | M2 |
| FR-JOB-003 | A claimed job holds a lease (default 30 s). A job whose lease has expired MUST become claimable again. | M2 |
| FR-JOB-004 | Transient errors (deadlock 1205, timeouts, connection loss) MUST requeue the job with exponential backoff (2^attempts seconds, capped at 60 s), up to 5 attempts. | M2 |
| FR-JOB-005 | Permanent failures (section 4.4 reasons other than `PROCESSING_ERROR`) MUST fail the transfer immediately with no retry. When attempts are exhausted the job becomes `DEAD`, the transfer `FAILED` with `PROCESSING_ERROR`, and the hold `RELEASED`. | M2 |
| FR-JOB-006 | Processing MUST be idempotent: if the transfer is no longer `PENDING`, the worker marks the job `DONE` and changes nothing else. | M2 |
| FR-JOB-007 | On shutdown, workers MUST stop claiming, finish in-flight jobs within the shutdown timeout, and release the lease of any job they abandon. | M2 |
| FR-JOB-008 | No global or per-account ordering of processing is guaranteed. Clients must not rely on it. | M2 |

### 5.9 Reversals (FR-REV)

| ID | Requirement | M |
|----|-------------|---|
| FR-REV-001 | `POST /v1/transfers/{id}/reverse` with optional `{reason}` MUST create a `REVERSAL` transfer. Requires `Idempotency-Key`. Returns `202`. | M3 |
| FR-REV-002 | Only a `POSTED` transfer whose type is not `REVERSAL` can be reversed; otherwise `409 TRANSFER_NOT_REVERSIBLE`. | M3 |
| FR-REV-003 | At most one non-`FAILED` reversal may exist per transfer; a second attempt returns `409 ALREADY_REVERSED`. A filtered unique index is the arbiter (INV-5). | M3 |
| FR-REV-004 | Reversal entries MUST be the exact negation of the original's entries. For cross-currency transfers no rate lookup occurs; the original amounts are used (INV-8). | M3 |
| FR-REV-005 | The party returning funds (the original destination) is checked and held like any debit if it is a `CUSTOMER` account. If funds are insufficient at submission, `422 INSUFFICIENT_FUNDS`. | M3 |
| FR-REV-006 | When the reversal posts, the original transfer MUST move to `REVERSED` in the same transaction. | M3 |
| FR-REV-007 | The original transfer resource MUST expose `reversed_by_transfer_id`; the reversal exposes `reverses_transfer_id`. | M3 |

### 5.10 Statements (FR-STM)

| ID | Requirement | M |
|----|-------------|---|
| FR-STM-001 | `GET /v1/accounts/{id}/statement?from&to&limit&cursor` MUST return the account's ledger entries in ascending entry-id order, with keyset pagination. | M3 |
| FR-STM-002 | Each line: `entry_id`, `transfer_id`, `transfer_type`, `amount`, `running_balance`, `reference`, `created_at`. | M3 |
| FR-STM-003 | `running_balance` MUST equal the sum of all of the account's entries up to and including that entry, regardless of the `from`/`to` window or page. | M3 |
| FR-STM-004 | The response MUST include `opening_balance` (balance before the first line of the window) and `closing_balance` (balance after the last line of the window). | M3 |

### 5.11 Foreign exchange (FR-FX)

| ID | Requirement | M |
|----|-------------|---|
| FR-FX-001 | `POST /v1/fx-rates` with `{base_currency, quote_currency, rate, effective_at?}` MUST append a rate row with source `MANUAL`. `rate` is a decimal string with at most 10 integer and 8 fractional digits, greater than zero. Rates are append-only; a correction is a newer row. | M4 |
| FR-FX-002 | `GET /v1/fx-rates?base_currency&quote_currency` MUST return the effective rate (latest `effective_at` not in the future). `GET /v1/fx-rates/history` returns paginated history. | M4 |
| FR-FX-003 | Transfers between `CUSTOMER` accounts of different currencies MUST be allowed and use the 4-entry pattern (section 4.3). | M4 |
| FR-FX-004 | The rate is resolved when the transfer is posted, then snapshotted on the transfer (`fx_rate`, `fx_rate_id`). | M4 |
| FR-FX-005 | Conversion: `D = round_half_even(S * rate * 10^(exp_dest - exp_src))`, computed with `math/big` rationals. Floating point is forbidden (INV-9). Rounding happens once. | M4 |
| FR-FX-006 | At submission, if no direct-pair rate exists, respond `422 FX_RATE_UNAVAILABLE`; if the latest rate is older than `LEDGER_FX_MAX_AGE` (default 24 h; 0 disables), respond `422 FX_RATE_STALE`; if the estimate rounds to zero, respond `422 AMOUNT_TOO_SMALL`. Nothing is persisted. | M4 |
| FR-FX-007 | At posting, the same three conditions fail the transfer with the matching `failure_reason` (permanent, no retry) and release the hold. | M4 |
| FR-FX-008 | Only direct pairs are supported: no inverse derivation and no triangulation. | M4 |

### 5.12 External rate provider (FR-PRV)

| ID | Requirement | M |
|----|-------------|---|
| FR-PRV-001 | The domain MUST depend on a `RateProvider` interface (`Fetch(ctx, pairs) ([]Rate, error)`), never on a concrete HTTP client. | M5 |
| FR-PRV-002 | When enabled, a background job MUST fetch rates for configured pairs every `LEDGER_FX_SYNC_INTERVAL` (default 60 min) and append rows with source `PROVIDER:<name>`, skipping rates unchanged from the latest row. | M5 |
| FR-PRV-003 | Provider failure MUST be logged and counted and MUST NOT affect transfers except through staleness (FR-FX-006). | M5 |
| FR-PRV-004 | A `FakeProvider` MUST exist for tests. The real provider is disabled by default (`LEDGER_FX_PROVIDER=none`). | M5 |
| FR-PRV-005 | The latest `effective_at` wins regardless of source (manual or provider). | M5 |

### 5.13 Operations (FR-OPS)

| ID | Requirement | M |
|----|-------------|---|
| FR-OPS-001 | `GET /healthz` returns `200` if the process is up. `GET /readyz` returns `200` only if the database answers a ping (and, from M2, workers are running); otherwise `503`. | M1 |
| FR-OPS-002 | Every request gets a request id: accept `X-Request-ID` or generate one; return it in the response header, logs, and error bodies. | M1 |
| FR-OPS-003 | Logs MUST be structured JSON (`log/slog`) including request id, method, path, status, latency. | M1 |
| FR-OPS-004 | On `SIGINT`/`SIGTERM` the server MUST stop accepting connections, drain in-flight requests, stop workers (FR-JOB-007), and exit within `LEDGER_SHUTDOWN_TIMEOUT` (default 30 s). | M1 |
| FR-OPS-005 | A `cmd/invariants` program MUST run the invariant queries in `04-data-model.md` section 7 and exit non-zero on any violation. | M1 |
| FR-OPS-006 | Schema changes MUST be versioned goose migrations applied via `make migrate`; there is no auto-migrate on start. | M1 |

---

## 6. Invariants

Invariants are properties that must hold at all times, including under concurrency, crashes, and retries. The invariant checker (FR-OPS-005) tests them; every concurrency test ends by running it.

| ID | Invariant | Enforced by |
|----|-----------|-------------|
| INV-1 | For every currency, the sum of all ledger entries is exactly zero | Posting patterns (4.3) plus checker |
| INV-2 | A `CUSTOMER` account's ledger balance and available balance are never negative | Row lock plus fund check at hold or posting time; checker |
| INV-3 | Ledger entries are append-only: never updated or deleted | `INSTEAD OF UPDATE, DELETE` trigger; no such statements in code |
| INV-4 | A transfer has ledger entries if and only if its status is `POSTED` or `REVERSED`, and its entries sum to zero per currency | Single transaction for entries plus status |
| INV-5 | A transfer is reversed at most once | Filtered unique index on `reverses_transfer_id` |
| INV-6 | An idempotency key maps to exactly one transfer | Unique constraint on `idempotency_key` |
| INV-7 | `ACTIVE` holds exist only for `PENDING` transfers, and each `PENDING` debit from a customer has exactly one `ACTIVE` hold | Same-transaction hold transitions; checker |
| INV-8 | A reversal's entries exactly negate the original's | Reversal posting logic; checker |
| INV-9 | No floating-point type is used for amounts, rates, or conversion | Code review, lint rule, tests |
| INV-10 | An entry's currency equals its account's currency | Composite foreign key `(account_id, currency)` |

---

## 7. Non-functional requirements

### 7.1 Correctness and reliability (NFR-REL)

| ID | Requirement |
|----|-------------|
| NFR-REL-001 | No acknowledged transfer may be lost or applied twice, including across process crashes at any point. |
| NFR-REL-002 | A crashed worker's job MUST be reprocessed after lease expiry with exactly-once ledger effect. |
| NFR-REL-003 | Deadlocks MUST be retried transparently (bounded) and never surface as corrupted state. |
| NFR-REL-004 | Posting a transfer MUST be one database transaction covering entries, hold, transfer status, original status (reversals), and job status. |

### 7.2 Performance (NFR-PERF)

Targets are measured on a documented laptop-class machine with SQL Server in Docker, then recorded in the README. If a target proves unrealistic, change it in this table with a note, not silently.

| ID | Requirement |
|----|-------------|
| NFR-PERF-001 | 100 concurrent submissions against one account produce zero invariant violations. |
| NFR-PERF-002 | `POST /v1/transfers` (submission only, M2+): p95 under 150 ms at 50 concurrent clients. |
| NFR-PERF-003 | `GET /v1/accounts/{id}` with 100,000 entries on the account: p95 under 100 ms. |
| NFR-PERF-004 | End-to-end time from submission to `POSTED`: p95 under 1 s with 4 workers at 100 concurrent submissions. |
| NFR-PERF-005 | Statement page of 50 lines on an account with 100,000 entries: p95 under 200 ms. |

### 7.3 Security (NFR-SEC)

| ID | Requirement |
|----|-------------|
| NFR-SEC-001 | All SQL MUST be parameterized; no string-built queries from request data. |
| NFR-SEC-002 | Secrets (DSN, API keys) come from environment variables only and are never logged. |
| NFR-SEC-003 | Request bodies are limited to 64 KB; unknown JSON fields are rejected. |
| NFR-SEC-004 | The database login used by the app MUST NOT hold `UPDATE`/`DELETE` permission on `ledger_entries` (defense in depth with INV-3). |
| NFR-SEC-005 | Error responses MUST NOT leak SQL text, stack traces, or driver messages. |

### 7.4 Observability and operability (NFR-OBS)

| ID | Requirement |
|----|-------------|
| NFR-OBS-001 | Request-scoped logs and job logs carry request id or job id and transfer id. |
| NFR-OBS-002 | Job outcomes (done, retried, failed, dead) and provider sync outcomes are logged at a stable, queryable level and message. |
| NFR-OBS-003 | The service starts, becomes ready, and shuts down cleanly with a single command each (`make run`, `Ctrl-C`). |

### 7.5 Testing (NFR-TST)

| ID | Requirement |
|----|-------------|
| NFR-TST-001 | Integration tests run against a real SQL Server using testcontainers; no mocked database for money paths. |
| NFR-TST-002 | Every test listed in the delivery plan for the current milestone exists and passes. |
| NFR-TST-003 | Line coverage of `internal/` at least 75 percent, enforced in CI; the gate is raised only, never lowered. |
| NFR-TST-004 | Property-based or table-driven tests cover FX conversion across exponents 0, 2, 3 including halfway cases. |
| NFR-TST-005 | Every concurrency test ends by running the invariant checker. |

### 7.6 Maintainability (NFR-MNT)

| ID | Requirement |
|----|-------------|
| NFR-MNT-001 | CI runs format check, `go vet`, linter, tests, and build on every push. |
| NFR-MNT-002 | The transfer-posting repository is an interface with a Go implementation (M1) and a stored-procedure implementation (M5) that pass the same test suite. |
| NFR-MNT-003 | `openapi.yaml` validates with a linter in CI and matches implemented behavior. |

---

## 8. Error model

All errors use one JSON shape:

```json
{
  "error": {
    "code": "INSUFFICIENT_FUNDS",
    "message": "Available balance is lower than the requested amount.",
    "request_id": "7f1c...",
    "details": { "available_balance": 1500, "requested": 2500 }
  }
}
```

`code` is a stable, machine-readable string. `message` is human-readable and may change. `details` is optional.

| HTTP | Code | When |
|------|------|------|
| 400 | `INVALID_REQUEST` | Malformed JSON, unknown fields, bad query parameters |
| 400 | `IDEMPOTENCY_KEY_REQUIRED` | Missing or malformed `Idempotency-Key` |
| 401 | `UNAUTHORIZED` | Missing or invalid API key |
| 404 | `NOT_FOUND` | Unknown account, transfer, or currency |
| 409 | `CONFLICT` | Duplicate currency code |
| 409 | `TRANSFER_NOT_REVERSIBLE` | Reversal of a non-`POSTED` transfer or of a `REVERSAL` |
| 409 | `ALREADY_REVERSED` | A non-failed reversal already exists |
| 422 | `VALIDATION_ERROR` | Field-level failures (range, length, format) with details |
| 422 | `INSUFFICIENT_FUNDS` | Available balance too low |
| 422 | `SAME_ACCOUNT` | Source equals destination |
| 422 | `ACCOUNT_NOT_ELIGIBLE` | A system account used in a public transfer |
| 422 | `CURRENCY_MISMATCH` | Body currency differs from the source (or account) currency |
| 422 | `IDEMPOTENCY_KEY_REUSED` | Same key, different request |
| 422 | `FX_RATE_UNAVAILABLE` | No direct-pair rate (M4+) |
| 422 | `FX_RATE_STALE` | Rate older than the maximum age (M4+) |
| 422 | `AMOUNT_TOO_SMALL` | Converted amount rounds to zero (M4+) |
| 500 | `INTERNAL` | Unexpected error (details only in logs) |
| 503 | `SERVICE_UNAVAILABLE` | Database unreachable or deadlock retries exhausted on the request path |

Domain errors are typed in Go (for example `ErrInsufficientFunds`) and mapped to this table in one place (ADR-012).

## 9. Configuration

All via environment variables.

| Variable | Default | Milestone | Purpose |
|----------|---------|-----------|---------|
| `LEDGER_HTTP_ADDR` | `:8080` | M1 | Listen address |
| `LEDGER_DB_DSN` | none (required) | M1 | SQL Server connection string |
| `LEDGER_API_KEYS` | none (required) | M1 | Comma-separated valid API keys |
| `LEDGER_DB_MAX_OPEN_CONNS` | `25` | M1 | Pool size |
| `LEDGER_SHUTDOWN_TIMEOUT` | `30s` | M1 | Graceful shutdown limit |
| `LEDGER_WORKER_COUNT` | `4` | M2 | Worker goroutines |
| `LEDGER_JOB_LEASE` | `30s` | M2 | Job lease duration |
| `LEDGER_JOB_MAX_ATTEMPTS` | `5` | M2 | Retry cap |
| `LEDGER_FX_MAX_AGE` | `24h` | M4 | Rate staleness limit (`0` disables) |
| `LEDGER_FX_PROVIDER` | `none` | M5 | `none`, `fake`, or a named provider |
| `LEDGER_FX_SYNC_INTERVAL` | `60m` | M5 | Provider sync period |
| `LEDGER_FX_SYNC_PAIRS` | empty | M5 | Comma-separated pairs, for example `USD/GHS,GHS/USD` |

## 10. Traceability

| Goal or objective | Requirements |
|-------------------|--------------|
| LO-1, LO-2 (locking, isolation) | FR-TRF-003, FR-TRF-009, INV-2, NFR-REL-003 |
| LO-3 (queue) | FR-JOB-001 to FR-JOB-008 |
| LO-4 (constraints) | INV-3, INV-5, INV-6, INV-10 |
| LO-5 (OUTPUT, atomic transitions) | FR-TRF-009, FR-JOB-002, FR-REV-003 |
| LO-6, LO-7 (windows, indexing) | FR-STM-001 to FR-STM-004, NFR-PERF-003, NFR-PERF-005 |
| LO-8 (stored procedures) | NFR-MNT-002 |
| LO-11 (Gin) | FR-AUTH, FR-OPS-002, error model |
| LO-12 (concurrency, shutdown) | FR-JOB-007, FR-OPS-004 |
| LO-13 (exact money) | FR-FX-005, INV-9 |
| LO-14 (testing) | NFR-TST-001 to NFR-TST-005 |
| G4 (prove correctness) | Section 6, FR-OPS-005 |
