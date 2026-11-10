# Hybrid Tables Retail Demo

A Snowflake hybrid tables demo built around a retail "store associate" app:

1. **Point lookups**: find a customer by ID or email and see their recent orders, hybrid vs standard table side by side.
2. **Enforced integrity**: PRIMARY KEY, UNIQUE, FOREIGN KEY, and CHECK constraints reject bad data (standard tables do not).
3. **One atomic transaction** across hybrid and standard tables (order + audit row).
4. **Analytics on live data**: hybrid orders joined with standard sales history in the same engine. No ETL, no federation.

All data is synthetic.

## Prerequisites

- A non-trial Snowflake account in an AWS or Azure commercial region (GA), or GCP (preview)
- A role that can create a schema in a standard (non-transient) database, a warehouse, and a Streamlit app
- Tri-Secret Secure and periodic data rekeying not enabled
- [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) 3.14+ to deploy the app

## What gets created

| Object | Type | Purpose |
| --- | --- | --- |
| `DEMO.HYBRID_RETAIL` | Schema | Everything lives here |
| `STORES`, `PRODUCTS`, `CUSTOMERS`, `ORDERS`, `ORDER_ITEMS` | Hybrid tables | Operational data (500 / 10K / 1M / 2M / 4M rows) |
| `CUSTOMERS_STD` | Standard table | Same customers, for the lookup comparison |
| `SALES_HISTORY` | Standard table | 20M rows of historical sales for analytics |
| `ORDER_AUDIT` | Standard table | Audit rows written in the same transaction as orders |
| `ORDER_ID_SEQ` | Sequence | Order ids for orders placed from the app |
| `HT_DEMO_WH` | Warehouse (XSMALL) | Serves the operational queries (see below) |
| `HYBRID_RETAIL_APP` | Streamlit app | The associate app |

### Why a separate warehouse

`HT_DEMO_WH` has `ENABLE_USE_STABLE_PATH = TRUE`, which turns on Snowflake's optimized path for
[operational queries on hybrid tables](https://docs.snowflake.com/en/user-guide/hybrid-tables-operational-query-performance)
(repeated, short, parameterized statements that touch only hybrid tables). It is a warehouse-level setting and in
public preview, so it is isolated on its own warehouse rather than changing a shared one. This also mirrors a real
deployment: one warehouse serves the app, another serves analytics.

## Run order

1. `sql/01_setup.sql`: schema and warehouse
2. `sql/02_create_and_load.sql`: tables and data (about 10 to 15 minutes on XSMALL)
3. Deploy the app:
   ```bash
   cd streamlit
   snow streamlit deploy --replace --prune --connection <your connection>
   ```
   Edit `streamlit/snowflake.yml` first if your compute pool is not `SYSTEM_COMPUTE_POOL_CPU`.
4. `sql/03_demo_worksheet.sql`: the live talk track. Run it **section by section** (Section B is supposed to fail).
5. Optional: `scripts/benchmark_lookups.py` for a parameterized lookup benchmark.
6. `sql/04_teardown.sql` when you are done.

## Reading the latency numbers honestly

- Hybrid tables never use the results cache, so the demo turns it off for the standard table too.
- In a worksheet, each query uses literal values and compiles from scratch (around 100 to 200 ms). That compile time
  hides the difference. Apps use bind variables, so the plan is reused and hybrid-only queries can take the optimized
  path. Use the app or the benchmark script for the realistic comparison.
- Baseline observed (XSMALL, 1M customers, parameterized, warm, median round trip from a laptop):

  | Lookup | Hybrid | Standard |
  | --- | --- | --- |
  | By customer_id | ~70 ms | ~150 ms |
  | By email | ~70 ms | ~150 ms |

- The email lookup is the fairest comparison: `CUSTOMERS_STD` is loaded in customer_id order, so the standard table
  can prune micro-partitions on id but not on email.
- Standard-table writes and commits cost more than hybrid row writes (micro-partition rewrite). The app's Place Order
  tab shows the per-step split.

## Hybrid tables limitations to know

See [Limitations and unsupported features](https://docs.snowflake.com/en/user-guide/tables-hybrid-limitations). Highlights:

- 2 TB of hybrid storage per database; roughly 16,000 operations per second per database (80/20 read/write)
- Not supported: streams, dynamic tables, materialized views, data sharing, replication, Snowpipe, clustering keys,
  search optimization, Fail-safe, UNDROP
- No temporary or transient hybrid tables
- CTAS cannot define FOREIGN KEYs (create the table, then `INSERT ... SELECT`)
- No results cache
- Larger storage footprint than standard tables (row store compresses less)
