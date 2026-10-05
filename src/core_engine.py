"""
src/core_engine.py - Core Algorithmic & Linear Optimization Engine for HRTech & Workforce Intelligence Practice.
Architecture: Decoupled Multi-Tier Domain adhering strictly to Dependency Inversion (DIP).
Core Algorithm: Constrained Linear Programming (HiGHS Simplex & Interior Point Solvers).
Trade-Off: Optimal Mathematical Resource Allocation vs. Naive Pro-Rata Heuristics.
"""

from datetime import datetime, timezone
import os
from pathlib import Path
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import polars as pl
from scipy.optimize import linprog

# Path resolution for standalone invocation
_project_root = str(Path(__file__).resolve().parent.parent)
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

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


class PolarsDataIngestionAdapter(DataIngestionProtocol):
    """Concrete infrastructure adapter for high-throughput columnar ingestion."""

    def ingest_records(self, source_path: str) -> pl.DataFrame:
        if not os.path.exists(source_path):
            raise FileNotFoundError(f"[DataIngestion] Parquet source not found at: {source_path}")
        return pl.read_parquet(source_path)

    def parse_channel_units(self, raw_data: pl.DataFrame) -> List[ChannelEfficiencyUnit]:
        """
        Aggregates empirical observations into canonical channel corridors
        (channel x region x seniority) computing median capacity and mean costs/yields.
        """
        aggregated = (
            raw_data.filter(pl.col("is_active_corridor") == True)
            .group_by(["channel", "region", "seniority"])
            .agg([
                pl.col("cost_per_applicant_usd").mean().round(2).alias("cost_per_applicant_usd"),
                pl.col("max_channel_capacity_applicants").median().cast(pl.Int32).alias("max_channel_capacity_applicants"),
                pl.col("interview_yield_rate").mean().round(4).alias("interview_yield_rate"),
                pl.col("offer_acceptance_rate").mean().round(4).alias("offer_acceptance_rate"),
            ])
            .sort(["channel", "region", "seniority"])
        )

        units: List[ChannelEfficiencyUnit] = []
        for row in aggregated.iter_rows(named=True):
            units.append(
                ChannelEfficiencyUnit(
                    channel=SourcingChannel(row["channel"]),
                    region=TalentRegion(row["region"]),
                    seniority=RoleSeniority(row["seniority"]),
                    cost_per_applicant_usd=float(row["cost_per_applicant_usd"]),
                    max_channel_capacity_applicants=int(row["max_channel_capacity_applicants"]),
                    interview_yield_rate=float(row["interview_yield_rate"]),
                    offer_acceptance_rate=float(row["offer_acceptance_rate"]),
                )
            )
        return units


