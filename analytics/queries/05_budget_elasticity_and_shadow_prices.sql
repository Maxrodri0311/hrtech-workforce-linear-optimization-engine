-- ==============================================================================
-- 05_budget_elasticity_and_shadow_prices.sql
-- HRTech & Workforce Intelligence Practice Remote Talent Marketplace - Analytical Sourcing Telemetry
--
-- Objective:
--   Computes marginal budget elasticity of candidate acquisition and estimates
--   shadow prices across all 80 sourcing corridors (Channel x Region x Seniority).
--   Evaluates diminishing marginal returns and identifies inflection points where
--   incremental capital injection yields sub-optimal candidate conversion.
--
-- Dialect: PostgreSQL 14+ / 16 (Window Functions, Window Framing, CTEs)
-- Performance: Optimized for execution on range-partitioned sourcing telemetry.
-- ==============================================================================

WITH RECURSIVE corridor_daily_metrics AS (
    -- 1. Base Aggregation of Cost and Qualified Pipeline Volume
    SELECT
        corridor_id,
        sourcing_channel,
        talent_region,
        role_seniority,
        DATE_TRUNC('month', event_timestamp)::DATE AS calendar_month,
        COUNT(telemetry_id) AS total_applications,
        SUM(cost_per_applicant_usd) AS monthly_expenditure_usd,
        AVG(cost_per_applicant_usd) AS mean_cpa_usd,
        SUM(CASE WHEN passed_interview THEN 1 ELSE 0 END) AS stage_interviews_passed,
        SUM(CASE WHEN hired_flag THEN 1 ELSE 0 END) AS stage_hires_achieved,
        AVG(interview_yield_rate * offer_acceptance_rate) AS empirical_conversion_yield
    FROM sourcing_channel_telemetry
    WHERE is_active_corridor = TRUE
    GROUP BY
        corridor_id,
        sourcing_channel,
        talent_region,
        role_seniority,
        DATE_TRUNC('month', event_timestamp)::DATE
),

marginal_efficiency_derivatives AS (
    -- 2. First and Second Finite Differences for Sourcing Elasticity
    SELECT
        corridor_id,
        sourcing_channel,
        talent_region,
        role_seniority,
        calendar_month,
        monthly_expenditure_usd,
        stage_hires_achieved,
        empirical_conversion_yield,
        LAG(monthly_expenditure_usd, 1) OVER w_corridor AS prev_monthly_expenditure,
        LAG(stage_hires_achieved, 1) OVER w_corridor AS prev_stage_hires,
        -- Marginal Cost Per Hire (Finite Difference Quotient)
        CASE
            WHEN (stage_hires_achieved - LAG(stage_hires_achieved, 1) OVER w_corridor) > 0
            THEN (monthly_expenditure_usd - LAG(monthly_expenditure_usd, 1) OVER w_corridor) /
                 NULLIF(stage_hires_achieved - LAG(stage_hires_achieved, 1) OVER w_corridor, 0)
            ELSE monthly_expenditure_usd / NULLIF(stage_hires_achieved, 0)
        END AS marginal_cph_usd,
        -- Point Elasticity of Sourcing: (% dHires) / (% dBudget)
        CASE
            WHEN LAG(monthly_expenditure_usd, 1) OVER w_corridor > 0
                 AND LAG(stage_hires_achieved, 1) OVER w_corridor > 0
                 AND (monthly_expenditure_usd - LAG(monthly_expenditure_usd, 1) OVER w_corridor) > 0
            THEN (
                (stage_hires_achieved - LAG(stage_hires_achieved, 1) OVER w_corridor) /
                NULLIF(LAG(stage_hires_achieved, 1) OVER w_corridor, 0)::NUMERIC
            ) / (
                (monthly_expenditure_usd - LAG(monthly_expenditure_usd, 1) OVER w_corridor) /
                NULLIF(LAG(monthly_expenditure_usd, 1) OVER w_corridor, 0)::NUMERIC
            )
            ELSE 1.0000
        END AS sourcing_budget_elasticity
    FROM corridor_daily_metrics
    WINDOW w_corridor AS (
        PARTITION BY corridor_id
        ORDER BY calendar_month ASC
        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
    )
),

