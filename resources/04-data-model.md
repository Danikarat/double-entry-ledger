# Data Model: Ledger API (SQL Server)

Version 1.0. This is the **target schema** for the finished system. Migrations land it in pieces by milestone (section 9). Where this document and the SRS disagree, the SRS wins.

---

## 1. Conventions

| Topic | Rule |
|-------|------|
| Money | `BIGINT` minor units. Never `FLOAT`, `REAL`, `MONEY`, or `DECIMAL` for amounts. Rates use `DECIMAL(18,8)` |
| Time | `DATETIME2(3)`, UTC, defaulted with `SYSUTCDATETIME()` |
| Strings | `NVARCHAR` for human text; `VARCHAR`/`CHAR` for codes and enums |
| IDs | `UNIQUEIDENTIFIER` with `NEWSEQUENTIALID()` default for accounts and transfers (avoids index fragmentation; it works only as a column default). `BIGINT IDENTITY` for entries, holds, jobs, rates |
| Enums | `VARCHAR` plus a named `CHECK` constraint |
| Names | `pk_`, `fk_`, `uq_`, `ck_`, `df_`, `ix_`, `ux_` prefixes; constraints are always named |
| Nulls | Columns are `NOT NULL` unless there is a reason, documented in a comment |
| goose | Migrations containing triggers, views, or procedures wrap each statement in `-- +goose StatementBegin` / `-- +goose StatementEnd` |

## 2. Entity overview

```
currencies 1───* accounts 1───* ledger_entries *───1 transfers 1───1 holds (M2)
     │               │                                  │   │
     │               └── (system_role per currency)     │   └──1 transfer_jobs (M2)
     └───* fx_rates (M4)                                └── reverses_transfer_id ──► transfers (M3)
```

## 3. Schema

### 3.1 `currencies` (M1)

```sql
CREATE TABLE currencies (
    code        CHAR(3)       NOT NULL CONSTRAINT pk_currencies PRIMARY KEY,
    name        NVARCHAR(100) NOT NULL,
    exponent    TINYINT       NOT NULL,
    created_at  DATETIME2(3)  NOT NULL CONSTRAINT df_currencies_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_currencies_exponent CHECK (exponent BETWEEN 0 AND 4),
    CONSTRAINT ck_currencies_code CHECK (code = UPPER(code) AND code NOT LIKE '%[^A-Z]%')
);
```

### 3.2 `accounts` (M1)

```sql
CREATE TABLE accounts (
    id            UNIQUEIDENTIFIER NOT NULL
                  CONSTRAINT df_accounts_id DEFAULT NEWSEQUENTIALID()
                  CONSTRAINT pk_accounts PRIMARY KEY,
    name          NVARCHAR(200)    NOT NULL,
    currency      CHAR(3)          NOT NULL CONSTRAINT fk_accounts_currency REFERENCES currencies(code),
    account_type  VARCHAR(10)      NOT NULL,
    system_role   VARCHAR(20)      NULL,    -- only for SYSTEM accounts
    created_at    DATETIME2(3)     NOT NULL CONSTRAINT df_accounts_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_accounts_type CHECK (account_type IN ('CUSTOMER','SYSTEM')),
    CONSTRAINT ck_accounts_role CHECK (system_role IN ('EXTERNAL','FX_CLEARING')),
    CONSTRAINT ck_accounts_type_role CHECK (
        (account_type = 'CUSTOMER' AND system_role IS NULL) OR
        (account_type = 'SYSTEM'   AND system_role IS NOT NULL)),
    -- target of the composite FK from ledger_entries (INV-10)
    CONSTRAINT uq_accounts_id_currency UNIQUE (id, currency)
);

-- exactly one EXTERNAL and one FX_CLEARING per currency
CREATE UNIQUE INDEX ux_accounts_system_role
    ON accounts (currency, system_role) WHERE system_role IS NOT NULL;

CREATE INDEX ix_accounts_currency ON accounts (currency, id);
```

### 3.3 `fx_rates` (M4)

Append-only: a correction is a newer row.