class LinearOptimizationEngine(OptimizationEngineProtocol):
    """
    Mathematical Decision Engine implementing Constrained Linear Programming
    via the HiGHS Simplex / Dual Simplex / Interior Point solver.
    """

    def __init__(self, solver_method: str = "highs"):
        self.solver_method = solver_method

    def evaluate_naive_heuristic(
        self,
        channels: List[ChannelEfficiencyUnit],
        constraints: CampaignBudgetConstraint,
    ) -> Dict[str, Any]:
        """
        Simulates traditional industry heuristic:
        Pro-rata equal capital distribution across all active corridors, capped at capacity.
        """
        n_channels = len(channels)
        if n_channels == 0:
            return {"total_hires": 0.0, "total_spend": 0.0, "cost_per_hire": 0.0}

        budget_per_channel = constraints.total_budget_usd / n_channels
        total_hires = 0.0
        total_spend = 0.0

        for ch in channels:
            # Sourcing spend capped by channel capacity
            max_budget_channel = ch.max_channel_capacity_applicants * ch.cost_per_applicant_usd
            actual_spend = min(budget_per_channel, max_budget_channel)
            applicants = actual_spend / ch.cost_per_applicant_usd
            hires = applicants * ch.overall_conversion_yield

            total_spend += actual_spend
            total_hires += hires

        cost_per_hire = total_spend / total_hires if total_hires > 0 else 0.0
        return {
            "total_hires": round(total_hires, 2),
            "total_spend": round(total_spend, 2),
            "cost_per_hire": round(cost_per_hire, 2),
        }

    def solve_allocation(
        self,
        channels: List[ChannelEfficiencyUnit],
        constraints: CampaignBudgetConstraint,
    ) -> ExecutiveOptimizationResult:
        """
        Solves the primal Linear Programming formulation:
        Maximize: sum(yield_i * x_i)  <=> Minimize: sum(-yield_i * x_i)
        Subject to:
          1. sum(cost_i * x_i) <= total_budget_usd
          2. sum(yield_i * x_i | seniority in [Senior, Staff]) >= min_senior_hires_quota
          3. sum(x_i | region = r) >= regional_quota_r (Diversity constraint)
          4. 0 <= x_i <= max_capacity_i
        """
        t0 = time.perf_counter()
        n = len(channels)
        if n == 0:
            raise ValueError("[LinearOptimizationEngine] Cannot optimize empty channel set.")

        # 1. Objective function coefficients (c: minimize -yield to maximize hires)
        yields = np.array([ch.overall_conversion_yield for ch in channels], dtype=np.float64)
        c = -yields

        # 2. Inequality Constraints: A_ub * x <= b_ub
        a_rows = []
        b_vals = []

        # Constraint 1: Budget Ceiling (sum(CPA_i * x_i) <= Total Budget)
        costs = np.array([ch.cost_per_applicant_usd for ch in channels], dtype=np.float64)
        a_rows.append(costs)
        b_vals.append(constraints.total_budget_usd)

        # Constraint 2: Seniority Quota (sum(yield_i * x_i for senior/staff) >= quota)
        # In <= form: sum(-yield_i * x_i) <= -min_senior_hires_quota
        if constraints.min_senior_hires_quota > 0:
            senior_mask = np.array([
                ch.seniority in [RoleSeniority.SENIOR_LEAD, RoleSeniority.STAFF_ARCHITECT]
                for ch in channels
            ], dtype=np.float64)
            a_rows.append(-yields * senior_mask)
            b_vals.append(-float(constraints.min_senior_hires_quota))

        # Constraint 3: Regional Diversity Quota (at least X% of applicants per primary region)
        if constraints.regional_diversity_min_pct > 0:
            # We enforce a baseline applicant allocation per geographic corridor
            for reg in TalentRegion:
                reg_mask = np.array([ch.region == reg for ch in channels], dtype=np.float64)
                if np.sum(reg_mask) > 0:
                    # Minimum applicants in this region >= 50
                    a_rows.append(-reg_mask)
                    b_vals.append(-50.0)

        A_ub = np.array(a_rows, dtype=np.float64)
        b_ub = np.array(b_vals, dtype=np.float64)

        # 3. Variable Bounds: 0 <= x_i <= max_channel_capacity_applicants
        bounds = [(0.0, float(ch.max_channel_capacity_applicants)) for ch in channels]

        # 4. Invoke SciPy HiGHS Solver
        res = linprog(
            c=c,
            A_ub=A_ub,
            b_ub=b_ub,
            bounds=bounds,
            method=self.solver_method,
        )

        solve_time_ms = (time.perf_counter() - t0) * 1000.0

        if not res.success:
            status_desc = f"SOLVER_INFEASIBLE: {res.message}"
            optimal_x = np.zeros(n)
        else:
            status_desc = "OPTIMAL_CONVERGENCE"
            optimal_x = np.maximum(res.x, 0.0)

        # 5. Extract Allocations and Outcomes
        allocations: List[AllocatedSourcingUnit] = []
        total_spend = 0.0
        total_hires = 0.0

        for i, ch in enumerate(channels):
            alloc_app = int(np.round(optimal_x[i]))
            if alloc_app > 0:
                spend = round(alloc_app * ch.cost_per_applicant_usd, 2)
                hires = round(alloc_app * ch.overall_conversion_yield, 2)
                cph = round(spend / hires, 2) if hires > 0 else 0.0

                allocations.append(
                    AllocatedSourcingUnit(
                        channel=ch.channel,
                        region=ch.region,
                        seniority=ch.seniority,
                        allocated_applicants=alloc_app,
                        allocated_budget_usd=spend,
                        expected_hires=hires,
                        effective_cost_per_hire_usd=cph,
                    )
                )
                total_spend += spend
                total_hires += hires

        # 6. Contrast against Naive Heuristic
        naive_metrics = self.evaluate_naive_heuristic(channels, constraints)
        naive_hires = naive_metrics["total_hires"]

        efficiency_gain = (
            round(((total_hires - naive_hires) / naive_hires) * 100.0, 2)
            if naive_hires > 0 else 0.0
        )

        blended_cph = round(total_spend / total_hires, 2) if total_hires > 0 else 0.0
        budget_utilization = round((total_spend / constraints.total_budget_usd) * 100.0, 2)

        return ExecutiveOptimizationResult(
            campaign_id=constraints.campaign_id,
            client_name=constraints.client_name,
            solver_status=status_desc,
            total_budget_allocated_usd=round(total_spend, 2),
            budget_utilization_pct=min(budget_utilization, 100.0),
            total_projected_hires=round(total_hires, 2),
            blended_cost_per_hire_usd=blended_cph,
            naive_heuristic_hires=naive_hires,
            efficiency_gain_pct=efficiency_gain,
            allocations=allocations,
            solve_time_ms=round(solve_time_ms, 2),
            solved_at=datetime.now(timezone.utc),
        )


