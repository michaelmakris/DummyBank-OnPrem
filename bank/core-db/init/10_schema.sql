-- Dummy bank core database: customers, bureau reports, accounts, public records, and the
-- risk data warehouse table the credit engine reads directly (read-only, TLS).
-- Runs once when the volume is created. Passwords come from the secret files.

CREATE SCHEMA core;
CREATE SCHEMA risk;

CREATE TABLE core.customers (
    customer_id         text PRIMARY KEY,
    first_name          text NOT NULL,
    last_name           text NOT NULL,
    date_of_birth       date NOT NULL,
    employment_type     text NOT NULL,
    net_monthly_income  numeric(12, 2) NOT NULL,
    monthly_debt_payments numeric(12, 2) NOT NULL
);

CREATE TABLE core.bureau_reports (
    customer_id   text PRIMARY KEY REFERENCES core.customers,
    bureau_score  integer,                 -- NULL: no score (thin file)
    as_of         date NOT NULL
);

CREATE TABLE core.accounts (
    account_id      text PRIMARY KEY,
    customer_id     text NOT NULL REFERENCES core.customers,
    product         text NOT NULL,
    status          text NOT NULL,         -- CURRENT | ARREARS_30 | ARREARS_60 | WRITTEN_OFF
    balance         numeric(12, 2) NOT NULL,
    monthly_payment numeric(12, 2) NOT NULL
);

CREATE TABLE core.public_records (
    customer_id  text PRIMARY KEY REFERENCES core.customers,
    bankruptcy   boolean NOT NULL
);

-- Daily exposure snapshot in the risk data warehouse (one row per customer per day).
CREATE TABLE risk.customer_exposure_daily (
    customer_id     text NOT NULL,
    as_of_date      date NOT NULL,
    total_exposure  numeric(14, 2) NOT NULL,
    PRIMARY KEY (customer_id, as_of_date)
);
