@echo off
setlocal enabledelayedexpansion

echo ================================================================================
echo   JOBGETHER: SOURCING LINEAR OPTIMIZATION AND FINANCE ENGINE
echo   Automated Execution, Verification, Benchmarks and CI Guards
echo ================================================================================
echo.

echo [1/6] Ingesting and Synthesizing Stochastic Domain Telemetry (50,000 records)...
python src/data_generator.py --records 50000
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Telemetry synthesis failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [2/6] Executing Primal Linear Optimization Solver (HiGHS Simplex)...
python src/core_engine.py
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Optimization engine execution failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [3/6] Generating Institutional C-Level Executive Financial Suite (Excel)...
python src/interface.py
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Executive workbook generation failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [4/6] Running Automated Pytest Mathematical Invariant Suite...
python -m pytest tests/ -v
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Pytest suite failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [5/6] Executing Latency SLA and Peak Heap Memory Benchmark (30 iterations)...
python tests/benchmark.py
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Benchmark profiling failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [6/6] Verifying Polyglot CI Quality and Architecture Guards...
python scripts/validate_sql_minimum_viable.py
if %ERRORLEVEL% NEQ 0 (exit /b %ERRORLEVEL%)

python scripts/validate_terraform_minimum_viable.py
if %ERRORLEVEL% NEQ 0 (exit /b %ERRORLEVEL%)

python scripts/validate_no_internal_leaks.py
if %ERRORLEVEL% NEQ 0 (exit /b %ERRORLEVEL%)

echo.
echo ================================================================================
echo   [SUCCESS] All 6 Verification Stages, SLAs and CI Guards Passed Flawlessly!
echo ================================================================================