```sql
CREATE TABLE fx_rates (
    id              BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_fx_rates PRIMARY KEY,
    base_currency   CHAR(3)       NOT NULL CONSTRAINT fk_fx_base  REFERENCES currencies(code),
    quote_currency  CHAR(3)       NOT NULL CONSTRAINT fk_fx_quote REFERENCES currencies(code),
    rate            DECIMAL(18,8) NOT NULL,       -- units of quote per 1 unit of base (major units)
    source          VARCHAR(50)   NOT NULL,       -- 'MANUAL' or 'PROVIDER:<name>'
    effective_at    DATETIME2(3)  NOT NULL,
    created_at      DATETIME2(3)  NOT NULL CONSTRAINT df_fx_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_fx_rate_positive CHECK (rate > 0),
    CONSTRAINT ck_fx_distinct CHECK (base_currency <> quote_currency)
);

CREATE INDEX ix_fx_pair_effective
    ON fx_rates (base_currency, quote_currency, effective_at DESC, id DESC) INCLUDE (rate);
```

### 3.4 `transfers` (M1; columns for later milestones are created early as nullable)

```sql
CREATE TABLE transfers (
    id                      UNIQUEIDENTIFIER NOT NULL
                            CONSTRAINT df_transfers_id DEFAULT NEWSEQUENTIALID()
                            CONSTRAINT pk_transfers PRIMARY KEY,
    transfer_type           VARCHAR(12)   NOT NULL,
    status                  VARCHAR(10)   NOT NULL,
    failure_reason          VARCHAR(30)   NULL,
    idempotency_key         NVARCHAR(100) NOT NULL,
    request_hash            CHAR(64)      NOT NULL,   -- hex SHA-256
    source_account_id       UNIQUEIDENTIFIER NOT NULL CONSTRAINT fk_transfers_src REFERENCES accounts(id),
    destination_account_id  UNIQUEIDENTIFIER NOT NULL CONSTRAINT fk_transfers_dst REFERENCES accounts(id),
    source_currency         CHAR(3)       NOT NULL,
    destination_currency    CHAR(3)       NOT NULL,
    source_amount           BIGINT        NOT NULL,
    destination_amount      BIGINT        NULL,       -- set at submission if same currency; at posting if FX
    fx_rate                 DECIMAL(18,8) NULL,       -- snapshot (M4)
    fx_rate_id              BIGINT        NULL,       -- FK added in M4 migration
    reverses_transfer_id    UNIQUEIDENTIFIER NULL CONSTRAINT fk_transfers_reverses REFERENCES transfers(id), -- M3
    reference               NVARCHAR(200) NULL,
    created_at              DATETIME2(3)  NOT NULL CONSTRAINT df_transfers_created DEFAULT SYSUTCDATETIME(),
    updated_at              DATETIME2(3)  NOT NULL CONSTRAINT df_transfers_updated DEFAULT SYSUTCDATETIME(),
    posted_at               DATETIME2(3)  NULL,
    CONSTRAINT uq_transfers_idempotency UNIQUE (idempotency_key),
    CONSTRAINT ck_transfers_type   CHECK (transfer_type IN ('TRANSFER','DEPOSIT','WITHDRAWAL','REVERSAL')),
    CONSTRAINT ck_transfers_status CHECK (status IN ('PENDING','POSTED','FAILED','REVERSED')),
    CONSTRAINT ck_transfers_reason CHECK (
        failure_reason IS NULL OR failure_reason IN
        ('FX_RATE_UNAVAILABLE','FX_RATE_STALE','AMOUNT_TOO_SMALL','PROCESSING_ERROR')),
    CONSTRAINT ck_transfers_reason_status CHECK (
        (status = 'FAILED' AND failure_reason IS NOT NULL) OR
        (status <> 'FAILED' AND failure_reason IS NULL)),
    CONSTRAINT ck_transfers_distinct CHECK (source_account_id <> destination_account_id),
    CONSTRAINT ck_transfers_src_amount CHECK (source_amount > 0),
    CONSTRAINT ck_transfers_dst_amount CHECK (destination_amount IS NULL OR destination_amount > 0),
    CONSTRAINT ck_transfers_posted_fields CHECK (
        status NOT IN ('POSTED','REVERSED') OR (destination_amount IS NOT NULL AND posted_at IS NOT NULL)),
    CONSTRAINT ck_transfers_reversal_link CHECK (
        (transfer_type = 'REVERSAL' AND reverses_transfer_id IS NOT NULL) OR
        (transfer_type <> 'REVERSAL' AND reverses_transfer_id IS NULL))
);

-- M3: at most one non-failed reversal per original (INV-5)
CREATE UNIQUE INDEX ux_transfers_reverses
    ON transfers (reverses_transfer_id)
    WHERE reverses_transfer_id IS NOT NULL AND status <> 'FAILED';

CREATE INDEX ix_transfers_source ON transfers (source_account_id, created_at DESC, id DESC);
CREATE INDEX ix_transfers_dest   ON transfers (destination_account_id, created_at DESC, id DESC);
CREATE INDEX ix_transfers_status ON transfers (status, created_at);

-- M4 migration
ALTER TABLE transfers ADD CONSTRAINT fk_transfers_fx_rate
    FOREIGN KEY (fx_rate_id) REFERENCES fx_rates(id);
```

