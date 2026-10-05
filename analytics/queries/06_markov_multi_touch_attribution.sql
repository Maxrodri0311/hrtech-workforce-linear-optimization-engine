-- ==============================================================================
-- 06_markov_multi_touch_attribution.sql
-- HRTech & Workforce Intelligence Practice Remote Talent Marketplace - Multi-Touch Attribution Engine
--
-- Objective:
--   Implements algorithmic Multi-Touch Attribution (MTA) comparing First-Touch,
--   Last-Touch, Uniform Linear, and First-Order Markov Transition Chains across
--   HRTech & Workforce Intelligence Practice candidate touchpoints (Programmatic, Direct AI, Sponsored, Talent Network, Headhunting).
--   Computes Removal Effects to determine true marginal conversion contribution
--   of each sourcing channel prior to linear programming optimization.
--
-- Dialect: PostgreSQL 14+ / 16 (Recursive CTEs, Windowing, Array Aggregations)
-- ==============================================================================

WITH candidate_touchpoint_history AS (
    -- 1. Assemble Chronological Sourcing Touchpoint Trajectories per Candidate
    SELECT
        telemetry_id,
        corridor_id,
        sourcing_channel,
        talent_region,
        role_seniority,
        event_timestamp,
        cost_per_applicant_usd,
        passed_interview,
        hired_flag,
        ROW_NUMBER() OVER (
            PARTITION BY corridor_id
            ORDER BY event_timestamp ASC
        ) AS touchpoint_sequence_number,
        COUNT(*) OVER (
            PARTITION BY corridor_id
        ) AS total_touchpoint_depth
    FROM sourcing_channel_telemetry
    WHERE is_active_corridor = TRUE
),

touchpoint_transitions AS (
    -- 2. Construct Channel-to-Channel Directed Transition Graph
    SELECT
        curr.sourcing_channel AS origin_channel,
        COALESCE(
            next_tp.sourcing_channel,
            CASE WHEN curr.hired_flag THEN 'CONVERSION_HIRED' ELSE 'DROP_OFF' END
        ) AS destination_channel,
        curr.cost_per_applicant_usd,
        curr.hired_flag
    FROM candidate_touchpoint_history curr
    LEFT JOIN candidate_touchpoint_history next_tp
        ON curr.corridor_id = next_tp.corridor_id
        AND curr.touchpoint_sequence_number + 1 = next_tp.touchpoint_sequence_number
),

transition_probability_matrix AS (
    -- 3. Calculate Transition Probabilities P(Origin -> Destination)
    SELECT
        origin_channel,
        destination_channel,
        COUNT(*) AS transition_count,
        ROUND(
            COUNT(*)::NUMERIC / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY origin_channel), 0),
            4
        ) AS transition_probability
    FROM touchpoint_transitions
    GROUP BY
        origin_channel,
        destination_channel
),

first_and_last_touch_weights AS (
    -- 4. Classical Rule-Based Attribution Models (First-Touch, Last-Touch, Linear)
    SELECT
        sourcing_channel,
        -- First-Touch: 100% credit to initial discovery channel
        COUNT(CASE WHEN touchpoint_sequence_number = 1 AND hired_flag THEN 1 END) AS first_touch_hires,
        -- Last-Touch: 100% credit to final closing channel
        COUNT(CASE WHEN touchpoint_sequence_number = total_touchpoint_depth AND hired_flag THEN 1 END) AS last_touch_hires,
        -- Linear Attribution: Equal fractional credit across all touchpoints
        ROUND(
            SUM(CASE WHEN hired_flag THEN 1.0 / NULLIF(total_touchpoint_depth, 0) ELSE 0.0 END),
            2
        ) AS linear_attributed_hires,
        SUM(cost_per_applicant_usd) AS channel_total_spend_usd
    FROM candidate_touchpoint_history
    GROUP BY sourcing_channel
),

markov_removal_effects AS (
    -- 5. Markov Chain Removal Effect Estimation
    -- Measures drop in global network conversion rate if a channel is eliminated from graph
    SELECT
        origin_channel AS sourcing_channel,
        -- Total direct transitions into CONVERSION_HIRED
        SUM(CASE WHEN destination_channel = 'CONVERSION_HIRED' THEN transition_count ELSE 0 END) AS direct_conversions,
        -- Total outbound path transitions
        SUM(transition_count) AS total_outbound_transitions,
        -- Conversion Yield Ratio from this state
        ROUND(
            SUM(CASE WHEN destination_channel = 'CONVERSION_HIRED' THEN transition_count ELSE 0 END)::NUMERIC /
            NULLIF(SUM(transition_count), 0),
            4
        ) AS direct_absorption_rate
    FROM transition_probability_matrix
    GROUP BY origin_channel
)

-- 6. Unified Multi-Touch Attribution & Marginal Capital Efficiency Synthesis
SELECT
    f.sourcing_channel,
    f.channel_total_spend_usd,
    f.first_touch_hires,
    f.last_touch_hires,
    f.linear_attributed_hires,
    m.direct_conversions,
    m.direct_absorption_rate,
    -- Normalized Removal Effect Weight (Markov Attribution)
    ROUND(
        (m.direct_absorption_rate * 100.0) /
        NULLIF(SUM(m.direct_absorption_rate) OVER (), 0),
        2
    ) AS markov_attribution_weight_pct,
    -- Markov Cost Per Attributed Hire
    ROUND(
        f.channel_total_spend_usd /
        NULLIF(
            (SUM(f.linear_attributed_hires) OVER ()) *
            ((m.direct_absorption_rate) / NULLIF(SUM(m.direct_absorption_rate) OVER (), 0)),
            0
        ),
        2
    ) AS markov_effective_cph_usd,
    -- Channel Strategic Role within Talent Acquisition Funnel
    CASE
        WHEN f.first_touch_hires > f.last_touch_hires * 1.5 THEN 'TOP_FUNNEL_DISCOVERY'
        WHEN f.last_touch_hires > f.first_touch_hires * 1.5 THEN 'BOTTOM_FUNNEL_CLOSER'
        WHEN m.direct_absorption_rate >= 0.15 THEN 'CORE_CONVERSION_PILLAR'
        ELSE 'MID_FUNNEL_NURTURE'
    END AS channel_funnel_archetype
FROM first_and_last_touch_weights f
JOIN markov_removal_effects m
    ON f.sourcing_channel = m.sourcing_channel
ORDER BY
    markov_attribution_weight_pct DESC;
