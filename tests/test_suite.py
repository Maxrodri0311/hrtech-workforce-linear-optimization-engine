"""
tests/test_suite.py - Automated Pytest Verification Suite for HRTech & Workforce Intelligence Practice.
Architecture: Mathematical Invariant Assertions, Linear Programming Feasibility,
              Simplex Optimality Proofs, and In-Memory DIP Mock Validation.
"""

from typing import Any, Dict, List
import numpy as np
import polars as pl
import pydantic
import pytest

from src.core_engine import (
    InMemoryTelemetrySink,
    LinearOptimizationEngine,
    OptimizationComparisonService,
    PolarsDataIngestionAdapter,
    create_optimization_pipeline,
)
from src.data_generator import generate_sourcing_dataset
from src.domain.contracts import (
    DataIngestionProtocol,
    OptimizationEngineProtocol,
    TelemetryStorageProtocol,
)
from src.domain.entities import (
    AllocatedSourcingUnit,
    CampaignBudgetConstraint,
    ChannelEfficiencyUnit,
    ExecutiveOptimizationResult,
    RoleSeniority,
    SourcingChannel,
    TalentRegion,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------
@pytest.fixture(scope="session")
def synthetic_sourcing_df() -> pl.DataFrame:
    """Session fixture generating calibrated sourcing observations in memory."""
    return generate_sourcing_dataset(n_samples=3000, seed=42)


@pytest.fixture(scope="session")
def channel_corridors(synthetic_sourcing_df: pl.DataFrame) -> List[ChannelEfficiencyUnit]:
    """Parsed canonical corridor efficiencies."""
    ingestion = PolarsDataIngestionAdapter()
    return ingestion.parse_channel_units(synthetic_sourcing_df)


@pytest.fixture(scope="session")
def standard_constraint() -> CampaignBudgetConstraint:
    """Standard enterprise campaign budget constraint."""
    return CampaignBudgetConstraint(
        campaign_id="CMP-TEST-PYTEST",
        client_name="ScaleUp Global Tech",
        total_budget_usd=100000.0,
        min_total_hires_required=30,
        min_senior_hires_quota=8,
        max_cost_per_hire_target_usd=4000.0,
        regional_diversity_min_pct=0.15,
    )


# -----------------------------------------------------------------------------
# 1. Stochastic Physics & Mathematical Invariants
# -----------------------------------------------------------------------------
def test_stochastic_generator_invariants(synthetic_sourcing_df: pl.DataFrame):
    """
    Asserts stochastic generator physics:
    - Zero null values across all columns
    - All cost-per-applicant values strictly positive (CPA > 0)
    - All channel saturation capacities strictly positive (Cap > 0)
    - All conversion yields strictly bounded within (0.0, 1.0]
    """
    df = synthetic_sourcing_df
    assert len(df) == 3000
    assert sum(df[col].null_count() for col in df.columns) == 0

    cpa = df["cost_per_applicant_usd"].to_numpy()
    assert np.all(cpa > 0.0), "All CPA values must be strictly positive."

    caps = df["max_channel_capacity_applicants"].to_numpy()
    assert np.all(caps > 0), "All monthly channel capacities must be positive."

    yields = df["overall_conversion_yield"].to_numpy()
    assert np.all((yields > 0.0) & (yields <= 1.0)), "Conversion yields must be bounded in (0, 1]."


# -----------------------------------------------------------------------------
# 2. Linear Programming Feasibility & Budget Constraints
# -----------------------------------------------------------------------------
def test_linear_programming_budget_feasibility(
    channel_corridors: List[ChannelEfficiencyUnit],
    standard_constraint: CampaignBudgetConstraint,
):
    """
    Asserts primal linear programming constraints:
    - Total allocated spend never exceeds the client budget ceiling
    - Capacity ceiling respected for all active channel corridors
    - Solver achieves optimal mathematical convergence
    """
    engine = LinearOptimizationEngine()
    result: ExecutiveOptimizationResult = engine.solve_allocation(channel_corridors, standard_constraint)

    assert result.solver_status == "OPTIMAL_CONVERGENCE"
    assert result.total_budget_allocated_usd <= standard_constraint.total_budget_usd + 1e-4, (
        f"Allocated spend (${result.total_budget_allocated_usd:,.2f}) exceeded "
        f"budget ceiling (${standard_constraint.total_budget_usd:,.2f})."
    )
    assert result.budget_utilization_pct <= 100.0
    assert result.total_projected_hires > 0.0

    # Verify corridor capacity constraints
    corridor_map = {
        (ch.channel, ch.region, ch.seniority): ch.max_channel_capacity_applicants
        for ch in channel_corridors
    }
    for alloc in result.allocations:
        key = (alloc.channel, alloc.region, alloc.seniority)
        max_cap = corridor_map[key]
        assert alloc.allocated_applicants <= max_cap, (
            f"Corridor {key} allocation ({alloc.allocated_applicants}) exceeded capacity ({max_cap})."
        )


# -----------------------------------------------------------------------------
# 3. Trade-Off Invariant: LP Superiority over Naive Heuristic
# -----------------------------------------------------------------------------
def test_linear_programming_superiority_over_heuristic(
    channel_corridors: List[ChannelEfficiencyUnit],
    standard_constraint: CampaignBudgetConstraint,
):
    """
    Validates the Central Business Trade-Off:
    Linear Programming optimal resource allocation strictly outperforms naive pro-rata heuristics:
    - Projected hires: Optimal > Naive
    - Blended Cost-per-Hire: Optimal < Naive
    - Significant positive efficiency gain (>= 50%)
    """
    tradeoff = OptimizationComparisonService.evaluate_tradeoff(channel_corridors, standard_constraint)

    naive_hires = tradeoff["naive_heuristic_hires"]
    optimal_hires = tradeoff["optimal_linear_hires"]
    naive_cph = tradeoff["naive_cost_per_hire_usd"]
    optimal_cph = tradeoff["optimal_cost_per_hire_usd"]
    gain_pct = tradeoff["efficiency_gain_pct"]

    assert optimal_hires > naive_hires, (
        f"Optimal hires ({optimal_hires}) must exceed naive hires ({naive_hires})."
    )
    assert optimal_cph < naive_cph, (
        f"Optimal CPH (${optimal_cph:,.2f}) must be lower than naive CPH (${naive_cph:,.2f})."
    )
    assert gain_pct >= 50.0, f"Efficiency gain ({gain_pct}%) below expected >= 50.0% threshold."


# -----------------------------------------------------------------------------
# 4. Domain Schema & Pydantic Boundary Enforcement
# -----------------------------------------------------------------------------
def test_domain_entity_validation():
    """Asserts strict boundary validation on Pydantic domain models."""
    valid_unit = ChannelEfficiencyUnit(
        channel=SourcingChannel.TALENT_NETWORK_POOL,
        region=TalentRegion.LATAM,
        seniority=RoleSeniority.SENIOR_LEAD,
        cost_per_applicant_usd=28.50,
        max_channel_capacity_applicants=850,
        interview_yield_rate=0.3200,
        offer_acceptance_rate=0.4500,
    )
    assert valid_unit.overall_conversion_yield == pytest.approx(0.32 * 0.45, rel=1e-4)
    assert valid_unit.cost_per_hire_benchmark == pytest.approx(28.50 / (0.32 * 0.45), rel=1e-4)

    # Invalid negative CPA rejected
    with pytest.raises(pydantic.ValidationError):
        ChannelEfficiencyUnit(
            channel=SourcingChannel.DIRECT_AI_SOURCING,
            region=TalentRegion.EMEA,
            seniority=RoleSeniority.MID_LEVEL_ENGINEER,
            cost_per_applicant_usd=-10.0,  # Invalid
            max_channel_capacity_applicants=500,
            interview_yield_rate=0.20,
            offer_acceptance_rate=0.40,
        )

    # Invalid negative budget constraint rejected
    with pytest.raises(pydantic.ValidationError):
        CampaignBudgetConstraint(
            campaign_id="CMP-ERR",
            client_name="Invalid Client",
            total_budget_usd=-5000.0,  # Invalid
            min_total_hires_required=10,
        )


# -----------------------------------------------------------------------------
# 5. Dependency Inversion Principle (DIP) & Isolated In-Memory Mocks
# -----------------------------------------------------------------------------
class MockDataIngestionAdapter(DataIngestionProtocol):
    """Zero-disk, sub-1ms mock adapter for domain business testing."""

    def ingest_records(self, source_path: str) -> Any:
        return [
            ChannelEfficiencyUnit(
                channel=SourcingChannel.TALENT_NETWORK_POOL,
                region=TalentRegion.LATAM,
                seniority=RoleSeniority.SENIOR_LEAD,
                cost_per_applicant_usd=20.0,
                max_channel_capacity_applicants=1000,
                interview_yield_rate=0.30,
                offer_acceptance_rate=0.50,
            ),
            ChannelEfficiencyUnit(
                channel=SourcingChannel.PROGRAMMATIC_JOB_BOARDS,
                region=TalentRegion.NORTH_AMERICA,
                seniority=RoleSeniority.JUNIOR_SPECIALIST,
                cost_per_applicant_usd=15.0,
                max_channel_capacity_applicants=5000,
                interview_yield_rate=0.05,
                offer_acceptance_rate=0.30,
            ),
        ]

    def parse_channel_units(self, raw_data: Any) -> List[ChannelEfficiencyUnit]:
        return raw_data


class MockTelemetryStorageAdapter(TelemetryStorageProtocol):
    """In-memory telemetry sink capturing emitted optimization runs."""

    def __init__(self):
        self.sink: List[ExecutiveOptimizationResult] = []

    def record_optimization_telemetry(self, result: ExecutiveOptimizationResult) -> bool:
        self.sink.append(result)
        return True


def test_core_engine_dependency_inversion_mock():
    """
    Validates complete architectural decoupling:
    The core linear solver executes against mocked ingestion and telemetry sinks
    in < 5ms without accessing disk, network, or external databases.
    """
    mock_ingestion = MockDataIngestionAdapter()
    mock_sink = MockTelemetryStorageAdapter()

    corridors = mock_ingestion.parse_channel_units(mock_ingestion.ingest_records("virtual://memory"))
    assert len(corridors) == 2

    constraint = CampaignBudgetConstraint(
        campaign_id="CMP-MOCK-001",
        client_name="Mock Corp",
        total_budget_usd=10000.0,
        min_total_hires_required=5,
        min_senior_hires_quota=2,
    )

    engine = LinearOptimizationEngine()
    result = engine.solve_allocation(corridors, constraint)
    mock_sink.record_optimization_telemetry(result)

    assert len(mock_sink.sink) == 1
    assert mock_sink.sink[0].solver_status == "OPTIMAL_CONVERGENCE"
    assert mock_sink.sink[0].total_budget_allocated_usd <= 10000.0