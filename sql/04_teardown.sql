-- 04_teardown.sql
-- Removes everything this demo created. The DEMO database itself is NOT dropped.

DROP STREAMLIT IF EXISTS DEMO.HYBRID_RETAIL.HYBRID_RETAIL_APP;
DROP SCHEMA IF EXISTS DEMO.HYBRID_RETAIL CASCADE;
DROP WAREHOUSE IF EXISTS HT_DEMO_WH;

-- Note: UNDROP does not restore hybrid tables, so this is permanent.
