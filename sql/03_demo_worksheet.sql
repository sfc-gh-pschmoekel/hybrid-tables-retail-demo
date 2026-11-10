-- 03_demo_worksheet.sql
-- Live talk track. Run section by section in a Snowsight worksheet (not "Run All":
-- Section B is SUPPOSED to fail, and Run All stops at the first error).

USE WAREHOUSE HT_DEMO_WH;   -- dedicated warehouse with the optimized operational-query path (see 01_setup.sql)
USE SCHEMA DEMO.HYBRID_RETAIL;

-- Hybrid tables never use the results cache. Turn it off for the session so the
-- standard-table comparison is fair (otherwise the second standard query returns from cache).
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Tag every demo query so we can pull timings from QUERY_HISTORY afterwards.
ALTER SESSION SET QUERY_TAG = 'HT_DEMO_LOOKUP';


------------------------------------------------------------
-- SECTION A: Point lookups (the store associate looks up a customer)
------------------------------------------------------------
-- Talk track: "A customer walks up to the counter and gives their email.
-- The app needs their profile and recent orders right now, for thousands of associates at once."
--
-- IMPORTANT, read before presenting:
--   * In a worksheet each query uses literal values, so Snowflake compiles it from scratch
--     (about 100-200 ms of compile time). That compile cost hides the hybrid advantage here.
--   * A real app sends the SAME statement with bind variables (?), so the plan is reused and
--     hybrid-only queries can take the optimized path. That is the realistic number.
--   * For the realistic comparison, use the Streamlit app (Customer Lookup tab) or
--     scripts/benchmark_lookups.py. Observed baseline on XSMALL, 1M customers, median:
--       hybrid ~70 ms vs standard ~150 ms (round trip, parameterized, warm).
--   * Use A5 below to show the split between compile and execution time.
--   * The email lookup is the fairest comparison: CUSTOMERS_STD happens to be loaded in
--     customer_id order, so Snowflake can prune micro-partitions on id but not on email.

-- A1. Lookup by primary key: hybrid vs standard
SELECT * FROM CUSTOMERS     WHERE customer_id = 424242;
SELECT * FROM CUSTOMERS_STD WHERE customer_id = 424242;

-- A2. Lookup by email (UNIQUE constraint = an index on the hybrid table; the standard table has no index)
SELECT * FROM CUSTOMERS     WHERE email = 'customer777777@example.com';
SELECT * FROM CUSTOMERS_STD WHERE email = 'customer777777@example.com';

-- A3. Customer profile + recent orders (hybrid join, uses the customer_id FK index on ORDERS)
SELECT c.customer_id, c.first_name, c.last_name, c.loyalty_tier,
       o.order_id, o.order_ts, o.order_status, o.order_total
FROM CUSTOMERS c
JOIN ORDERS o ON o.customer_id = c.customer_id
WHERE c.email = 'customer777777@example.com'
ORDER BY o.order_ts DESC
LIMIT 10;

-- A4. Repeat a handful of lookups to show the latency is consistent, not a one-off
SELECT * FROM CUSTOMERS WHERE customer_id = 11;
SELECT * FROM CUSTOMERS WHERE customer_id = 250001;
SELECT * FROM CUSTOMERS WHERE customer_id = 999999;
SELECT * FROM CUSTOMERS_STD WHERE customer_id = 11;
SELECT * FROM CUSTOMERS_STD WHERE customer_id = 250001;
SELECT * FROM CUSTOMERS_STD WHERE customer_id = 999999;

-- A5. Server-side timings for the queries above (the honest number; the UI adds round-trip time).
-- QUERY_HISTORY can take a few seconds to show the latest queries.
SELECT
    CASE WHEN query_text ILIKE '%CUSTOMERS_STD%' THEN 'STANDARD' ELSE 'HYBRID' END AS table_type,
    LEFT(query_text, 80)  AS query,
    total_elapsed_time    AS total_ms,
    execution_time        AS exec_ms,
    compilation_time      AS compile_ms
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
WHERE query_tag = 'HT_DEMO_LOOKUP'
  AND query_type = 'SELECT'
  AND query_text ILIKE 'SELECT * FROM CUSTOMERS%'
ORDER BY start_time;

-- A6. Summary: median latency per table type
SELECT
    CASE WHEN query_text ILIKE '%CUSTOMERS_STD%' THEN 'STANDARD' ELSE 'HYBRID' END AS table_type,
    COUNT(*)                         AS queries,
    MEDIAN(total_elapsed_time)       AS median_total_ms,
    MEDIAN(execution_time)           AS median_exec_ms
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
WHERE query_tag = 'HT_DEMO_LOOKUP'
  AND query_type = 'SELECT'
  AND query_text ILIKE 'SELECT * FROM CUSTOMERS%'
GROUP BY 1;

ALTER SESSION UNSET QUERY_TAG;


------------------------------------------------------------
-- SECTION B: Constraint enforcement (Snowflake rejects bad data)
------------------------------------------------------------
-- Talk track: "On standard tables, PRIMARY KEY / UNIQUE / FOREIGN KEY are informational only.
-- On hybrid tables they are enforced. Each statement below is EXPECTED TO FAIL."

