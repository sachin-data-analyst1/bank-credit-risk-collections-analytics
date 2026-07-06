/* ============================================================================
   FILE:        data_cleaning.sql
   PROJECT:     Bank Credit Risk & Collections Analytics
   PURPOSE:     Data quality checks + ETL transformation from the raw staging
                table into the cleaned star-schema (dim_customers,
                fact_repayment_history, fact_statements, fact_credit_risk).
   DIALECT:     PostgreSQL 13+
   RUN ORDER:   Run schema.sql first, then this file, top to bottom.
   ============================================================================ */

-- ============================================================================
-- STEP 0: DATA QUALITY CHECKS  (run before trusting any downstream numbers)
-- ============================================================================

-- 0.1 Row count sanity check
SELECT COUNT(*) AS total_rows FROM staging_raw_credit_data;

-- 0.2 Null checks across all key columns
SELECT
    COUNT(*) FILTER (WHERE credit_limit    IS NULL) AS null_credit_limit,
    COUNT(*) FILTER (WHERE gender          IS NULL) AS null_gender,
    COUNT(*) FILTER (WHERE education       IS NULL) AS null_education,
    COUNT(*) FILTER (WHERE marital_status  IS NULL) AS null_marital_status,
    COUNT(*) FILTER (WHERE age             IS NULL) AS null_age,
    COUNT(*) FILTER (WHERE default_raw     IS NULL) AS null_default
FROM staging_raw_credit_data;

-- 0.3 Duplicate customer check (should be zero — customer_id is a surrogate key)
SELECT customer_id, COUNT(*)
FROM staging_raw_credit_data
GROUP BY customer_id
HAVING COUNT(*) > 1;

-- 0.4 Domain / range checks — flag any records with implausible values
SELECT customer_id, age, credit_limit
FROM staging_raw_credit_data
WHERE age NOT BETWEEN 18 AND 100
   OR credit_limit <= 0;

-- 0.5 Category audit — see every distinct raw value before standardizing
SELECT DISTINCT gender FROM staging_raw_credit_data;
SELECT DISTINCT education FROM staging_raw_credit_data;
SELECT DISTINCT marital_status FROM staging_raw_credit_data;
SELECT DISTINCT timeliness_1 FROM staging_raw_credit_data ORDER BY 1;

-- ============================================================================
-- STEP 1: POPULATE dim_customers — standardize categorical text, derive bands
-- ============================================================================
INSERT INTO dim_customers (customer_id, credit_limit, credit_limit_band,
                            gender, education, marital_status, age, age_band)
SELECT
    customer_id,
    credit_limit,
    CASE
        WHEN credit_limit < 50000  THEN '<50K'
        WHEN credit_limit < 100000 THEN '50K-100K'
        WHEN credit_limit < 200000 THEN '100K-200K'
        WHEN credit_limit < 300000 THEN '200K-300K'
        WHEN credit_limit < 500000 THEN '300K-500K'
        ELSE '500K+'
    END AS credit_limit_band,
    INITCAP(TRIM(gender)) AS gender,
    CASE TRIM(LOWER(education))
        WHEN 'grad'   THEN 'Graduate School'
        WHEN 'uni'    THEN 'University'
        WHEN 'hs'     THEN 'High School'
        WHEN 'other1' THEN 'Other'
        WHEN 'other2' THEN 'Other'
        WHEN 'other3' THEN 'Other'
        ELSE 'Unknown'
    END AS education,
    CASE TRIM(LOWER(marital_status))
        WHEN 'married' THEN 'Married'
        WHEN 'single'  THEN 'Single'
        WHEN 'other'   THEN 'Other'
        ELSE 'Unknown'
    END AS marital_status,
    age,
    CASE
        WHEN age < 25 THEN '<25'
        WHEN age < 35 THEN '25-34'
        WHEN age < 45 THEN '35-44'
        WHEN age < 55 THEN '45-54'
        WHEN age < 65 THEN '55-64'
        ELSE '65+'
    END AS age_band
FROM staging_raw_credit_data;

-- ============================================================================
-- STEP 2: POPULATE fact_repayment_history — unpivot the 6 monthly
--          timeliness columns and convert repayment codes to a numeric
--          days-past-due (DPD) proxy.
--          Code convention: 'm-2'/'m-1' = paid duly/early -> DPD 0
--                            'm+0'      = paid on time     -> DPD 0
--                            'm+1'..'m+8' = N months delinquent -> DPD N
-- ============================================================================
INSERT INTO fact_repayment_history (customer_id, statement_month, timeliness_code, dpd)
SELECT customer_id, 1 AS statement_month, timeliness_1,
       GREATEST(CAST(REPLACE(timeliness_1, 'm', '') AS INT), 0)
FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 2, timeliness_2,
       GREATEST(CAST(REPLACE(timeliness_2, 'm', '') AS INT), 0)
FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 3, timeliness_3,
       GREATEST(CAST(REPLACE(timeliness_3, 'm', '') AS INT), 0)
FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 4, timeliness_4,
       GREATEST(CAST(REPLACE(timeliness_4, 'm', '') AS INT), 0)
FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 5, timeliness_5,
       GREATEST(CAST(REPLACE(timeliness_5, 'm', '') AS INT), 0)
FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 6, timeliness_6,
       GREATEST(CAST(REPLACE(timeliness_6, 'm', '') AS INT), 0)
FROM staging_raw_credit_data;

-- ============================================================================
-- STEP 3: POPULATE fact_statements — unpivot bill & payment columns
-- ============================================================================
INSERT INTO fact_statements (customer_id, statement_month, bill_amount, payment_amount)
SELECT customer_id, 1, balance_1, payment_1 FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 2, balance_2, payment_2 FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 3, balance_3, payment_3 FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 4, balance_4, payment_4 FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 5, balance_5, payment_5 FROM staging_raw_credit_data
UNION ALL
SELECT customer_id, 6, balance_6, payment_6 FROM staging_raw_credit_data;

-- ============================================================================
-- STEP 4: POPULATE fact_credit_risk — engineer the risk score, risk grade,
--          and collections stage exactly as defined in the Python pipeline
--          (engineer.py), so SQL and Python outputs reconcile 1:1.
-- ============================================================================
WITH repayment_agg AS (
    SELECT
        customer_id,
        MAX(dpd) FILTER (WHERE statement_month = 1) AS current_dpd,
        MAX(dpd) AS worst_dpd_6mo,
        COUNT(*) FILTER (WHERE dpd > 0) AS months_delinquent_6mo,
        ROUND(AVG(dpd), 2) AS avg_dpd_6mo
    FROM fact_repayment_history
    GROUP BY customer_id
),
statement_agg AS (
    SELECT
        customer_id,
        SUM(bill_amount)    AS total_bill_6mo,
        SUM(payment_amount) AS total_paid_6mo
    FROM fact_statements
    GROUP BY customer_id
),
base AS (
    SELECT
        c.customer_id,
        r.current_dpd,
        r.worst_dpd_6mo,
        r.months_delinquent_6mo,
        r.avg_dpd_6mo,
        s.total_bill_6mo,
        s.total_paid_6mo,
        CASE WHEN s.total_bill_6mo > 0
             THEN ROUND(s.total_paid_6mo / s.total_bill_6mo, 3)
             ELSE 1.0 END AS payment_to_bill_ratio,
        ROUND(dc.credit_limit_avg_balance_ratio, 3) AS credit_utilization,
        sr.default_raw
    FROM dim_customers c
    JOIN repayment_agg r  ON r.customer_id = c.customer_id
    JOIN statement_agg s  ON s.customer_id = c.customer_id
    JOIN staging_raw_credit_data sr ON sr.customer_id = c.customer_id
    CROSS JOIN LATERAL (
        SELECT sr.avg_balance / NULLIF(c.credit_limit, 0) AS credit_limit_avg_balance_ratio
    ) dc
),
scored AS (
    SELECT
        *,
        ROUND(
            (worst_dpd_6mo * 10)
          + (months_delinquent_6mo * 5)
          + (GREATEST(credit_utilization - 0.8, 0) * 20)
          + (GREATEST(0.3 - payment_to_bill_ratio, 0) * 30)
        , 2) AS risk_score
    FROM base
)
INSERT INTO fact_credit_risk (
    customer_id, current_dpd, worst_dpd_6mo, months_delinquent_6mo, avg_dpd_6mo,
    collections_stage, total_bill_6mo, total_paid_6mo, payment_to_bill_ratio,
    credit_utilization, risk_score, risk_grade, default_flag
)
SELECT
    customer_id,
    current_dpd,
    worst_dpd_6mo,
    months_delinquent_6mo,
    avg_dpd_6mo,
    CASE
        WHEN current_dpd <= 0 THEN '1-Current'
        WHEN current_dpd <= 2 THEN '2-Early DPD (1-2mo)'
        WHEN current_dpd <= 5 THEN '3-Mid DPD (3-5mo)'
        ELSE '4-Severe DPD (6mo+)'
    END AS collections_stage,
    total_bill_6mo,
    total_paid_6mo,
    payment_to_bill_ratio,
    credit_utilization,
    risk_score,
    CASE
        WHEN risk_score < 5  THEN 'A - Low Risk'
        WHEN risk_score < 15 THEN 'B - Moderate Risk'
        WHEN risk_score < 30 THEN 'C - High Risk'
        ELSE 'D - Severe Risk'
    END AS risk_grade,
    CASE WHEN LOWER(default_raw) = 'yes' THEN 1 ELSE 0 END AS default_flag
FROM scored;

-- ============================================================================
-- STEP 5: POST-LOAD VALIDATION — confirm row counts reconcile across layers
-- ============================================================================
SELECT
    (SELECT COUNT(*) FROM staging_raw_credit_data) AS staging_rows,
    (SELECT COUNT(*) FROM dim_customers)           AS dim_customer_rows,
    (SELECT COUNT(*) FROM fact_credit_risk)        AS fact_risk_rows,
    (SELECT COUNT(*) FROM fact_repayment_history)  AS repayment_rows_expect_6x,
    (SELECT COUNT(*) FROM fact_statements)         AS statement_rows_expect_6x;
