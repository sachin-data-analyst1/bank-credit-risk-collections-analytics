/* ============================================================================
   FILE:        risk_segmentation.sql
   PROJECT:     Bank Credit Risk & Collections Analytics
   PURPOSE:     Business-facing risk segmentation queries — the SQL
                equivalent of the "Risk Segmentation" tab in the Excel
                dashboard. Answers: which customer segments carry the most
                default risk, and by how much?
   DIALECT:     PostgreSQL 13+
   DEPENDS ON:  schema.sql, data_cleaning.sql (must be run first)
   ============================================================================ */

-- ============================================================================
-- 1. DEFAULT RATE BY RISK GRADE
--    Validates the risk-scoring model: grades should show a clear,
--    monotonic increase in default rate from A -> D.
-- ============================================================================
SELECT
    fr.risk_grade,
    COUNT(*)                                        AS accounts,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_portfolio,
    ROUND(AVG(fr.default_flag) * 100, 2)             AS default_rate_pct,
    ROUND(AVG(dc.credit_limit), 0)                   AS avg_credit_limit,
    ROUND(AVG(fr.credit_utilization) * 100, 1)       AS avg_utilization_pct,
    ROUND(AVG(fr.risk_score), 2)                     AS avg_risk_score
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY fr.risk_grade
ORDER BY fr.risk_grade;

-- ============================================================================
-- 2. DEFAULT RATE BY CREDIT LIMIT BAND
--    Tests whether lower-limit (often newer / thinner-file) customers
--    default more often than higher-limit customers.
-- ============================================================================
SELECT
    dc.credit_limit_band,
    COUNT(*)                                  AS accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)      AS default_rate_pct,
    ROUND(AVG(fr.risk_score), 2)              AS avg_risk_score
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY dc.credit_limit_band
ORDER BY
    CASE dc.credit_limit_band
        WHEN '<50K'      THEN 1
        WHEN '50K-100K'  THEN 2
        WHEN '100K-200K' THEN 3
        WHEN '200K-300K' THEN 4
        WHEN '300K-500K' THEN 5
        ELSE 6
    END;

-- ============================================================================
-- 3. DEFAULT RATE BY AGE BAND
-- ============================================================================
SELECT
    dc.age_band,
    COUNT(*)                              AS accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)  AS default_rate_pct
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY dc.age_band
ORDER BY
    CASE dc.age_band
        WHEN '<25'   THEN 1 WHEN '25-34' THEN 2 WHEN '35-44' THEN 3
        WHEN '45-54' THEN 4 WHEN '55-64' THEN 5 ELSE 6
    END;

-- ============================================================================
-- 4. DEFAULT RATE BY EDUCATION x MARITAL STATUS (cross-tab)
--    Mirrors the grouped-bar chart in the Python EDA notebook.
-- ============================================================================
SELECT
    dc.education,
    dc.marital_status,
    COUNT(*)                              AS accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)  AS default_rate_pct
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY dc.education, dc.marital_status
ORDER BY dc.education, dc.marital_status;

-- ============================================================================
-- 5. TOP 10 HIGHEST-RISK CUSTOMER SEGMENTS
--    Combines age band, education, and credit limit band into a single
--    segment, ranks by default rate (min 100 accounts to avoid tiny-sample
--    noise). Useful for prioritizing underwriting policy changes.
-- ============================================================================
SELECT
    dc.age_band,
    dc.education,
    dc.credit_limit_band,
    COUNT(*)                              AS accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)  AS default_rate_pct,
    RANK() OVER (ORDER BY AVG(fr.default_flag) DESC) AS risk_rank
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY dc.age_band, dc.education, dc.credit_limit_band
HAVING COUNT(*) >= 100
ORDER BY default_rate_pct DESC
LIMIT 10;

-- ============================================================================
-- 6. RISK-SCORE DECILE ANALYSIS
--    Splits the portfolio into 10 equal-sized groups by risk_score and
--    shows default rate per decile — a standard credit-risk model
--    validation technique (checks the score "rank-orders" risk cleanly).
-- ============================================================================
WITH deciles AS (
    SELECT
        customer_id,
        risk_score,
        default_flag,
        NTILE(10) OVER (ORDER BY risk_score) AS risk_decile
    FROM fact_credit_risk
)
SELECT
    risk_decile,
    COUNT(*)                             AS accounts,
    ROUND(MIN(risk_score), 2)            AS min_score,
    ROUND(MAX(risk_score), 2)            AS max_score,
    ROUND(AVG(default_flag) * 100, 2)    AS default_rate_pct
FROM deciles
GROUP BY risk_decile
ORDER BY risk_decile;

-- ============================================================================
-- 7. UTILIZATION & PAYMENT BEHAVIOR BY RISK GRADE
--    Shows the underlying behavioral drivers behind each risk grade —
--    useful context for a credit policy / collections strategy review.
-- ============================================================================
SELECT
    fr.risk_grade,
    ROUND(AVG(fr.credit_utilization) * 100, 1)      AS avg_utilization_pct,
    ROUND(AVG(fr.payment_to_bill_ratio) * 100, 1)   AS avg_payment_to_bill_pct,
    ROUND(AVG(fr.months_delinquent_6mo), 2)         AS avg_months_delinquent,
    ROUND(AVG(fr.worst_dpd_6mo), 2)                 AS avg_worst_dpd
FROM fact_credit_risk fr
GROUP BY fr.risk_grade
ORDER BY fr.risk_grade;

-- ============================================================================
-- 8. GENDER-BASED DEFAULT COMPARISON (basic demographic cut)
-- ============================================================================
SELECT
    dc.gender,
    COUNT(*)                              AS accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)  AS default_rate_pct
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY dc.gender;