corridor_shadow_price_estimation AS (
    -- 3. Estimation of Mathematical Dual Variables (Shadow Prices)
    -- Under HiGHS LP constraints, shadow price represents marginal increase in total hires
    -- per additional $1,000 of budget assigned to a saturated channel.
    SELECT
        corridor_id,
        sourcing_channel,
        talent_region,
        role_seniority,
        calendar_month,
        monthly_expenditure_usd,
        stage_hires_achieved,
        empirical_conversion_yield,
        marginal_cph_usd,
        sourcing_budget_elasticity,
        -- Sourcing Capital Efficiency Index (Normalized Yield / Normalized CPA)
        ROUND(
            (empirical_conversion_yield * 1000.0) /
            NULLIF(marginal_cph_usd, 0),
            4
        ) AS capital_efficiency_index,
        -- Shadow Price: Marginal Hires expected per $1,000 capital expansion
        ROUND(
            (1000.0 / NULLIF(marginal_cph_usd, 0))::NUMERIC,
            3
        ) AS shadow_price_hires_per_k_usd,
        -- Diminishing Returns Status
        CASE
            WHEN sourcing_budget_elasticity >= 1.20 THEN 'ELASTIC_HIGH_SCALE'
            WHEN sourcing_budget_elasticity BETWEEN 0.80 AND 1.19 THEN 'CONSTANT_RETURNS'
            WHEN sourcing_budget_elasticity BETWEEN 0.30 AND 0.79 THEN 'INELASTIC_SATURATING'
            ELSE 'DECREASING_CAPITAL_TRAP'
        END AS elasticity_regime
    FROM marginal_efficiency_derivatives
)

-- 4. Final Executive Corridor Elasticity and Reallocation Recommendation
SELECT
    sourcing_channel,
    talent_region,
    role_seniority,
    COUNT(DISTINCT calendar_month) AS observation_periods,
    ROUND(AVG(monthly_expenditure_usd), 2) AS avg_monthly_expenditure_usd,
    ROUND(AVG(stage_hires_achieved), 1) AS avg_monthly_hires,
    ROUND(AVG(marginal_cph_usd), 2) AS blended_marginal_cph_usd,
    ROUND(AVG(sourcing_budget_elasticity), 4) AS avg_budget_elasticity,
    ROUND(AVG(shadow_price_hires_per_k_usd), 3) AS avg_shadow_price_k_usd,
    MODE() WITHIN GROUP (ORDER BY elasticity_regime) AS dominant_elasticity_regime,
    -- Strategic Allocation Directive for C-Level Suite
    CASE
        WHEN MODE() WITHIN GROUP (ORDER BY elasticity_regime) = 'ELASTIC_HIGH_SCALE'
             AND AVG(marginal_cph_usd) < 250.00
        THEN 'PRIORITY_AGGRESSIVE_EXPANSION'
        WHEN MODE() WITHIN GROUP (ORDER BY elasticity_regime) = 'CONSTANT_RETURNS'
             AND AVG(marginal_cph_usd) < 400.00
        THEN 'SUSTAIN_OPTIMAL_LP_QUOTA'
        WHEN MODE() WITHIN GROUP (ORDER BY elasticity_regime) IN ('INELASTIC_SATURATING', 'DECREASING_CAPITAL_TRAP')
             OR AVG(marginal_cph_usd) >= 400.00
        THEN 'THROTTLE_ALLOCATION_TO_CAPACITY_BOUND'
        ELSE 'RE-BENCHMARK_INTERVIEW_PASS_RATE'
    END AS strategic_capital_action
FROM corridor_shadow_price_estimation
GROUP BY
    sourcing_channel,
    talent_region,
    role_seniority
ORDER BY
    avg_shadow_price_k_usd DESC,
    blended_marginal_cph_usd ASC;
