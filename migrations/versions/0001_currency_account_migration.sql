-- +goose Up
CREATE TABLE currencies (
    code        CHAR(3)       NOT NULL CONSTRAINT pk_currencies PRIMARY KEY,
    name        NVARCHAR(100) NOT NULL,
    exponent    TINYINT       NOT NULL,
    created_at  DATETIME2(3)  NOT NULL CONSTRAINT df_currencies_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_currencies_exponent CHECK (exponent BETWEEN 0 AND 4),
    -- binary collation: the default (case-insensitive) collation would accept lowercase letters
    CONSTRAINT ck_currencies_code CHECK (code COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^A-Z]%')
);

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

-- +goose Down
DROP TABLE accounts;     -- its indexes are dropped with it
DROP TABLE currencies;