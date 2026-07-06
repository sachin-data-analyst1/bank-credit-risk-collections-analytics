/* ============================================================================
   FILE:        collections_analysis.sql
   PROJECT:     Bank Credit Risk & Collections Analytics
   PURPOSE:     Collections-team-facing queries — funnel size, delinquency
                distribution, and a month-over-month roll-rate matrix,
                mirroring the "Collections Analysis" tab in the Excel
                dashboard.
   DIALECT:     PostgreSQL 13+
   DEPENDS ON:  schema.sql, data_cleaning.sql (must be run first)
   ============================================================================ */

-- ============================================================================
-- 1. COLLECTIONS FUNNEL — accounts, exposure, and collection efficiency
--    by delinquency stage
-- ============================================================================
SELECT
    fr.collections_stage,
    COUNT(*)                                             AS accounts,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)       AS pct_of_portfolio,
    ROUND(AVG(fr.default_flag) * 100, 2)                 AS default_rate_pct,
    ROUND(SUM(fr.total_bill_6mo), 0)                     AS total_outstanding_bill,
    ROUND(SUM(fr.total_paid_6mo), 0)                     AS total_collected,
    ROUND(100.0 * SUM(fr.total_paid_6mo) / NULLIF(SUM(fr.total_bill_6mo), 0), 2)
                                                          AS collection_efficiency_pct,
    ROUND(AVG(fr.risk_score), 2)                         AS avg_risk_score
FROM fact_credit_risk fr
GROUP BY fr.collections_stage
ORDER BY fr.collections_stage;

-- ============================================================================
-- 2. CURRENT-MONTH DPD DISTRIBUTION (0 through 8+ months past due)
--    Finer-grained than the 4-stage funnel — useful for setting collections
--    treatment triggers at specific DPD thresholds.
-- ============================================================================
SELECT
    CASE WHEN current_dpd >= 8 THEN '8+ months' ELSE current_dpd::TEXT || ' months' END AS dpd_bucket,
    COUNT(*)                                        AS accounts,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_portfolio,
    ROUND(AVG(default_flag) * 100, 2)               AS default_rate_pct
FROM fact_credit_risk
GROUP BY CASE WHEN current_dpd >= 8 THEN '8+ months' ELSE current_dpd::TEXT || ' months' END,
         CASE WHEN current_dpd >= 8 THEN 999 ELSE current_dpd END
ORDER BY CASE WHEN current_dpd >= 8 THEN 999 ELSE current_dpd END;

-- ============================================================================
-- 3. ROLL-RATE MATRIX — prior month stage -> current month stage
--    Answers: "of accounts that were in stage X last month, what % are now
--    in each stage this month?" The classic collections-team KPI for
--    predicting near-term charge-off / recovery workload.
--
--    Prior month  = fact_repayment_history.statement_month = 2
--    Current month = fact_repayment_history.statement_month = 1
-- ============================================================================
WITH stage_map AS (
    SELECT
        customer_id,
        statement_month,
        CASE
            WHEN dpd <= 0 THEN '1-Current'
            WHEN dpd <= 2 THEN '2-Early DPD (1-2mo)'
            WHEN dpd <= 5 THEN '3-Mid DPD (3-5mo)'
            ELSE '4-Severe DPD (6mo+)'
        END AS stage
    FROM fact_repayment_history
    WHERE statement_month IN (1, 2)
),
transitions AS (
    SELECT
        p.stage AS prior_stage,
        c.stage AS current_stage
    FROM stage_map p
    JOIN stage_map c ON c.customer_id = p.customer_id
    WHERE p.statement_month = 2   -- prior month
      AND c.statement_month = 1   -- current month
),
prior_totals AS (
    SELECT prior_stage, COUNT(*) AS prior_total
    FROM transitions
    GROUP BY prior_stage
)
SELECT
    t.prior_stage,
    t.current_stage,
    COUNT(*)                                              AS accounts,
    ROUND(100.0 * COUNT(*) / pt.prior_total, 1)           AS pct_of_prior_stage
FROM transitions t
JOIN prior_totals pt ON pt.prior_stage = t.prior_stage
GROUP BY t.prior_stage, t.current_stage, pt.prior_total
ORDER BY t.prior_stage, t.current_stage;

-- ---- Pivoted version of the roll-rate matrix (one row per prior stage) ----
WITH stage_map AS (
    SELECT
        customer_id,
        statement_month,
        CASE
            WHEN dpd <= 0 THEN '1-Current'
            WHEN dpd <= 2 THEN '2-Early DPD (1-2mo)'
            WHEN dpd <= 5 THEN '3-Mid DPD (3-5mo)'
            ELSE '4-Severe DPD (6mo+)'
        END AS stage
    FROM fact_repayment_history
    WHERE statement_month IN (1, 2)
),
transitions AS (
    SELECT p.stage AS prior_stage, c.stage AS current_stage
    FROM stage_map p
    JOIN stage_map c ON c.customer_id = p.customer_id
    WHERE p.statement_month = 2 AND c.statement_month = 1
)
SELECT
    prior_stage,
    ROUND(100.0 * COUNT(*) FILTER (WHERE current_stage = '1-Current')            / COUNT(*), 1) AS to_current_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE current_stage = '2-Early DPD (1-2mo)')  / COUNT(*), 1) AS to_early_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE current_stage = '3-Mid DPD (3-5mo)')    / COUNT(*), 1) AS to_mid_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE current_stage = '4-Severe DPD (6mo+)')  / COUNT(*), 1) AS to_severe_pct,
    COUNT(*) AS total_accounts_in_prior_stage
FROM transitions
GROUP BY prior_stage
ORDER BY prior_stage;

-- ============================================================================
-- 4. OUTSTANDING EXPOSURE CONCENTRATION BY STAGE
--    Shows what % of total dollar exposure sits in each delinquency stage —
--    often the small severe-DPD tail holds outsized dollar risk.
-- ============================================================================
SELECT
    collections_stage,
    COUNT(*)                                                       AS accounts,
    ROUND(SUM(total_bill_6mo), 0)                                  AS outstanding_exposure,
    ROUND(100.0 * SUM(total_bill_6mo) / SUM(SUM(total_bill_6mo)) OVER (), 2) AS pct_of_total_exposure
FROM fact_credit_risk
GROUP BY collections_stage
ORDER BY collections_stage;

-- ============================================================================
-- 5. COLLECTION EFFICIENCY RANKED BY CUSTOMER SEGMENT
--    Which segments recover the smallest share of what they owe? These are
--    candidates for more aggressive (or different) collections treatment.
-- ============================================================================
SELECT
    dc.credit_limit_band,
    dc.age_band,
    COUNT(*)                                                                   AS accounts,
    ROUND(SUM(fr.total_bill_6mo), 0)                                           AS outstanding,
    ROUND(SUM(fr.total_paid_6mo), 0)                                           AS collected,
    ROUND(100.0 * SUM(fr.total_paid_6mo) / NULLIF(SUM(fr.total_bill_6mo), 0), 2) AS collection_efficiency_pct,
    RANK() OVER (ORDER BY SUM(fr.total_paid_6mo) / NULLIF(SUM(fr.total_bill_6mo), 0) ASC) AS worst_efficiency_rank
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY dc.credit_limit_band, dc.age_band
HAVING COUNT(*) >= 50
ORDER BY collection_efficiency_pct ASC
LIMIT 10;
