/* ============================================================================
   FILE:        kpi_dashboard_queries.sql
   PROJECT:     Bank Credit Risk & Collections Analytics
   PURPOSE:     Executive-summary KPI queries and reusable SQL VIEWs designed
                to feed the Excel dashboard / a BI tool (Power BI, Tableau,
                Excel Power Query) directly via a live database connection.
   DIALECT:     PostgreSQL 13+
   DEPENDS ON:  schema.sql, data_cleaning.sql (must be run first)
   ============================================================================ */

-- ============================================================================
-- 1. EXECUTIVE SUMMARY — single-row KPI snapshot (mirrors the KPI cards on
--    the Dashboard tab of the Excel workbook)
-- ============================================================================
SELECT
    COUNT(*)                                                          AS total_accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)                              AS overall_default_rate_pct,
    ROUND(SUM(dc.credit_limit), 0)                                    AS total_credit_exposure,
    ROUND(SUM(fr.total_bill_6mo), 0)                                  AS total_outstanding_bill,
    ROUND(SUM(fr.total_paid_6mo), 0)                                  AS total_collected_6mo,
    ROUND(100.0 * SUM(fr.total_paid_6mo) / NULLIF(SUM(fr.total_bill_6mo), 0), 2)
                                                                       AS collection_efficiency_pct,
    COUNT(*) FILTER (WHERE fr.current_dpd >= 6)                       AS severe_dpd_accounts,
    COUNT(*) FILTER (WHERE fr.risk_grade IN ('C - High Risk','D - Severe Risk')) AS high_risk_plus_accounts,
    ROUND(AVG(fr.default_flag) FILTER (WHERE fr.risk_grade IN ('C - High Risk','D - Severe Risk')) * 100, 2)
                                                                       AS high_risk_default_rate_pct,
    ROUND(AVG(fr.default_flag) FILTER (WHERE fr.risk_grade = 'A - Low Risk') * 100, 2)
                                                                       AS low_risk_default_rate_pct
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id;

-- ============================================================================
-- 2. VIEW: vw_dashboard_kpi_summary
--    Wraps query #1 as a view so a BI tool / Excel Power Query can connect
--    to a single stable object instead of a raw ad-hoc query.
-- ============================================================================
CREATE OR REPLACE VIEW vw_dashboard_kpi_summary AS
SELECT
    COUNT(*)                                                          AS total_accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)                              AS overall_default_rate_pct,
    ROUND(SUM(dc.credit_limit), 0)                                    AS total_credit_exposure,
    ROUND(SUM(fr.total_bill_6mo), 0)                                  AS total_outstanding_bill,
    ROUND(SUM(fr.total_paid_6mo), 0)                                  AS total_collected_6mo,
    ROUND(100.0 * SUM(fr.total_paid_6mo) / NULLIF(SUM(fr.total_bill_6mo), 0), 2)
                                                                       AS collection_efficiency_pct,
    COUNT(*) FILTER (WHERE fr.current_dpd >= 6)                       AS severe_dpd_accounts,
    COUNT(*) FILTER (WHERE fr.risk_grade IN ('C - High Risk','D - Severe Risk')) AS high_risk_plus_accounts
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id;

-- ============================================================================
-- 3. VIEW: vw_risk_grade_summary
--    Feeds the "Default Rate by Risk Grade" bar chart.
-- ============================================================================
CREATE OR REPLACE VIEW vw_risk_grade_summary AS
SELECT
    risk_grade,
    COUNT(*)                              AS accounts,
    ROUND(AVG(default_flag) * 100, 2)     AS default_rate_pct,
    ROUND(AVG(risk_score), 2)             AS avg_risk_score
FROM fact_credit_risk
GROUP BY risk_grade;

-- ============================================================================
-- 4. VIEW: vw_collections_stage_summary
--    Feeds the collections funnel bar chart and portfolio-mix pie chart.
-- ============================================================================
CREATE OR REPLACE VIEW vw_collections_stage_summary AS
SELECT
    collections_stage,
    COUNT(*)                                                          AS accounts,
    ROUND(AVG(default_flag) * 100, 2)                                 AS default_rate_pct,
    ROUND(SUM(total_bill_6mo), 0)                                     AS total_outstanding,
    ROUND(SUM(total_paid_6mo), 0)                                     AS total_collected,
    ROUND(100.0 * SUM(total_paid_6mo) / NULLIF(SUM(total_bill_6mo), 0), 2) AS collection_efficiency_pct
FROM fact_credit_risk
GROUP BY collections_stage;

-- ============================================================================
-- 5. VIEW: vw_credit_limit_band_trend
--    Feeds the "Default Rate by Credit Limit Band" line chart.
-- ============================================================================
CREATE OR REPLACE VIEW vw_credit_limit_band_trend AS
SELECT
    dc.credit_limit_band,
    COUNT(*)                              AS accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)  AS default_rate_pct
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY dc.credit_limit_band;

-- ============================================================================
-- 6. MONTHLY BILL / PAYMENT TREND (across the 6-month statement window)
--    Useful for a trend-line chart showing whether average balances are
--    growing or average payments are shrinking over time — an early
--    portfolio-level warning signal.
-- ============================================================================
SELECT
    statement_month,
    ROUND(AVG(bill_amount), 0)     AS avg_bill_amount,
    ROUND(AVG(payment_amount), 0)  AS avg_payment_amount,
    ROUND(AVG(payment_amount) / NULLIF(AVG(bill_amount), 0) * 100, 2) AS avg_payment_ratio_pct
FROM fact_statements
GROUP BY statement_month
ORDER BY statement_month DESC;  -- month 6 = oldest (April) -> month 1 = most recent (Sept)

-- ============================================================================
-- 7. FULL DASHBOARD REFRESH QUERY — single query returning every metric an
--    Excel Power Query / Power BI refresh would need in one round trip
--    (segment-level grain, used to build a single Power Query table that
--    Excel PivotTables/PivotCharts can slice locally).
-- ============================================================================
SELECT
    dc.credit_limit_band,
    dc.age_band,
    dc.education,
    dc.marital_status,
    dc.gender,
    fr.risk_grade,
    fr.collections_stage,
    COUNT(*)                              AS accounts,
    ROUND(AVG(fr.default_flag) * 100, 2)  AS default_rate_pct,
    ROUND(SUM(fr.total_bill_6mo), 0)      AS total_outstanding,
    ROUND(SUM(fr.total_paid_6mo), 0)      AS total_collected
FROM fact_credit_risk fr
JOIN dim_customers dc ON dc.customer_id = fr.customer_id
GROUP BY GROUPING SETS (
    (dc.credit_limit_band),
    (dc.age_band),
    (dc.education),
    (dc.marital_status),
    (dc.gender),
    (fr.risk_grade),
    (fr.collections_stage)
);

/* ----------------------------------------------------------------------------
   USAGE: In Excel, use Data -> Get Data -> From Database -> From PostgreSQL
   Database, point at vw_dashboard_kpi_summary / vw_risk_grade_summary /
   vw_collections_stage_summary / vw_credit_limit_band_trend to power a
   live-refreshing version of the dashboard tabs in
   excel/Credit_Risk_Collections_Dashboard.xlsx.
---------------------------------------------------------------------------- */
