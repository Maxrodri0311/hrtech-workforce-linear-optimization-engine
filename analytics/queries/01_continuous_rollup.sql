-- ==============================================================================
-- Jobgether Remote Talent Optimization - Continuous Moving Rollup & KPIs
-- Target: PostgreSQL 16 Enterprise / Amazon RDS Aurora Multi-AZ
-- Architecture: Materialized Views with 7-Day Window Moving Averages & Percentiles
-- ==============================================================================

SET search_path TO jobgether_analytics, public;

DROP MATERIALIZED VIEW IF EXISTS mv_sourcing_channel_efficiency_rollup CASCADE;

CREATE MATERIALIZED VIEW mv_sourcing_channel_efficiency_rollup AS
WITH windowed_telemetry AS (
    SELECT
        t.telemetry_id,
        t.campaign_id,
        c.client_name,
        t.channel_name,
        t.region,
        t.seniority,
        t.cost_per_applicant_usd,
        t.allocated_applicants,
        t.allocated_spend_usd,
        t.overall_conversion_yield,
        t.projected_hires,
        t.event_timestamp,
        DATE_TRUNC('day', t.event_timestamp) AS snapshot_date,
        -- Moving 7-day average CPA per channel corridor
        AVG(t.cost_per_applicant_usd) OVER (
            PARTITION BY t.channel_name, t.region, t.seniority
            ORDER BY t.event_timestamp
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW
        ) AS moving_7d_avg_cpa_usd,
        -- Moving 7-day average conversion yield per channel corridor
        AVG(t.overall_conversion_yield) OVER (
            PARTITION BY t.channel_name, t.region, t.seniority
            ORDER BY t.event_timestamp
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW
        ) AS moving_7d_avg_yield,
        -- Cumulative spend per campaign to date
        SUM(t.allocated_spend_usd) OVER (
            PARTITION BY t.campaign_id
            ORDER BY t.event_timestamp
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_campaign_spend_usd,
        -- Cumulative projected hires per campaign to date
        SUM(t.projected_hires) OVER (
            PARTITION BY t.campaign_id
            ORDER BY t.event_timestamp
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_projected_hires
    FROM sourcing_telemetry t
    INNER JOIN campaign_master c ON t.campaign_id = c.campaign_id
),
aggregated_corridor_daily AS (
    SELECT
        snapshot_date,
        channel_name,
        region,
        seniority,
        COUNT(DISTINCT campaign_id) AS active_campaigns_count,
        SUM(allocated_applicants) AS total_applicants_acquired,
        SUM(allocated_spend_usd) AS total_spend_usd,
        SUM(projected_hires) AS total_projected_hires,
        ROUND(AVG(cost_per_applicant_usd)::numeric, 2) AS mean_cpa_usd,
        ROUND(AVG(moving_7d_avg_cpa_usd)::numeric, 2) AS rolling_7d_cpa_usd,
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY cost_per_applicant_usd)::numeric, 2) AS p95_cpa_usd,
        ROUND(AVG(overall_conversion_yield)::numeric, 5) AS mean_conversion_yield,
        ROUND(AVG(moving_7d_avg_yield)::numeric, 5) AS rolling_7d_yield,
        -- Empirical Cost-per-Hire: Total Spend / Total Projected Hires
        ROUND((SUM(allocated_spend_usd)::numeric / NULLIF(SUM(projected_hires), 0))::numeric, 2) AS effective_cost_per_hire_usd,
        -- Return on Sourcing Spend (Hires generated per $1,000 invested)
        ROUND(((SUM(projected_hires)::numeric / NULLIF(SUM(allocated_spend_usd), 0)) * 1000.0)::numeric, 3) AS hires_yield_per_1k_usd
    FROM windowed_telemetry
    GROUP BY snapshot_date, channel_name, region, seniority
)
SELECT
    snapshot_date,
    channel_name,
    region,
    seniority,
    active_campaigns_count,
    total_applicants_acquired,
    total_spend_usd,
    total_projected_hires,
    mean_cpa_usd,
    rolling_7d_cpa_usd,
    p95_cpa_usd,
    mean_conversion_yield,
    rolling_7d_yield,
    effective_cost_per_hire_usd,
    hires_yield_per_1k_usd,
    -- Efficiency Quadrant Categorization
    CASE
        WHEN effective_cost_per_hire_usd <= 1200.00 AND mean_conversion_yield >= 0.08000 THEN 'HIGH_YIELD_LOW_COST (STAR)'
        WHEN effective_cost_per_hire_usd <= 1200.00 THEN 'MODERATE_YIELD_AFFORDABLE'
        WHEN mean_conversion_yield >= 0.08000 THEN 'HIGH_PRECISION_PREMIUM'
        ELSE 'LOW_YIELD_EXPENSIVE_BOTTLENECK'
    END AS corridor_strategic_tier
FROM aggregated_corridor_daily
ORDER BY snapshot_date DESC, total_spend_usd DESC;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_sourcing_rollup_pk 
    ON mv_sourcing_channel_efficiency_rollup (snapshot_date, channel_name, region, seniority);

CREATE INDEX IF NOT EXISTS idx_mv_sourcing_strategic_tier 
    ON mv_sourcing_channel_efficiency_rollup (corridor_strategic_tier, snapshot_date DESC);