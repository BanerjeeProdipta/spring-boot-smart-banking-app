CREATE TABLE customers (
    id          BIGSERIAL PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    email       VARCHAR(255) NOT NULL,
    kyc_status  VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT ck_customers_kyc_status CHECK (kyc_status IN ('PENDING', 'VERIFIED', 'REJECTED'))
);

CREATE TABLE accounts (
    id           BIGSERIAL PRIMARY KEY,
    customer_id  BIGINT NOT NULL REFERENCES customers (id),
    type         VARCHAR(20) NOT NULL,
    balance      NUMERIC(19, 2) NOT NULL DEFAULT 0,
    currency     VARCHAR(3) NOT NULL DEFAULT 'CAD',
    status       VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    version      BIGINT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_accounts_type CHECK (type IN ('CHECKING', 'SAVINGS')),
    CONSTRAINT ck_accounts_status CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    CONSTRAINT ck_accounts_balance_non_negative CHECK (balance >= 0)
);

CREATE INDEX ix_accounts_customer_id ON accounts (customer_id);

CREATE TABLE transactions (
    id                     BIGSERIAL PRIMARY KEY,
    account_id             BIGINT NOT NULL REFERENCES accounts (id),
    counterparty_account_id BIGINT REFERENCES accounts (id),
    transfer_id            UUID,
    type                   VARCHAR(20) NOT NULL,
    amount                 NUMERIC(19, 2) NOT NULL,
    status                 VARCHAR(20) NOT NULL DEFAULT 'COMPLETED',
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_transactions_type CHECK (type IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER_OUT', 'TRANSFER_IN')),
    CONSTRAINT ck_transactions_status CHECK (status IN ('COMPLETED', 'FLAGGED', 'FAILED')),
    CONSTRAINT ck_transactions_amount_positive CHECK (amount > 0)
);

CREATE INDEX ix_transactions_account_id_created_at ON transactions (account_id, created_at DESC);
CREATE INDEX ix_transactions_transfer_id ON transactions (transfer_id);
