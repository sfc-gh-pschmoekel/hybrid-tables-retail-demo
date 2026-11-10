"""Benchmark parameterized point lookups: hybrid CUSTOMERS vs standard CUSTOMERS_STD.

This is how an application actually queries: the same statement with bind variables,
repeated many times. Usage:

    pip install snowflake-connector-python
    SNOWFLAKE_CONNECTION_NAME=<your connection> python scripts/benchmark_lookups.py
"""
import os
import random
import statistics
import time

import snowflake.connector

RUNS = 100
WARMUP = 10

conn = snowflake.connector.connect(
    connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME", "default"),
    database="DEMO",
    schema="HYBRID_RETAIL",
    warehouse=os.getenv("HT_DEMO_WAREHOUSE", "HT_DEMO_WH"),
)
cur = conn.cursor()
cur.execute("ALTER SESSION SET USE_CACHED_RESULT = FALSE")

lookups = [
    ("customer_id", lambda: random.randint(1, 1_000_000)),
    ("email", lambda: f"customer{random.randint(1, 1_000_000)}@example.com"),
]

print(f"{'table':15} {'lookup':12} {'p50 ms':>8} {'p95 ms':>8}")
for table in ["CUSTOMERS", "CUSTOMERS_STD"]:
    for column, value in lookups:
        times = []
        for _ in range(RUNS):
            start = time.perf_counter()
            cur.execute(f"SELECT * FROM {table} WHERE {column} = %s", (value(),))
            cur.fetchall()
            times.append((time.perf_counter() - start) * 1000)
        warm = sorted(times[WARMUP:])
        p95 = warm[int(len(warm) * 0.95)]
        print(f"{table:15} {column:12} {statistics.median(warm):8.0f} {p95:8.0f}")

conn.close()
