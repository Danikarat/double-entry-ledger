-- +goose Up
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
    fx_rate_id              BIGINT        NULL,       -- FK added in the M4 migration
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
        (transfer_type <> 'REVERSAL' AND reverses_transfer_id IS NULL)),
    -- M1 only supports same-currency transfers; DROP this constraint in the M4 (FX) migration
    CONSTRAINT ck_transfers_same_currency CHECK (source_currency = destination_currency)
);

-- ux_transfers_reverses is added in M3 (0006); fk_transfers_fx_rate is added in M4 (0007)
CREATE INDEX ix_transfers_source ON transfers (source_account_id, created_at DESC, id DESC);
CREATE INDEX ix_transfers_dest   ON transfers (destination_account_id, created_at DESC, id DESC);
CREATE INDEX ix_transfers_status ON transfers (status, created_at);

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
CREATE INDEX ix_ledger_account  ON ledger_entries (account_id, id) INCLUDE (amount);
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

-- +goose Down
-- +goose StatementBegin
DROP TRIGGER tr_ledger_entries_append_only;
-- +goose StatementEnd
DROP TABLE ledger_entries;   -- must go first: it references transfers
DROP TABLE transfers;