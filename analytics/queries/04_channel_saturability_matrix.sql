-- ==============================================================================
-- HRTech & Workforce Intelligence Practice Remote Talent Optimization - Channel Saturability & Shadow Price SQL
-- Target: PostgreSQL 16 Enterprise / Amazon RDS Aurora Multi-AZ
-- Architecture: Capacity Saturation Ratios, Linear Bottleneck Analysis,
--               and Shadow Price Dual Variable Estimation for C-Level Planning
-- ==============================================================================

SET search_path TO jobgether_analytics, public;

WITH monthly_allocation_aggregates AS (
    SELECT
        DATE_TRUNC('month', t.event_timestamp) AS allocation_month,
        t.channel_name,
        t.region,
        t.seniority,
        r.saturation_capacity,
        SUM(t.allocated_applicants) AS total_allocated_applicants,
        ROUND(SUM(t.allocated_spend_usd)::numeric, 2) AS total_spend_usd,
        ROUND(SUM(t.projected_hires)::numeric, 1) AS total_projected_hires,
        ROUND(AVG(t.cost_per_applicant_usd)::numeric, 2) AS effective_cpa_usd,
        ROUND(AVG(t.overall_conversion_yield)::numeric, 5) AS effective_conversion_yield
    FROM sourcing_telemetry t
    INNER JOIN channel_corridor_registry r
        ON t.channel_name = r.channel_name
       AND t.region = r.region
       AND t.seniority = r.seniority
    GROUP BY 
        DATE_TRUNC('month', t.event_timestamp),
        t.channel_name,
        t.region,
        t.seniority,
        r.saturation_capacity
),
capacity_saturation_analysis AS (
    SELECT
        allocation_month,
        channel_name,
        region,
        seniority,
        saturation_capacity,
        total_allocated_applicants,
        total_spend_usd,
        total_projected_hires,
        effective_cpa_usd,
        effective_conversion_yield,
        -- Utilization Percentage: Allocated / Capacity
        ROUND((total_allocated_applicants::numeric / NULLIF(saturation_capacity, 0) * 100.0)::numeric, 2) AS capacity_utilization_pct,
        -- Unused headroom
        (saturation_capacity - total_allocated_applicants) AS remaining_applicant_headroom,
        -- Estimated Shadow Price: Marginal Hires generated per +100 applicant capacity expansion
        ROUND((100.0 * effective_conversion_yield)::numeric, 2) AS marginal_hires_per_100_extra_capacity,
        -- Marginal Revenue / Cost efficiency
        ROUND((effective_cpa_usd / NULLIF(effective_conversion_yield, 0))::numeric, 2) AS corridor_cph_benchmark
    FROM monthly_allocation_aggregates
)
SELECT
    TO_CHAR(allocation_month, 'YYYY-MM') AS report_month,
    channel_name,
    region,
    seniority,
    saturation_capacity,
    total_allocated_applicants,
    capacity_utilization_pct,
    remaining_applicant_headroom,
    marginal_hires_per_100_extra_capacity,
    corridor_cph_benchmark,
    -- Capacity Bottleneck Status
    CASE
        WHEN capacity_utilization_pct >= 95.00 THEN 'SEVERELY_SATURATED_HARD_BOTTLENECK'
        WHEN capacity_utilization_pct >= 80.00 THEN 'CONGESTED_NEAR_CAPACITY'
        WHEN capacity_utilization_pct <= 30.00 THEN 'UNDER_UTILIZED_SLACK_CAPACITY'
        ELSE 'OPTIMALLY_LOADED'
    END AS channel_saturation_status,
    -- Strategic Expansion Priority Ranking
    CASE
        WHEN capacity_utilization_pct >= 80.00 AND corridor_cph_benchmark <= 1500.00 THEN 'TIER_1_EXPANSION_TARGET (HIGH ROI)'
        WHEN capacity_utilization_pct >= 80.00 THEN 'TIER_2_EXPANSION_SELECTIVE'
        ELSE 'MAINTAIN_CURRENT_LIMITS'
    END AS capacity_expansion_recommendation
FROM capacity_saturation_analysis
ORDER BY 
    allocation_month DESC,
    capacity_utilization_pct DESC,
    corridor_cph_benchmark ASC;