### 3.5 `ledger_entries` (M1)

```sql
CREATE TABLE ledger_entries (
    id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_ledger_entries PRIMARY KEY,
    transfer_id  UNIQUEIDENTIFIER NOT NULL CONSTRAINT fk_ledger_transfer REFERENCES transfers(id),
    account_id   UNIQUEIDENTIFIER NOT NULL,
    currency     CHAR(3)          NOT NULL,
    amount       BIGINT           NOT NULL,     -- signed: debit < 0, credit > 0
    created_at   DATETIME2(3)     NOT NULL CONSTRAINT df_ledger_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_ledger_amount_nonzero CHECK (amount <> 0),
    -- INV-10: the entry's currency must equal the account's currency
    CONSTRAINT fk_ledger_account_currency
        FOREIGN KEY (account_id, currency) REFERENCES accounts (id, currency)
);

-- covering index for balance and statement queries
CREATE INDEX ix_ledger_account ON ledger_entries (account_id, id) INCLUDE (amount);
CREATE INDEX ix_ledger_transfer ON ledger_entries (transfer_id);
CREATE INDEX ix_ledger_currency ON ledger_entries (currency) INCLUDE (amount);  -- invariant checks

-- INV-3: append-only
-- +goose StatementBegin
CREATE TRIGGER tr_ledger_entries_append_only
ON ledger_entries
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51000, 'ledger_entries is append-only', 1;
END;
-- +goose StatementEnd
```

### 3.6 `holds` (M2)

```sql
CREATE TABLE holds (
    id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_holds PRIMARY KEY,
    transfer_id  UNIQUEIDENTIFIER NOT NULL
                 CONSTRAINT uq_holds_transfer UNIQUE
                 CONSTRAINT fk_holds_transfer REFERENCES transfers(id),
    account_id   UNIQUEIDENTIFIER NOT NULL CONSTRAINT fk_holds_account REFERENCES accounts(id),
    currency     CHAR(3)          NOT NULL,
    amount       BIGINT           NOT NULL,
    status       VARCHAR(10)      NOT NULL,
    created_at   DATETIME2(3)     NOT NULL CONSTRAINT df_holds_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)     NOT NULL CONSTRAINT df_holds_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_holds_amount CHECK (amount > 0),
    CONSTRAINT ck_holds_status CHECK (status IN ('ACTIVE','CAPTURED','RELEASED'))
);

-- small, hot index: only active holds
CREATE INDEX ix_holds_active ON holds (account_id) INCLUDE (amount) WHERE status = 'ACTIVE';
```

### 3.7 `transfer_jobs` (M2)

