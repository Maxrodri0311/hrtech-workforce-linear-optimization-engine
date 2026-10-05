-- ==============================================================================
-- HRTech & Workforce Intelligence Practice Remote Talent Optimization - Real-Time Anomaly & Escalation Triggers
-- Target: PostgreSQL 16 Enterprise / Amazon RDS Aurora Multi-AZ
-- Architecture: PL/pgSQL Event Functions, Anomaly Audit Log & Dynamic Alerts
-- ==============================================================================

SET search_path TO jobgether_analytics, public;

-- 1. Sourcing Anomaly Audit Log
CREATE TABLE IF NOT EXISTS sourcing_anomaly_audit_log (
    anomaly_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    campaign_id VARCHAR(64) NOT NULL,
    channel_name VARCHAR(64) NOT NULL,
    region VARCHAR(32) NOT NULL,
    seniority VARCHAR(32) NOT NULL,
    observed_cpa_usd NUMERIC(8, 2) NOT NULL,
    baseline_cpa_usd NUMERIC(8, 2) NOT NULL,
    observed_yield NUMERIC(8, 5) NOT NULL,
    escalation_tier VARCHAR(32) NOT NULL,
    alert_payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sourcing_anomaly_campaign_created
    ON sourcing_anomaly_audit_log (campaign_id, created_at DESC);

-- 2. Trigger Function: Real-Time Cost Surge & Conversion Collapse Detection
CREATE OR REPLACE FUNCTION fn_detect_cpa_anomaly_and_alert()
RETURNS TRIGGER AS $$
DECLARE
    v_baseline_cpa NUMERIC(8, 2);
    v_client_name VARCHAR(128);
    v_escalation_tier VARCHAR(32);
    v_cpa_surge_ratio NUMERIC(6, 2);
BEGIN
    -- Retrieve baseline expected CPA from corridor registry
    SELECT baseline_cpa_usd 
    INTO v_baseline_cpa
    FROM channel_corridor_registry
    WHERE channel_name = NEW.channel_name
      AND region = NEW.region
      AND seniority = NEW.seniority;

    -- Default fallback if corridor unindexed
    IF v_baseline_cpa IS NULL THEN
        v_baseline_cpa := 40.00;
    END IF;

    -- Compute surge multiplier
    v_cpa_surge_ratio := ROUND((NEW.cost_per_applicant_usd / NULLIF(v_baseline_cpa, 0))::numeric, 2);

    -- Anomaly Condition 1: CPA surge exceeds 1.45x baseline
    -- Anomaly Condition 2: Conversion yield collapse below 0.5% (0.00500)
    IF v_cpa_surge_ratio >= 1.45 OR NEW.overall_conversion_yield <= 0.00500 THEN

        -- Retrieve client branding for notification payload
        SELECT client_name INTO v_client_name
        FROM campaign_master
        WHERE campaign_id = NEW.campaign_id;

        IF v_cpa_surge_ratio >= 2.00 OR NEW.overall_conversion_yield <= 0.00200 THEN
            v_escalation_tier := 'P1_CRITICAL_BUDGET_DRAIN';
        ELSE
            v_escalation_tier := 'P2_ELEVATED_DRIFT_WARNING';
        END IF;

        INSERT INTO sourcing_anomaly_audit_log (
            campaign_id,
            channel_name,
            region,
            seniority,
            observed_cpa_usd,
            baseline_cpa_usd,
            observed_yield,
            escalation_tier,
            alert_payload
        ) VALUES (
            NEW.campaign_id,
            NEW.channel_name,
            NEW.region,
            NEW.seniority,
            NEW.cost_per_applicant_usd,
            v_baseline_cpa,
            NEW.overall_conversion_yield,
            v_escalation_tier,
            jsonb_build_object(
                'event', 'Sourcing Corridors Anomaly Triggered',
                'campaign_id', NEW.campaign_id,
                'client_name', COALESCE(v_client_name, 'Enterprise Client'),
                'channel', NEW.channel_name,
                'corridor', CONCAT(NEW.region, ' - ', NEW.seniority),
                'cpa_observed', NEW.cost_per_applicant_usd,
                'cpa_baseline', v_baseline_cpa,
                'surge_multiplier', v_cpa_surge_ratio,
                'conversion_yield', NEW.overall_conversion_yield,
                'recommended_action', CASE 
                    WHEN v_cpa_surge_ratio >= 2.00 THEN 'Immediate Channel Throttling & Reallocate to Talent Network'
                    ELSE 'Adjust Linear Optimization Channel Upper Bound'
                END,
                'evaluated_at', CURRENT_TIMESTAMP
            )
        );

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Bind Trigger to Sourcing Telemetry
DROP TRIGGER IF EXISTS trg_detect_sourcing_anomaly ON sourcing_telemetry;

CREATE TRIGGER trg_detect_sourcing_anomaly
AFTER INSERT ON sourcing_telemetry
FOR EACH ROW
EXECUTE FUNCTION fn_detect_cpa_anomaly_and_alert();