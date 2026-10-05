-- ==============================================================================
-- HRTech & Workforce Intelligence Practice Remote Talent Optimization - Multi-Objective Pareto Frontier SQL
-- Target: PostgreSQL 16 Enterprise / Amazon RDS Aurora Multi-AZ
-- Architecture: Non-Dominated Pareto Set Identification, Frontier Ranking
--               & Marginal Rate of Technical Substitution (MRTS) Analysis
-- ==============================================================================

SET search_path TO jobgether_analytics, public;

WITH corridor_aggregated_metrics AS (
    -- Consolidate empirical performance points across active talent corridors
    SELECT
        channel_name,
        region,
        seniority,
        ROUND(AVG(cost_per_applicant_usd)::numeric, 2) AS mean_cpa_usd,
        ROUND(AVG(overall_conversion_yield)::numeric, 5) AS mean_conversion_yield,
        SUM(allocated_applicants) AS historical_applicants_volume,
        ROUND(SUM(allocated_spend_usd)::numeric, 2) AS total_historical_spend_usd,
        ROUND((SUM(allocated_spend_usd)::numeric / NULLIF(SUM(projected_hires), 0))::numeric, 2) AS empirical_cph_usd
    FROM sourcing_telemetry
    GROUP BY channel_name, region, seniority
    HAVING SUM(allocated_applicants) >= 100
),
pareto_dominance_evaluation AS (
    -- A corridor A is dominated by B if CPA_B <= CPA_A AND Yield_B >= Yield_A (with at least one strict)
    SELECT
        c1.channel_name,
        c1.region,
        c1.seniority,
        c1.mean_cpa_usd,
        c1.mean_conversion_yield,
        c1.empirical_cph_usd,
        c1.historical_applicants_volume,
        c1.total_historical_spend_usd,
        -- Count how many corridors strictly dominate this corridor
        COUNT(c2.channel_name) AS dominated_by_count
    FROM corridor_aggregated_metrics c1
    LEFT JOIN corridor_aggregated_metrics c2 
        ON c2.mean_cpa_usd <= c1.mean_cpa_usd 
       AND c2.mean_conversion_yield >= c1.mean_conversion_yield
       AND (c2.mean_cpa_usd < c1.mean_cpa_usd OR c2.mean_conversion_yield > c1.mean_conversion_yield)
    GROUP BY 
        c1.channel_name,
        c1.region,
        c1.seniority,
        c1.mean_cpa_usd,
        c1.mean_conversion_yield,
        c1.empirical_cph_usd,
        c1.historical_applicants_volume,
        c1.total_historical_spend_usd
),
frontier_ranking AS (
    SELECT
        channel_name,
        region,
        seniority,
        mean_cpa_usd,
        mean_conversion_yield,
        empirical_cph_usd,
        historical_applicants_volume,
        total_historical_spend_usd,
        dominated_by_count,
        -- Rank 1 = Exact Pareto Optimal Frontier (0 dominant peers)
        DENSE_RANK() OVER (ORDER BY dominated_by_count ASC) AS pareto_frontier_rank,
        -- Ordered ranking along the frontier by increasing cost
        LAG(mean_cpa_usd, 1) OVER (
            PARTITION BY dominated_by_count 
            ORDER BY mean_cpa_usd ASC
        ) AS prev_frontier_cpa,
        LAG(mean_conversion_yield, 1) OVER (
            PARTITION BY dominated_by_count 
            ORDER BY mean_cpa_usd ASC
        ) AS prev_frontier_yield
    FROM pareto_dominance_evaluation
)
SELECT
    channel_name,
    region,
    seniority,
    mean_cpa_usd,
    ROUND((mean_conversion_yield * 100.0)::numeric, 3) AS conversion_yield_pct,
    empirical_cph_usd,
    dominated_by_count,
    pareto_frontier_rank,
    CASE 
        WHEN dominated_by_count = 0 THEN 'PARETO_OPTIMAL_FRONTIER'
        WHEN dominated_by_count <= 2 THEN 'NEAR_OPTIMAL_SECOND_TIER'
        ELSE 'SUB_OPTIMAL_DOMINATED'
    END AS pareto_efficiency_status,
    -- Marginal Rate of Technical Substitution: Delta Yield / Delta CPA
    CASE 
        WHEN prev_frontier_cpa IS NOT NULL AND (mean_cpa_usd - prev_frontier_cpa) > 0 THEN
            ROUND((((mean_conversion_yield - prev_frontier_yield) * 100.0) / (mean_cpa_usd - prev_frontier_cpa))::numeric, 4)
        ELSE NULL
    END AS marginal_yield_per_additional_dollar
FROM frontier_ranking
ORDER BY 
    dominated_by_count ASC,
    mean_cpa_usd ASC;