```sql
CREATE TABLE transfer_jobs (
    id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_transfer_jobs PRIMARY KEY,
    transfer_id   UNIQUEIDENTIFIER NOT NULL
                  CONSTRAINT uq_jobs_transfer UNIQUE
                  CONSTRAINT fk_jobs_transfer REFERENCES transfers(id),
    status        VARCHAR(12)   NOT NULL,
    attempts      INT           NOT NULL CONSTRAINT df_jobs_attempts DEFAULT 0,
    available_at  DATETIME2(3)  NOT NULL CONSTRAINT df_jobs_available DEFAULT SYSUTCDATETIME(),
    locked_until  DATETIME2(3)  NULL,
    locked_by     NVARCHAR(100) NULL,
    last_error    NVARCHAR(1000) NULL,
    created_at    DATETIME2(3)  NOT NULL CONSTRAINT df_jobs_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NOT NULL CONSTRAINT df_jobs_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_jobs_status CHECK (status IN ('QUEUED','PROCESSING','DONE','DEAD')),
    CONSTRAINT ck_jobs_attempts CHECK (attempts >= 0)
);

-- claimable work: queued by availability, processing by lease expiry
CREATE INDEX ix_jobs_queued ON transfer_jobs (available_at, id) WHERE status = 'QUEUED';
CREATE INDEX ix_jobs_leased ON transfer_jobs (locked_until, id) WHERE status = 'PROCESSING';
```

## 4. Views

M1 version (migration 0004; the `holds` table does not exist yet, so held is a constant 0):

```sql
CREATE VIEW vw_account_balances AS
SELECT  a.id AS account_id,
        a.currency,
        COALESCE(l.total, 0) AS ledger_balance,
        CAST(0 AS BIGINT)    AS held_amount,
        COALESCE(l.total, 0) AS available_balance
FROM accounts a
OUTER APPLY (SELECT SUM(e.amount) AS total FROM ledger_entries e WHERE e.account_id = a.id) l;
```

M2 version (migration 0005 drops and recreates the view with holds):

```sql
CREATE VIEW vw_account_balances AS
SELECT  a.id AS account_id,
        a.currency,
        COALESCE(l.total, 0)                      AS ledger_balance,
        COALESCE(h.held, 0)                       AS held_amount,
        COALESCE(l.total, 0) - COALESCE(h.held, 0) AS available_balance
FROM accounts a
OUTER APPLY (SELECT SUM(e.amount) AS total FROM ledger_entries e WHERE e.account_id = a.id) l
OUTER APPLY (SELECT SUM(x.amount) AS held  FROM holds x
             WHERE x.account_id = a.id AND x.status = 'ACTIVE') h;

-- human-readable ledger for debugging (M4: uses currencies.exponent)
CREATE VIEW vw_ledger_readable AS
SELECT  e.id, e.transfer_id, e.account_id, e.currency,
        CAST(e.amount AS DECIMAL(38,6)) / POWER(CAST(10 AS DECIMAL(38,6)), c.exponent) AS amount_major,
        e.created_at
FROM ledger_entries e JOIN currencies c ON c.code = e.currency;
```

## 5. Canonical queries

These are the patterns the repositories implement. Parameters use `@name` for clarity; in Go use `sql.Named` or positional placeholders as the driver requires.

### 5.1 Place a debit: lock, check, create (request path, one transaction)

```sql
BEGIN TRANSACTION;

-- serialize debits for this account (ADR-004)
SELECT id FROM accounts WITH (UPDLOCK, ROWLOCK) WHERE id = @source_account_id;

DECLARE @ledger BIGINT = (SELECT COALESCE(SUM(amount), 0) FROM ledger_entries WHERE account_id = @source_account_id);
DECLARE @held   BIGINT = (SELECT COALESCE(SUM(amount), 0) FROM holds
                          WHERE account_id = @source_account_id AND status = 'ACTIVE');

IF (@ledger - @held) < @amount
BEGIN
    ROLLBACK TRANSACTION;
    -- return available = @ledger - @held to the caller; map to INSUFFICIENT_FUNDS
END
ELSE
BEGIN
    -- may raise 2627/2601 on idempotency_key: caller handles replay logic (ADR-009)
    INSERT INTO transfers (...) OUTPUT inserted.id VALUES (...);
    INSERT INTO holds (transfer_id, account_id, currency, amount, status) VALUES (@transfer_id, ..., 'ACTIVE');
    INSERT INTO transfer_jobs (transfer_id, status) VALUES (@transfer_id, 'QUEUED');
    COMMIT TRANSACTION;
END
```

