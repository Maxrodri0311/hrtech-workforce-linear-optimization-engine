-- ==============================================================================
-- HRTech & Workforce Intelligence Practice Remote Talent Optimization - Enterprise Analytics DDL & Partitioning
-- Target: PostgreSQL 16 Enterprise / Amazon RDS Aurora Multi-AZ
-- Architecture: Time-Series Range Partitioning, BRIN Indexing & Audit Log Tables
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS jobgether_analytics;
SET search_path TO jobgether_analytics, public;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Master Recruitment Campaigns Registry
CREATE TABLE IF NOT EXISTS campaign_master (
    campaign_id VARCHAR(64) PRIMARY KEY,
    client_name VARCHAR(128) NOT NULL,
    total_budget_usd NUMERIC(12, 2) NOT NULL CHECK (total_budget_usd > 0),
    target_hires INT NOT NULL CHECK (target_hires > 0),
    min_senior_hires INT NOT NULL DEFAULT 0 CHECK (min_senior_hires >= 0),
    max_cph_target_usd NUMERIC(10, 2) NOT NULL DEFAULT 5000.00,
    regional_diversity_min_pct NUMERIC(5, 4) NOT NULL DEFAULT 0.1500,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2. Channel & Corridor Efficiency Registry
CREATE TABLE IF NOT EXISTS channel_corridor_registry (
    corridor_id VARCHAR(64) PRIMARY KEY,
    channel_name VARCHAR(64) NOT NULL CHECK (channel_name IN (
        'Programmatic Job Boards', 'Direct AI Sourcing', 'Sponsored Campaigns',
        'Talent Network Pool', 'Executive Headhunting'
    )),
    region VARCHAR(32) NOT NULL CHECK (region IN ('LATAM', 'EMEA', 'North America', 'APAC')),
    seniority VARCHAR(32) NOT NULL CHECK (seniority IN (
        'Junior Specialist', 'Mid-Level Engineer', 'Senior Lead', 'Staff Architect'
    )),
    baseline_cpa_usd NUMERIC(8, 2) NOT NULL CHECK (baseline_cpa_usd > 0),
    saturation_capacity INT NOT NULL CHECK (saturation_capacity > 0),
    expected_interview_yield NUMERIC(6, 4) NOT NULL CHECK (expected_interview_yield > 0),
    expected_offer_acceptance NUMERIC(6, 4) NOT NULL CHECK (expected_offer_acceptance > 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_channel_corridor UNIQUE (channel_name, region, seniority)
);

-- 3. Telemetry Event Table: Range-Partitioned by Event Timestamp
CREATE TABLE IF NOT EXISTS sourcing_telemetry (
    telemetry_id UUID DEFAULT uuid_generate_v4(),
    campaign_id VARCHAR(64) NOT NULL REFERENCES campaign_master(campaign_id),
    channel_name VARCHAR(64) NOT NULL,
    region VARCHAR(32) NOT NULL,
    seniority VARCHAR(32) NOT NULL,
    cost_per_applicant_usd NUMERIC(8, 2) NOT NULL CHECK (cost_per_applicant_usd > 0),
    allocated_applicants INT NOT NULL CHECK (allocated_applicants >= 0),
    allocated_spend_usd NUMERIC(12, 2) NOT NULL CHECK (allocated_spend_usd >= 0),
    interview_yield_rate NUMERIC(6, 4) NOT NULL CHECK (interview_yield_rate >= 0),
    offer_acceptance_rate NUMERIC(6, 4) NOT NULL CHECK (offer_acceptance_rate >= 0),
    overall_conversion_yield NUMERIC(8, 5) NOT NULL CHECK (overall_conversion_yield >= 0),
    projected_hires NUMERIC(8, 2) NOT NULL CHECK (projected_hires >= 0),
    actual_hires INT NOT NULL DEFAULT 0 CHECK (actual_hires >= 0),
    event_timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_sourcing_telemetry PRIMARY KEY (event_timestamp, telemetry_id)
) PARTITION BY RANGE (event_timestamp);

-- Time-Series Partitions (Quarterly Rolling Windows for Enterprise Scale)
CREATE TABLE IF NOT EXISTS sourcing_telemetry_2026_q1 PARTITION OF sourcing_telemetry
    FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2026-04-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS sourcing_telemetry_2026_q2 PARTITION OF sourcing_telemetry
    FOR VALUES FROM ('2026-04-01 00:00:00+00') TO ('2026-07-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS sourcing_telemetry_2026_q3 PARTITION OF sourcing_telemetry
    FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS sourcing_telemetry_default PARTITION OF sourcing_telemetry
    DEFAULT;

-- 4. Optimization Solver Runs Audit Store
CREATE TABLE IF NOT EXISTS optimization_runs_audit (
    run_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    campaign_id VARCHAR(64) NOT NULL REFERENCES campaign_master(campaign_id),
    solver_status VARCHAR(64) NOT NULL,
    total_budget_usd NUMERIC(12, 2) NOT NULL,
    allocated_budget_usd NUMERIC(12, 2) NOT NULL,
    budget_utilization_pct NUMERIC(5, 2) NOT NULL,
    projected_hires NUMERIC(8, 2) NOT NULL,
    blended_cost_per_hire_usd NUMERIC(10, 2) NOT NULL,
    naive_heuristic_hires NUMERIC(8, 2) NOT NULL,
    efficiency_gain_pct NUMERIC(6, 2) NOT NULL,
    solve_time_ms NUMERIC(8, 2) NOT NULL,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 5. High-Throughput Production Indexing Strategy
-- BRIN index on timestamp: 95% space reduction on append-only logs
CREATE INDEX IF NOT EXISTS idx_sourcing_telemetry_brin_timestamp 
    ON sourcing_telemetry USING BRIN (event_timestamp) 
    WITH (pages_per_range = 32);

-- Composite B-Tree index for campaign history queries
CREATE INDEX IF NOT EXISTS idx_sourcing_telemetry_campaign_lookup 
    ON sourcing_telemetry (campaign_id, event_timestamp DESC);

-- Composite B-Tree index for channel-corridor aggregation queries
CREATE INDEX IF NOT EXISTS idx_sourcing_telemetry_corridor_lookup 
    ON sourcing_telemetry (channel_name, region, seniority);

-- Index for optimization run lookups by client campaign
CREATE INDEX IF NOT EXISTS idx_optimization_runs_campaign 
    ON optimization_runs_audit (campaign_id, executed_at DESC);