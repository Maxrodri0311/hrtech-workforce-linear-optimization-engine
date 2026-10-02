"""
tests/benchmark.py - Quantitative Latency & Memory Benchmark for Jobgether.
Architecture: Dual-Tier Latency SLA Profiling (Real-Time Linear Programming Solver & Corridor Aggregation).
Enforces Production SLA Constraints:
  - Linear Programming Primal Solver: p95 < 150.0 ms
  - Sourcing Telemetry Corridor Aggregation: p95 < 50.0 ms
  - Peak Heap Memory Allocation: < 15.0 MB
"""

from pathlib import Path
import sys
import time
import tracemalloc
from typing import Dict, List

import numpy as np
import polars as pl

# Robust path resolution
project_root = str(Path(__file__).resolve().parent.parent)
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from src.core_engine import LinearOptimizationEngine, PolarsDataIngestionAdapter
from src.data_generator import generate_sourcing_dataset
from src.domain.entities import CampaignBudgetConstraint


def run_benchmarks(iterations: int = 30, num_records: int = 10000) -> Dict[str, float]:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    print(f"[*] [Benchmark] Synthesizing calibrated dataset ({num_records:,} observations)...")
    df: pl.DataFrame = generate_sourcing_dataset(n_samples=num_records, seed=42)
    ingestion = PolarsDataIngestionAdapter()

    # -------------------------------------------------------------------------
    # 1. Memory Profile (Isolated pass to avoid allocator instrumentation overhead)
    # -------------------------------------------------------------------------
    tracemalloc.start()
    channels = ingestion.parse_channel_units(df)
    test_constraint = CampaignBudgetConstraint(
        campaign_id="CMP-BENCHMARK-RUN",
        client_name="Global Enterprise Tech",
        total_budget_usd=150000.0,
        min_total_hires_required=50,
        min_senior_hires_quota=15,
        max_cost_per_hire_target_usd=3500.0,
        regional_diversity_min_pct=0.15,
    )
    engine = LinearOptimizationEngine()
    _ = engine.solve_allocation(channels, test_constraint)
    _, peak_mem_bytes = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    peak_mem_mb = peak_mem_bytes / (1024.0 * 1024.0)

    # -------------------------------------------------------------------------
    # 2. Micro-Benchmark: Sourcing Corridor Columnar Aggregation (Polars)
    # -------------------------------------------------------------------------
    agg_latencies: List[float] = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        _ = ingestion.parse_channel_units(df)
        agg_latencies.append((time.perf_counter() - t0) * 1000.0)

    p50_agg = float(np.percentile(agg_latencies, 50))
    p95_agg = float(np.percentile(agg_latencies, 95))
    p99_agg = float(np.percentile(agg_latencies, 99))

    # -------------------------------------------------------------------------
    # 3. Macro-Benchmark: Constrained Linear Programming Primal Solver (HiGHS)
    # -------------------------------------------------------------------------
    # Warmup
    _ = engine.solve_allocation(channels, test_constraint)

    solver_latencies: List[float] = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        res = engine.solve_allocation(channels, test_constraint)
        solver_latencies.append((time.perf_counter() - t0) * 1000.0)

    p50_solver = float(np.percentile(solver_latencies, 50))
    p95_solver = float(np.percentile(solver_latencies, 95))
    p99_solver = float(np.percentile(solver_latencies, 99))
    mean_solver_lat = float(np.mean(solver_latencies))
    solver_throughput = float(1000.0 / mean_solver_lat) if mean_solver_lat > 0 else 0.0

    status_agg = "PASS" if p95_agg < 50.0 else "FAIL"
    status_solver = "PASS" if p95_solver < 150.0 else "FAIL"
    status_mem = "PASS" if peak_mem_mb < 15.0 else "FAIL"

    print("\n" + "=" * 74)
    print("  JOBGETHER LINEAR OPTIMIZATION ENGINE - QUANTITATIVE BENCHMARK REPORT")
    print("=" * 74)
    print(f"  Dataset Population       : {num_records:,} total historical observations")
    print(f"  Profiling Iterations     : {iterations} passes")
    print(f"  Corridors Optimized      : {len(channels)} discrete decision variables")
    print("-" * 74)
    print(f"  1. Columnar Sourcing Aggregation (Polars):")
    print(f"     -> p50: {p50_agg:.2f} ms | p95: {p95_agg:.2f} ms | p99: {p99_agg:.2f} ms")
    print(f"     -> Production SLA Target : p95 < 50.0 ms [{status_agg}]")
    print("-" * 74)
    print(f"  2. Constrained Linear Programming Solver (HiGHS Simplex):")
    print(f"     -> p50: {p50_solver:.2f} ms | p95: {p95_solver:.2f} ms | p99: {p99_solver:.2f} ms")
    print(f"     -> Solver Throughput     : {solver_throughput:,.1f} optimizations/sec")
    print(f"     -> Production SLA Target : p95 < 150.0 ms [{status_solver}]")
    print("-" * 74)
    print(f"  3. Memory Footprint Profile:")
    print(f"     -> Peak Heap Allocation  : {peak_mem_mb:.2f} MB [SLA < 15.0 MB: {status_mem}]")
    print("=" * 74)

    # Formal Production SLA Assertions
    assert p95_agg < 50.0, f"Aggregation SLA breached: p95={p95_agg:.2f}ms >= 50.0ms target."
    assert p95_solver < 150.0, f"Solver SLA breached: p95={p95_solver:.2f}ms >= 150.0ms target."
    assert peak_mem_mb < 15.0, f"Memory threshold breached: peak={peak_mem_mb:.2f}MB >= 15.0MB."

    print("  [+] All quantitative SLA and memory constraints verified successfully.\n")

    return {
        "p50_agg_ms": round(p50_agg, 2),
        "p95_agg_ms": round(p95_agg, 2),
        "p50_solver_ms": round(p50_solver, 2),
        "p95_solver_ms": round(p95_solver, 2),
        "throughput_ops": round(solver_throughput, 1),
        "peak_mem_mb": round(peak_mem_mb, 2),
    }


if __name__ == "__main__":
    run_benchmarks()