In M1 (synchronous) the same lock and check run, but instead of hold and job the entries are inserted and the transfer is created as `POSTED` in the same transaction.

### 5.2 Detecting duplicates

go-mssqldb returns `mssql.Error` with `Number` 2627 (unique constraint) or 2601 (unique index) on a duplicate `idempotency_key` or duplicate reversal. For `uq_transfers_idempotency` load the existing row and compare `request_hash`. For `ux_transfers_reverses` return `ALREADY_REVERSED`. Deadlock is `1205`.

### 5.3 Claim a job (worker)

```sql
;WITH next AS (
    SELECT TOP (1) *
    FROM transfer_jobs WITH (UPDLOCK, READPAST, ROWLOCK)
    WHERE (status = 'QUEUED'     AND available_at <= SYSUTCDATETIME())
       OR (status = 'PROCESSING' AND locked_until <  SYSUTCDATETIME())
    ORDER BY id
)
UPDATE next
SET status       = 'PROCESSING',
    attempts     = attempts + 1,
    locked_until = DATEADD(SECOND, @lease_seconds, SYSUTCDATETIME()),
    locked_by    = @worker_id,
    updated_at   = SYSUTCDATETIME()
OUTPUT inserted.id, inserted.transfer_id, inserted.attempts;
```

Zero rows returned means no work: sleep with jitter (for example 50 to 250 ms) and poll again.

### 5.4 Post a same-currency transfer (worker, one transaction)

```sql
BEGIN TRANSACTION;

DECLARE @status VARCHAR(10);
SELECT @status = status FROM transfers WITH (UPDLOCK, ROWLOCK) WHERE id = @transfer_id;

IF @status = 'PENDING'
BEGIN
    INSERT INTO ledger_entries (transfer_id, account_id, currency, amount) VALUES
        (@transfer_id, @source_account_id,      @currency, -@amount),
        (@transfer_id, @destination_account_id, @currency,  @amount);

    UPDATE holds SET status = 'CAPTURED', updated_at = SYSUTCDATETIME()
    WHERE transfer_id = @transfer_id AND status = 'ACTIVE';

    UPDATE transfers
    SET status = 'POSTED', destination_amount = source_amount,
        posted_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
    WHERE id = @transfer_id AND status = 'PENDING';
END

UPDATE transfer_jobs SET status = 'DONE', updated_at = SYSUTCDATETIME() WHERE id = @job_id;
COMMIT TRANSACTION;
```

Cross-currency posting adds the two clearing entries and the rate snapshot (`fx_rate`, `fx_rate_id`, `destination_amount`). Reversal posting inserts the negation of the original's entries and updates the original (`WHERE id = @original AND status = 'POSTED'`) to `REVERSED`.

### 5.5 Reversal entries (negate the original)

```sql
INSERT INTO ledger_entries (transfer_id, account_id, currency, amount)
SELECT @reversal_id, account_id, currency, -amount
FROM ledger_entries
WHERE transfer_id = @original_id;
```

### 5.6 Effective FX rate

```sql
SELECT TOP (1) id, rate, effective_at
FROM fx_rates
WHERE base_currency = @base AND quote_currency = @quote
  AND effective_at <= SYSUTCDATETIME()
ORDER BY effective_at DESC, id DESC;
```

### 5.7 Statement with running balance (M3)

```sql
;WITH running AS (
    SELECT  e.id, e.transfer_id, e.amount, e.created_at,
            SUM(e.amount) OVER (ORDER BY e.id ROWS UNBOUNDED PRECEDING) AS running_balance
    FROM ledger_entries e
    WHERE e.account_id = @account_id
)
SELECT TOP (@limit)
       r.id, r.transfer_id, t.transfer_type, r.amount, r.running_balance, t.reference, r.created_at
FROM running r
JOIN transfers t ON t.id = r.transfer_id
WHERE r.id > @cursor
  AND r.created_at >= @from AND r.created_at < @to
ORDER BY r.id;
```

