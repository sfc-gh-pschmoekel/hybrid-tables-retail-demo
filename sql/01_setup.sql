-- 01_setup.sql
-- Creates the demo schema and a dedicated warehouse for the operational (app) queries.
-- Hybrid tables cannot live in a transient database or schema, so DEMO must be a standard database.

CREATE DATABASE IF NOT EXISTS DEMO;
CREATE SCHEMA IF NOT EXISTS DEMO.HYBRID_RETAIL;

-- Why a separate warehouse:
--   ENABLE_USE_STABLE_PATH turns on Snowflake's optimized path for "operational queries"
--   (repeated, short, parameterized statements that touch only hybrid tables). It is a
--   warehouse-level setting and currently in public preview, so we keep it on its own
--   warehouse instead of changing a shared one. This mirrors a real deployment: one
--   warehouse serves the app, another serves analytics.
--   Docs: https://docs.snowflake.com/en/user-guide/hybrid-tables-operational-query-performance
CREATE WAREHOUSE IF NOT EXISTS HT_DEMO_WH
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  ENABLE_USE_STABLE_PATH = TRUE
  COMMENT = 'Hybrid tables demo: operational queries with the optimized path (public preview)';

USE WAREHOUSE HT_DEMO_WH;
USE SCHEMA DEMO.HYBRID_RETAIL;
