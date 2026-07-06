/* ============================================================================
   FILE:        schema.sql
   PROJECT:     Bank Credit Risk & Collections Analytics
   PURPOSE:     Defines the full database schema for the project — a raw
                staging table (mirrors the source CSV) plus a normalized
                star-schema layer (dimension + fact tables) used for all
                downstream risk segmentation, collections, and KPI queries.
   DIALECT:     PostgreSQL 13+ (ANSI-standard; minor tweaks needed for
                MySQL / SQL Server — see notes inline)
   SOURCE DATA: Default of Credit Card Clients Dataset
                Yeh, I.C. & Lien, C.H. (2009) — UCI Machine Learning Repository
   ============================================================================ */

-- Drop tables in dependency order (safe re-run during development)
DROP TABLE IF EXISTS fact_credit_risk;
DROP TABLE IF EXISTS fact_statements;
DROP TABLE IF EXISTS fact_repayment_history;
DROP TABLE IF EXISTS dim_customers;
DROP TABLE IF EXISTS staging_raw_credit_data;

-- ============================================================================
-- 1. STAGING LAYER — mirrors the raw source CSV exactly (1 row per customer,
--    6 months of history stored wide). This is the landing zone for a
--    COPY / BULK INSERT / ETL load job before cleaning & normalization.
-- ============================================================================
CREATE TABLE staging_raw_credit_data (
    customer_id       SERIAL PRIMARY KEY,
    credit_limit      NUMERIC(14,2)   NOT NULL,
    gender            VARCHAR(10),
    education         VARCHAR(20),
    marital_status    VARCHAR(20),
    age               SMALLINT,
    -- Repayment status codes, most recent (1) to oldest (6) statement month
    -- Raw codes: 'm-2'/'m-1' = paid duly/early, 'm+0' = paid on time,
    -- 'm+1'..'m+8' = number of months delinquent
    timeliness_1      VARCHAR(5),
    timeliness_2      VARCHAR(5),
    timeliness_3      VARCHAR(5),
    timeliness_4      VARCHAR(5),
    timeliness_5      VARCHAR(5),
    timeliness_6      VARCHAR(5),
    balance_1         NUMERIC(14,2),
    balance_2         NUMERIC(14,2),
    balance_3         NUMERIC(14,2),
    balance_4         NUMERIC(14,2),
    balance_5         NUMERIC(14,2),
    balance_6         NUMERIC(14,2),
    payment_1         NUMERIC(14,2),
    payment_2         NUMERIC(14,2),
    payment_3         NUMERIC(14,2),
    payment_4         NUMERIC(14,2),
    payment_5         NUMERIC(14,2),
    payment_6         NUMERIC(14,2),
    avg_balance       NUMERIC(14,2),
    avg_payment       NUMERIC(14,2),
    default_raw       VARCHAR(5)      -- 'yes' / 'no'
);

COMMENT ON TABLE staging_raw_credit_data IS
  'Raw landing table — 1:1 with source CSV. Never queried directly by analysts; feeds data_cleaning.sql transformations.';

-- ============================================================================
-- 2. DIMENSION LAYER — cleaned, standardized customer attributes
-- ============================================================================
CREATE TABLE dim_customers (
    customer_id         INT PRIMARY KEY REFERENCES staging_raw_credit_data(customer_id),
    credit_limit        NUMERIC(14,2) NOT NULL,
    credit_limit_band   VARCHAR(20)   NOT NULL,
    gender              VARCHAR(10),
    education           VARCHAR(20),
    marital_status      VARCHAR(20),
    age                 SMALLINT,
    age_band            VARCHAR(10)
);

CREATE INDEX idx_dim_customers_credit_limit_band ON dim_customers(credit_limit_band);
CREATE INDEX idx_dim_customers_age_band          ON dim_customers(age_band);
CREATE INDEX idx_dim_customers_education         ON dim_customers(education);

-- ============================================================================
-- 3. FACT LAYER — repayment history, unpivoted (1 row per customer per month)
--    statement_month: 1 = most recent (September), 6 = oldest (April)
-- ============================================================================
CREATE TABLE fact_repayment_history (
    customer_id       INT NOT NULL REFERENCES dim_customers(customer_id),
    statement_month   SMALLINT NOT NULL CHECK (statement_month BETWEEN 1 AND 6),
    timeliness_code   VARCHAR(5),
    dpd               SMALLINT NOT NULL,   -- days-past-due proxy, in months; 0 = current
    PRIMARY KEY (customer_id, statement_month)
);

CREATE INDEX idx_repayment_dpd ON fact_repayment_history(dpd);

-- ============================================================================
-- 4. FACT LAYER — bill & payment amounts, unpivoted (1 row per customer/month)
-- ============================================================================
CREATE TABLE fact_statements (
    customer_id       INT NOT NULL REFERENCES dim_customers(customer_id),
    statement_month   SMALLINT NOT NULL CHECK (statement_month BETWEEN 1 AND 6),
    bill_amount       NUMERIC(14,2) NOT NULL,
    payment_amount    NUMERIC(14,2) NOT NULL,
    PRIMARY KEY (customer_id, statement_month)
);

-- ============================================================================
-- 5. FACT LAYER — final analytical table: one row per customer with all
--    engineered risk & collections features. This is the table most
--    business queries (risk_segmentation.sql, collections_analysis.sql,
--    kpi_dashboard_queries.sql) run against.
-- ============================================================================
CREATE TABLE fact_credit_risk (
    customer_id             INT PRIMARY KEY REFERENCES dim_customers(customer_id),
    current_dpd             SMALLINT NOT NULL,
    worst_dpd_6mo           SMALLINT NOT NULL,
    months_delinquent_6mo   SMALLINT NOT NULL,
    avg_dpd_6mo             NUMERIC(6,2) NOT NULL,
    collections_stage       VARCHAR(30)  NOT NULL,
    total_bill_6mo          NUMERIC(16,2) NOT NULL,
    total_paid_6mo          NUMERIC(16,2) NOT NULL,
    payment_to_bill_ratio   NUMERIC(6,3)  NOT NULL,
    credit_utilization      NUMERIC(6,3)  NOT NULL,
    risk_score              NUMERIC(8,2)  NOT NULL,
    risk_grade              VARCHAR(20)   NOT NULL,
    default_flag            SMALLINT      NOT NULL CHECK (default_flag IN (0,1))
);

CREATE INDEX idx_fact_risk_grade         ON fact_credit_risk(risk_grade);
CREATE INDEX idx_fact_collections_stage  ON fact_credit_risk(collections_stage);
CREATE INDEX idx_fact_default_flag       ON fact_credit_risk(default_flag);

/* ----------------------------------------------------------------------------
   NOTE ON PORTABILITY:
   - SERIAL  -> use AUTO_INCREMENT (MySQL) or IDENTITY(1,1) (SQL Server)
   - NUMERIC -> supported across all three engines
   - CHECK constraints are supported in PostgreSQL, SQL Server, MySQL 8.0.16+
---------------------------------------------------------------------------- */