Notes for the implementer:
- Use `ROWS UNBOUNDED PRECEDING` explicitly. The default frame with `ORDER BY` is `RANGE`, which is slower and spills to disk.
- The window is computed over all of the account's entries and filtered afterward, which keeps `running_balance` correct for any window or page (FR-STM-003). Compare the plan with an alternative that computes an opening balance and windows only the page; record the findings (LO-7).
- `opening_balance` is the balance immediately before the first returned line (`running_balance - amount` of that line); if no lines are returned, it is `SUM(amount)` of entries before `@from`. `closing_balance` is the `running_balance` of the last returned line.

### 5.8 Keyset pagination for lists

Order by `(created_at DESC, id DESC)` and use the last row's pair as the cursor:

```sql
WHERE (created_at < @c_created_at) OR (created_at = @c_created_at AND id < @c_id)
ORDER BY created_at DESC, id DESC
```

Cursors are opaque to clients (base64 of the pair).

## 6. Index rationale

| Index | Serves | Why |
|-------|--------|-----|
| `ix_ledger_account (account_id, id) INCLUDE (amount)` | Balance, statement, window | Covers `SUM(amount)` per account with no key lookups |
| `ix_holds_active` (filtered) | Available balance | Stays tiny because only active holds are indexed |
| `ux_transfers_reverses` (filtered unique) | INV-5 | Enforces one live reversal per transfer, ignoring failed attempts |
| `ux_accounts_system_role` (filtered unique) | One `EXTERNAL` and one `FX_CLEARING` per currency | Structural guarantee |
| `ix_jobs_queued`, `ix_jobs_leased` (filtered) | Job claim | Narrow, ordered access to claimable rows |
| `ix_fx_pair_effective` | Rate lookup | Single seek for the latest effective rate |
| `ix_transfers_source/dest/status` | Lists and filters | Keyset pagination without sorts |

Each index above must be justified by an execution plan captured in `docs/notes/query-plans.md` during M3 and M5.

## 7. Invariant queries (used by `cmd/invariants`)

Each query must return **zero rows** on a healthy database. The checker runs all and reports each non-empty result.

```sql
-- INV-1: every currency sums to zero
SELECT currency, SUM(amount) AS total
FROM ledger_entries GROUP BY currency HAVING SUM(amount) <> 0;

-- INV-2: no negative customer balances (ledger or available)
SELECT b.account_id, b.ledger_balance, b.available_balance
FROM vw_account_balances b JOIN accounts a ON a.id = b.account_id
WHERE a.account_type = 'CUSTOMER' AND (b.ledger_balance < 0 OR b.available_balance < 0);

-- INV-4a: posted or reversed transfers must have entries
SELECT t.id FROM transfers t
WHERE t.status IN ('POSTED','REVERSED')
  AND NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.transfer_id = t.id);

-- INV-4b: entries only for posted or reversed transfers
SELECT DISTINCT e.transfer_id FROM ledger_entries e
JOIN transfers t ON t.id = e.transfer_id
WHERE t.status NOT IN ('POSTED','REVERSED');

-- INV-4c: each transfer's entries sum to zero per currency
SELECT transfer_id, currency, SUM(amount) AS total
FROM ledger_entries GROUP BY transfer_id, currency HAVING SUM(amount) <> 0;

-- INV-5a: no original reversed more than once (non-failed)
SELECT reverses_transfer_id, COUNT(*) AS n FROM transfers
WHERE reverses_transfer_id IS NOT NULL AND status <> 'FAILED'
GROUP BY reverses_transfer_id HAVING COUNT(*) > 1;

-- INV-5b: an original is REVERSED if and only if a POSTED reversal exists
SELECT o.id FROM transfers o
WHERE (o.status = 'REVERSED' AND NOT EXISTS (
          SELECT 1 FROM transfers r WHERE r.reverses_transfer_id = o.id AND r.status = 'POSTED'))
   OR (o.status <> 'REVERSED' AND EXISTS (
          SELECT 1 FROM transfers r WHERE r.reverses_transfer_id = o.id AND r.status = 'POSTED'));

-- INV-7a: active holds only on pending transfers
SELECT h.id FROM holds h JOIN transfers t ON t.id = h.transfer_id
WHERE h.status = 'ACTIVE' AND t.status <> 'PENDING';

-- INV-7b: each pending debit from a customer has an active hold
SELECT t.id FROM transfers t JOIN accounts s ON s.id = t.source_account_id
WHERE t.status = 'PENDING' AND s.account_type = 'CUSTOMER'
  AND NOT EXISTS (SELECT 1 FROM holds h WHERE h.transfer_id = t.id AND h.status = 'ACTIVE');

-- INV-7c: terminal transfers have terminal holds
SELECT h.id FROM holds h JOIN transfers t ON t.id = h.transfer_id
WHERE (t.status IN ('POSTED','REVERSED') AND h.status <> 'CAPTURED')
   OR (t.status = 'FAILED' AND h.status <> 'RELEASED');

-- INV-8: reversal entries are the exact negation of the original's
SELECT r.id FROM transfers r
WHERE r.transfer_type = 'REVERSAL' AND r.status = 'POSTED'
  AND ( EXISTS (SELECT account_id, currency, amount  FROM ledger_entries WHERE transfer_id = r.reverses_transfer_id
                EXCEPT
                SELECT account_id, currency, -amount FROM ledger_entries WHERE transfer_id = r.id)
     OR EXISTS (SELECT account_id, currency, -amount FROM ledger_entries WHERE transfer_id = r.id
                EXCEPT
                SELECT account_id, currency, amount  FROM ledger_entries WHERE transfer_id = r.reverses_transfer_id));

-- Job consistency: every PENDING transfer has a live job; no live job for a non-pending transfer
SELECT t.id FROM transfers t
WHERE t.status = 'PENDING'
  AND NOT EXISTS (SELECT 1 FROM transfer_jobs j WHERE j.transfer_id = t.id AND j.status IN ('QUEUED','PROCESSING'));

SELECT j.id FROM transfer_jobs j JOIN transfers t ON t.id = j.transfer_id
WHERE j.status IN ('QUEUED','PROCESSING') AND t.status <> 'PENDING';
```

