"""
src/domain/contracts.py - Inversion of Dependencies (DIP) Protocols.
Architecture: Anti-Buried Dependencies & Clean Architecture Policy.
All business services depend strictly on these abstract interface protocols.
"""

from typing import Any, Dict, List, Optional, Protocol
import pandas as pd

from .entities import (
    AllocatedSourcingUnit,
    CampaignBudgetConstraint,
    ChannelEfficiencyUnit,
    ExecutiveOptimizationResult,
)


class DataIngestionProtocol(Protocol):
    """Abstract data ingestion interface for sourcing channel telemetry."""

    def ingest_records(self, source_path: str) -> Any:
        """Loads raw telemetry dataset from storage path."""
        ...

    def parse_channel_units(self, raw_data: Any) -> List[ChannelEfficiencyUnit]:
        """Maps tabular dataframe rows into strongly-typed domain entities."""
        ...


class OptimizationEngineProtocol(Protocol):
    """Abstract mathematical decision engine implementing Constrained Linear Optimization."""

    def solve_allocation(
        self,
        channels: List[ChannelEfficiencyUnit],
        constraints: CampaignBudgetConstraint,
    ) -> ExecutiveOptimizationResult:
        """Solves optimal applicant and budget distribution via Simplex / HiGHS."""
        ...

    def evaluate_naive_heuristic(
        self,
        channels: List[ChannelEfficiencyUnit],
        constraints: CampaignBudgetConstraint,
    ) -> Dict[str, Any]:
        """Calculates benchmark metrics using unconstrained pro-rata heuristic allocation."""
        ...


class ExecutiveWorkbookProtocol(Protocol):
    """Abstract reporting contract for DeliveryParadigm.C_LEVEL_EXECUTIVE_SUITE."""

    def generate_executive_suite(
        self,
        result: ExecutiveOptimizationResult,
        output_path: str = "data/Jobgether_Executive_Sourcing_Optimization_Suite.xlsx",
    ) -> str:
        """Renders an institutional C-Level financial workbook with live formulas and DAX rollups."""
        ...


class TelemetryStorageProtocol(Protocol):
    """Abstract analytical storage contract for telemetry and audit logging."""

    def record_optimization_telemetry(self, result: ExecutiveOptimizationResult) -> bool:
        """Persists optimization telemetry into analytical store (PostgreSQL / Lakehouse)."""
        ...