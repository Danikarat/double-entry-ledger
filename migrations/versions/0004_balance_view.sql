-- +goose Up
-- M1 version: the holds table does not exist yet, so held_amount is a constant 0.
-- M2 (0005) drops and recreates this view with the holds-aware version.
-- +goose StatementBegin
CREATE VIEW vw_account_balances AS
SELECT  a.id AS account_id,
        a.currency,
        COALESCE(l.total, 0) AS ledger_balance,
        CAST(0 AS BIGINT)    AS held_amount,
        COALESCE(l.total, 0) AS available_balance
FROM accounts a
OUTER APPLY (SELECT SUM(e.amount) AS total FROM ledger_entries e WHERE e.account_id = a.id) l;
-- +goose StatementEnd

-- +goose Down
DROP VIEW vw_account_balances;