Quiescence note: the job-consistency and hold queries can show transient rows while workers are mid-transaction. Concurrency tests run the checker only after all jobs reach a terminal state.

## 8. Seed data (M1)

```sql
INSERT INTO currencies (code, name, exponent) VALUES
    ('GHS', N'Ghana Cedi', 2), ('USD', N'US Dollar', 2), ('EUR', N'Euro', 2),
    ('GBP', N'Pound Sterling', 2), ('JPY', N'Japanese Yen', 0);

-- one EXTERNAL and one FX_CLEARING account per seeded currency
INSERT INTO accounts (name, currency, account_type, system_role)
SELECT CONCAT(r.role_name, N' ', c.code), c.code, 'SYSTEM', r.role_code
FROM currencies c
CROSS JOIN (VALUES (N'External', 'EXTERNAL'), (N'FX Clearing', 'FX_CLEARING')) AS r(role_name, role_code);
```

`POST /v1/currencies` performs the equivalent for a new currency in one transaction.

## 9. Migration plan

| Migration | Milestone | Contents |
|-----------|-----------|----------|
| `0001_currencies_accounts.sql` | M1 | `currencies`, `accounts` and their indexes |
| `0002_transfers_ledger.sql` | M1 | `transfers` (with nullable M3/M4 columns), `ledger_entries`, append-only trigger |
| `0003_seed_currencies.sql` | M1 | Seed data (section 8) |
| `0004_balance_view.sql` | M1 | `vw_account_balances` (M1 version: held is constant 0) |
| `0005_holds_jobs.sql` | M2 | `holds`, `transfer_jobs`, replace `vw_account_balances` with the holds-aware version |
| `0006_reversals.sql` | M3 | `ux_transfers_reverses` |
| `0007_fx.sql` | M4 | `fx_rates`, FK `fk_transfers_fx_rate`, `vw_ledger_readable` |
| `0008_sproc_post_transfer.sql` | M5 | `usp_post_transfer` (and `usp_reverse_transfer` if time allows) |

Every migration has a working `Down`. CI applies all migrations up from empty, then runs the integration suite.
