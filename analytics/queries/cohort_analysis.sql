-- ==============================================================================
-- HRTech & Workforce Intelligence Practice Remote Talent Optimization - Longitudinal Cohort Sourcing Analytics
-- Target: PostgreSQL 16 Enterprise / Amazon RDS Aurora Multi-AZ
-- Architecture: Advanced Window Functions (NTILE, LAG, LEAD, FIRST_VALUE),
--               CPA Inflation Tracking & Multi-Period Client Onboarding Cohorts
-- ==============================================================================

SET search_path TO jobgether_analytics, public;

WITH client_onboarding_cohorts AS (
    -- Identify the inception cohort month for each enterprise client campaign
    SELECT
        campaign_id,
        client_name,
        total_budget_usd,
        target_hires,
        min_senior_hires,
        DATE_TRUNC('month', created_at) AS cohort_month
    FROM campaign_master
),
sequenced_allocation_telemetry AS (
    -- Enrich telemetry with longitudinal window metrics per campaign lifecycle
    SELECT
        t.telemetry_id,
        t.campaign_id,
        c.client_name,
        c.cohort_month,
        t.channel_name,
        t.region,
        t.seniority,
        t.cost_per_applicant_usd,
        t.allocated_applicants,
        t.allocated_spend_usd,
        t.overall_conversion_yield,
        t.projected_hires,
        t.event_timestamp,
        -- Sequence number of allocation batch within the client campaign
        ROW_NUMBER() OVER (
            PARTITION BY t.campaign_id 
            ORDER BY t.event_timestamp ASC
        ) AS allocation_batch_sequence,
        -- Previous allocation batch CPA (Velocity of cost inflation)
        LAG(t.cost_per_applicant_usd, 1) OVER (
            PARTITION BY t.campaign_id 
            ORDER BY t.event_timestamp ASC
        ) AS prev_batch_cpa_usd,
        -- Subsequent allocation batch conversion yield (Yield momentum indicator)
        LEAD(t.overall_conversion_yield, 1) OVER (
            PARTITION BY t.campaign_id 
            ORDER BY t.event_timestamp ASC
        ) AS next_batch_conversion_yield,
        -- Baseline CPA recorded at campaign inception
        FIRST_VALUE(t.cost_per_applicant_usd) OVER (
            PARTITION BY t.campaign_id 
            ORDER BY t.event_timestamp ASC 
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS baseline_campaign_cpa_usd,
        -- Peer corridor average CPA benchmark across all clients
        AVG(t.cost_per_applicant_usd) OVER (
            PARTITION BY t.channel_name, t.region, t.seniority
        ) AS corridor_benchmark_avg_cpa_usd,
        -- Cost quartile segmentation within seniority tier
        NTILE(4) OVER (
            PARTITION BY t.seniority 
            ORDER BY t.cost_per_applicant_usd ASC
        ) AS cpa_efficiency_quartile
    FROM sourcing_telemetry t
    INNER JOIN client_onboarding_cohorts c ON t.campaign_id = c.campaign_id
),
longitudinal_cohort_scoring AS (
    -- Compute drift deltas and velocity percentages
    SELECT
        telemetry_id,
        campaign_id,
        client_name,
        cohort_month,
        channel_name,
        region,
        seniority,
        cost_per_applicant_usd,
        allocated_applicants,
        allocated_spend_usd,
        projected_hires,
        overall_conversion_yield,
        allocation_batch_sequence,
        cpa_efficiency_quartile,
        baseline_campaign_cpa_usd,
        corridor_benchmark_avg_cpa_usd,
        -- Absolute dollar drift from initial baseline onboarding CPA
        ROUND((cost_per_applicant_usd - baseline_campaign_cpa_usd)::numeric, 2) AS cpa_drift_from_baseline_usd,
        -- CPA inflation velocity percentage
        CASE 
            WHEN prev_batch_cpa_usd IS NULL OR prev_batch_cpa_usd = 0 THEN 0.0
            ELSE ROUND(((cost_per_applicant_usd - prev_batch_cpa_usd) / prev_batch_cpa_usd * 100.0)::numeric, 2)
        END AS cpa_velocity_pct_change,
        -- Operational Tier classification
        CASE
            WHEN cpa_efficiency_quartile = 1 AND overall_conversion_yield >= 0.08 THEN 'OPTIMAL_HIGH_PERFORMER'
            WHEN cpa_efficiency_quartile = 4 AND overall_conversion_yield <= 0.03 THEN 'CHRONIC_COST_INEFFICIENCY'
            WHEN cpa_efficiency_quartile IN (2, 3) THEN 'NOMINAL_OPERATIONAL_BAND'
            ELSE 'STABLE_AVERAGE'
        END AS longitudinal_performance_tier
    FROM sequenced_allocation_telemetry
)
-- Aggregate Cohort Performance Matrix for C-Level Leadership
SELECT
    TO_CHAR(cohort_month, 'YYYY-MM') AS onboarding_cohort,
    channel_name,
    region,
    seniority,
    longitudinal_performance_tier,
    COUNT(DISTINCT campaign_id) AS total_active_campaigns,
    SUM(allocated_applicants) AS total_applicants_routed,
    ROUND(SUM(allocated_spend_usd)::numeric, 2) AS total_spend_usd,
    ROUND(SUM(projected_hires)::numeric, 1) AS total_projected_hires,
    ROUND(AVG(cost_per_applicant_usd)::numeric, 2) AS avg_cpa_usd,
    ROUND(AVG(cpa_drift_from_baseline_usd)::numeric, 2) AS avg_drift_from_inception_usd,
    ROUND(AVG(cpa_velocity_pct_change)::numeric, 2) AS avg_cpa_velocity_pct,
    ROUND(AVG(overall_conversion_yield * 100.0)::numeric, 3) AS avg_conversion_yield_pct,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cost_per_applicant_usd)::numeric, 2) AS median_cpa_usd,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY cost_per_applicant_usd)::numeric, 2) AS p95_cpa_usd,
    -- Effective Cost per Hire for this cohort stratum
    ROUND((SUM(allocated_spend_usd)::numeric / NULLIF(SUM(projected_hires), 0))::numeric, 2) AS effective_cost_per_hire_usd
FROM longitudinal_cohort_scoring
GROUP BY 
    cohort_month,
    channel_name,
    region,
    seniority,
    longitudinal_performance_tier
HAVING COUNT(*) >= 2
ORDER BY 
    cohort_month DESC,
    total_spend_usd DESC;