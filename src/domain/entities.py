"""
src/domain/entities.py - Pure Domain Entities for Jobgether Remote Talent Optimization.
Architecture: Clean Architecture & Strict Pydantic Contracts.
Zero external I/O or vendor infrastructure dependencies.
"""

from datetime import datetime, timezone
from enum import Enum
from typing import Dict, List, Optional
from pydantic import BaseModel, Field, field_validator


class SourcingChannel(str, Enum):
    """Available sourcing distribution channels in Jobgether marketplace."""
    PROGRAMMATIC_JOB_BOARDS = "Programmatic Job Boards"
    DIRECT_AI_SOURCING = "Direct AI Sourcing"
    SPONSORED_CAMPAIGNS = "Sponsored Campaigns"
    TALENT_NETWORK_POOL = "Talent Network Pool"
    EXECUTIVE_HEADHUNTING = "Executive Headhunting"


class TalentRegion(str, Enum):
    """Target geographic talent corridors for remote placement."""
    LATAM = "LATAM"
    EMEA = "EMEA"
    NORTH_AMERICA = "North America"
    APAC = "APAC"


class RoleSeniority(str, Enum):
    """Technical seniority levels for remote talent placement."""
    JUNIOR_SPECIALIST = "Junior Specialist"
    MID_LEVEL_ENGINEER = "Mid-Level Engineer"
    SENIOR_LEAD = "Senior Lead"
    STAFF_ARCHITECT = "Staff Architect"


class ChannelEfficiencyUnit(BaseModel):
    """Domain model representing empirical cost, capacity, and conversion efficiency per channel corridor."""
    channel: SourcingChannel
    region: TalentRegion
    seniority: RoleSeniority
    cost_per_applicant_usd: float = Field(..., gt=0.0, description="Empirical acquisition cost per applicant")
    max_channel_capacity_applicants: int = Field(..., gt=0, description="Monthly applicant saturation ceiling")
    interview_yield_rate: float = Field(..., gt=0.0, le=1.0, description="P(Interview | Applicant)")
    offer_acceptance_rate: float = Field(..., gt=0.0, le=1.0, description="P(Hire | Interview)")

    @property
    def overall_conversion_yield(self) -> float:
        """Overall joint probability of converting an applicant into a successful hire."""
        return self.interview_yield_rate * self.offer_acceptance_rate

    @property
    def cost_per_hire_benchmark(self) -> float:
        """Theoretical cost per hire assuming unconstrained capacity."""
        if self.overall_conversion_yield <= 0:
            return float("inf")
        return self.cost_per_applicant_usd / self.overall_conversion_yield


class CampaignBudgetConstraint(BaseModel):
    """Formal linear constraints bounding client recruitment campaign."""
    campaign_id: str = Field(..., min_length=3)
    client_name: str = Field(..., min_length=2)
    total_budget_usd: float = Field(..., gt=0.0, description="Max client budget ceiling")
    min_total_hires_required: int = Field(..., gt=0, description="Minimum aggregate hires guaranteed by SLA")
    min_senior_hires_quota: int = Field(default=0, ge=0, description="Minimum hires for Senior/Staff roles")
    max_cost_per_hire_target_usd: float = Field(default=12000.0, gt=0.0)
    regional_diversity_min_pct: float = Field(default=0.15, ge=0.0, le=0.50)


class AllocatedSourcingUnit(BaseModel):
    """Optimal decision variable outcome for a specific channel corridor."""
    channel: SourcingChannel
    region: TalentRegion
    seniority: RoleSeniority
    allocated_applicants: int = Field(..., ge=0)
    allocated_budget_usd: float = Field(..., ge=0.0)
    expected_hires: float = Field(..., ge=0.0)
    effective_cost_per_hire_usd: float = Field(default=0.0, ge=0.0)


class ExecutiveOptimizationResult(BaseModel):
    """Aggregate C-Level result of the Linear Programming allocation."""
    campaign_id: str
    client_name: str
    solver_status: str
    total_budget_allocated_usd: float = Field(..., ge=0.0)
    budget_utilization_pct: float = Field(..., ge=0.0, le=100.0)
    total_projected_hires: float = Field(..., ge=0.0)
    blended_cost_per_hire_usd: float = Field(..., ge=0.0)
    naive_heuristic_hires: float = Field(..., ge=0.0)
    efficiency_gain_pct: float = Field(..., description="Percentage gain over naive heuristic allocation")
    allocations: List[AllocatedSourcingUnit] = Field(default_factory=list)
    solve_time_ms: float = Field(..., ge=0.0)
    solved_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))