-- B1. Duplicate primary key
INSERT INTO CUSTOMERS (customer_id, email, first_name, last_name, loyalty_tier, home_store_id, created_at)
VALUES (1, 'brand.new@example.com', 'Dup', 'Key', 'GOLD', 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

-- B2. Duplicate email (UNIQUE)
INSERT INTO CUSTOMERS (customer_id, email, first_name, last_name, loyalty_tier, home_store_id, created_at)
VALUES (2000001, 'customer1@example.com', 'Dup', 'Email', 'GOLD', 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

-- B3. Order for a customer that does not exist (FOREIGN KEY)
INSERT INTO ORDERS (order_id, customer_id, store_id, order_status, order_ts, order_total)
VALUES (9000001, 99999999, 1, 'PLACED', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 25.00);

-- B4. Order line for a product that does not exist (FOREIGN KEY)
INSERT INTO ORDER_ITEMS (order_id, line_no, product_id, quantity, unit_price)
VALUES (1, 99, 99999999, 1, 9.99);

-- B5. Negative quantity (CHECK)
INSERT INTO ORDER_ITEMS (order_id, line_no, product_id, quantity, unit_price)
VALUES (1, 99, 1, -5, 9.99);

-- B6. Delete a customer who still has orders (FOREIGN KEY protects the parent)
DELETE FROM CUSTOMERS WHERE customer_id = (SELECT customer_id FROM ORDERS LIMIT 1);

-- B7. Contrast: the standard table happily accepts a duplicate "primary key" and email
INSERT INTO CUSTOMERS_STD (customer_id, email, first_name, last_name, loyalty_tier, home_store_id, created_at)
VALUES (1, 'customer1@example.com', 'Dup', 'Key', 'GOLD', 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

SELECT customer_id, email, first_name, last_name FROM CUSTOMERS_STD WHERE customer_id = 1;  -- two rows

-- Clean up the duplicate in the standard table
DELETE FROM CUSTOMERS_STD WHERE customer_id = 1 AND first_name = 'Dup';


------------------------------------------------------------
-- SECTION C: One atomic transaction across hybrid and standard tables
------------------------------------------------------------
-- Talk track: "Place an order (hybrid) and write the audit trail (standard) together.
-- Either both happen or neither does. No two-phase commit, no second database."

BEGIN TRANSACTION;

INSERT INTO ORDERS (order_id, customer_id, store_id, order_status, order_ts, order_total)
VALUES (9100001, 424242, 17, 'PLACED', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 59.97);

INSERT INTO ORDER_ITEMS (order_id, line_no, product_id, quantity, unit_price)
VALUES (9100001, 1, 1234, 3, 19.99);

INSERT INTO ORDER_AUDIT (order_id, action, detail)
VALUES (9100001, 'PLACED', 'Order placed at store 17 by associate demo');

COMMIT;

SELECT * FROM ORDERS      WHERE order_id = 9100001;
SELECT * FROM ORDER_AUDIT WHERE order_id = 9100001;

-- C2. Rollback: a failed statement inside the transaction, then roll back. Nothing is written.
BEGIN TRANSACTION;
INSERT INTO ORDER_AUDIT (order_id, action, detail) VALUES (9100002, 'PLACED', 'should not persist');
INSERT INTO ORDERS (order_id, customer_id, store_id, order_status, order_ts, order_total)
VALUES (9100002, 99999999, 17, 'PLACED', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 10.00);  -- fails: FK
ROLLBACK;

SELECT COUNT(*) AS should_be_zero FROM ORDER_AUDIT WHERE order_id = 9100002;

-- Reset Section C so the demo can be rerun
DELETE FROM ORDER_ITEMS WHERE order_id = 9100001;
DELETE FROM ORDERS      WHERE order_id = 9100001;
DELETE FROM ORDER_AUDIT WHERE order_id IN (9100001, 9100002);


------------------------------------------------------------
-- SECTION D: Analytics on live operational data (no ETL, no federation)
------------------------------------------------------------
-- Talk track: "The same orders the associates just wrote are immediately available
-- to analysts, joined with years of history in a standard table, in the same engine."

-- D1. Revenue by region: live orders (hybrid) vs historical sales (standard)
WITH live AS (
    SELECT s.region, SUM(o.order_total) AS live_revenue
    FROM ORDERS o JOIN STORES s ON s.store_id = o.store_id
    WHERE o.order_status <> 'RETURNED'
    GROUP BY s.region
), hist AS (
    SELECT s.region, SUM(h.amount) AS historical_revenue
    FROM SALES_HISTORY h JOIN STORES s ON s.store_id = h.store_id
    GROUP BY s.region
)
SELECT l.region, l.live_revenue, h.historical_revenue
FROM live l JOIN hist h ON h.region = l.region
ORDER BY l.live_revenue DESC;

-- D2. Top customers by lifetime value: hybrid CUSTOMERS joined to standard SALES_HISTORY
SELECT c.customer_id, c.first_name, c.last_name, c.loyalty_tier, SUM(h.amount) AS lifetime_value
FROM SALES_HISTORY h
JOIN CUSTOMERS c ON c.customer_id = h.customer_id
GROUP BY ALL
ORDER BY lifetime_value DESC
LIMIT 10;

ALTER SESSION UNSET USE_CACHED_RESULT;
