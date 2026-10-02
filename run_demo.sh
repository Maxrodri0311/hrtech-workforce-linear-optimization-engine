#!/usr/bin/env bash
set -e

echo "================================================================================"
echo "  JOBGETHER: SOURCING LINEAR OPTIMIZATION & FINANCE ENGINE"
echo "  Automated Execution, Verification, Benchmarks & CI Guards"
echo "================================================================================"
echo ""

echo "[1/6] Ingesting & Synthesizing Stochastic Domain Telemetry (50,000 records)..."
python src/data_generator.py --records 50000

echo ""
echo "[2/6] Executing Primal Linear Optimization Solver (HiGHS Simplex)..."
python src/core_engine.py

echo ""
echo "[3/6] Generating Institutional C-Level Executive Financial Suite (Excel)..."
python src/interface.py

echo ""
echo "[4/6] Running Automated Pytest Mathematical Invariant Suite..."
python -m pytest tests/ -v

echo ""
echo "[5/6] Executing Latency SLA & Peak Heap Memory Benchmark (30 iterations)..."
python tests/benchmark.py

echo ""
echo "[6/6] Verifying Polyglot CI Quality & Architecture Guards..."
python scripts/validate_sql_minimum_viable.py
python scripts/validate_terraform_minimum_viable.py
python scripts/validate_no_internal_leaks.py

echo ""
echo "================================================================================"
echo "  [SUCCESS] All 6 Verification Stages, SLAs & CI Guards Passed Flawlessly!"
echo "================================================================================"