-- +goose Up
INSERT INTO currencies (code, name, exponent) VALUES
    ('GHS', N'Ghana Cedi', 2), ('USD', N'US Dollar', 2), ('EUR', N'Euro', 2),
    ('GBP', N'Pound Sterling', 2), ('JPY', N'Japanese Yen', 0);

-- one EXTERNAL and one FX_CLEARING account per seeded currency
INSERT INTO accounts (name, currency, account_type, system_role)
SELECT CONCAT(r.role_name, N' ', c.code), c.code, 'SYSTEM', r.role_code
FROM currencies c
CROSS JOIN (VALUES (N'External', 'EXTERNAL'), (N'FX Clearing', 'FX_CLEARING')) AS r(role_name, role_code);

-- +goose Down
-- Only works while no transfers or ledger entries reference these accounts (fine in dev).
DELETE FROM accounts
WHERE account_type = 'SYSTEM' AND currency IN ('GHS','USD','EUR','GBP','JPY');
DELETE FROM currencies
WHERE code IN ('GHS','USD','EUR','GBP','JPY');