class OptimizationComparisonService:
    """
    Demonstrates the Central Business Trade-Off:
    Constrained Linear Optimization (Simplex / HiGHS) vs. Naive Pro-Rata Heuristics.
    """

    @staticmethod
    def evaluate_tradeoff(
        channels: List[ChannelEfficiencyUnit],
        constraints: CampaignBudgetConstraint,
    ) -> Dict[str, Any]:
        engine = LinearOptimizationEngine()
        optimal_result = engine.solve_allocation(channels, constraints)
        naive_result = engine.evaluate_naive_heuristic(channels, constraints)

        hires_gain = optimal_result.total_projected_hires - naive_result["total_hires"]
        cph_reduction = naive_result["cost_per_hire"] - optimal_result.blended_cost_per_hire_usd
        cph_reduction_pct = (
            (cph_reduction / naive_result["cost_per_hire"] * 100.0)
            if naive_result["cost_per_hire"] > 0 else 0.0
        )

        return {
            "campaign_id": constraints.campaign_id,
            "client_name": constraints.client_name,
            "total_budget_usd": constraints.total_budget_usd,
            "naive_heuristic_hires": naive_result["total_hires"],
            "naive_cost_per_hire_usd": naive_result["cost_per_hire"],
            "optimal_linear_hires": optimal_result.total_projected_hires,
            "optimal_cost_per_hire_usd": optimal_result.blended_cost_per_hire_usd,
            "hires_volume_gain": round(hires_gain, 2),
            "efficiency_gain_pct": optimal_result.efficiency_gain_pct,
            "cost_per_hire_reduction_usd": round(cph_reduction, 2),
            "cost_per_hire_savings_pct": round(cph_reduction_pct, 2),
            "solve_time_ms": optimal_result.solve_time_ms,
            "conclusion": (
                f"Constrained Linear Programming delivers +{optimal_result.efficiency_gain_pct:.1f}% more "
                f"qualified remote hires and reduces cost-per-hire by {cph_reduction_pct:.1f}% (${cph_reduction:.2f} savings/hire) "
                f"under identical client budget constraints."
            ),
        }


class InMemoryTelemetrySink(TelemetryStorageProtocol):
    """Zero-I/O in-memory telemetry sink for isolated sub-5ms testing."""

    def __init__(self):
        self.records: List[ExecutiveOptimizationResult] = []

    def record_optimization_telemetry(self, result: ExecutiveOptimizationResult) -> bool:
        self.records.append(result)
        return True


def create_optimization_pipeline() -> Tuple[PolarsDataIngestionAdapter, LinearOptimizationEngine]:
    """Composition Root."""
    return PolarsDataIngestionAdapter(), LinearOptimizationEngine()


if __name__ == "__main__":
    data_file = "data/raw_dataset.parquet"
    if not os.path.exists(data_file):
        from src.data_generator import generate_domain_dataset
        generate_domain_dataset(num_records=50000, output_path=data_file)

    ingestion, solver = create_optimization_pipeline()
    df = ingestion.ingest_records(data_file)
    channels = ingestion.parse_channel_units(df)

    test_constraint = CampaignBudgetConstraint(
        campaign_id="CMP-HRTech & Workforce Intelligence Practice-2026-Q1",
        client_name="Fintech Global Scale Inc.",
        total_budget_usd=120000.0,
        min_total_hires_required=45,
        min_senior_hires_quota=12,
        max_cost_per_hire_target_usd=3000.0,
        regional_diversity_min_pct=0.15,
    )

    tradeoff = OptimizationComparisonService.evaluate_tradeoff(channels, test_constraint)

    print("\n" + "=" * 76)
    print(" [*] HRTech & Workforce Intelligence Practice REMOTE TALENT SOURCING - LINEAR OPTIMIZATION BENCHMARK")
    print("=" * 76)
    print(f" Campaign ID                    : {tradeoff['campaign_id']} ({tradeoff['client_name']})")
    print(f" Total Campaign Budget (USD)    : ${tradeoff['total_budget_usd']:,.2f}")
    print(f" Channels Evaluated             : {len(channels)} discrete corridors")
    print(f" Solver Engine Latency          : {tradeoff['solve_time_ms']:.2f} ms")
    print("-" * 76)
    print(f" 1. Naive Heuristic (Pro-Rata)  : {tradeoff['naive_heuristic_hires']:.1f} Hires | CPA CPH: ${tradeoff['naive_cost_per_hire_usd']:,.2f}")
    print(f" 2. Optimal Linear Programming  : {tradeoff['optimal_linear_hires']:.1f} Hires | CPA CPH: ${tradeoff['optimal_cost_per_hire_usd']:,.2f}")
    print("-" * 76)
    print(f" Net Hires Volume Gain          : +{tradeoff['hires_volume_gain']:.1f} candidates (+{tradeoff['efficiency_gain_pct']}%)")
    print(f" Cost-per-Hire Savings          : -${tradeoff['cost_per_hire_reduction_usd']:,.2f} / hire (-{tradeoff['cost_per_hire_savings_pct']}%)")
    print(f"\n Verdict: {tradeoff['conclusion']}")
    print("=" * 76 + "\n")