-- 02_create_and_load.sql
-- Creates the hybrid (operational) and standard (analytical) tables and loads synthetic retail data.
-- Tables without foreign keys are bulk loaded with CTAS (CREATE HYBRID TABLE ... AS SELECT).
-- CTAS does not allow FOREIGN KEY definitions on hybrid tables, so tables with FKs are created empty
-- and loaded with INSERT INTO ... SELECT (bulk-load path, since the table is empty).
-- CHECK constraints must be defined at creation time; COPY INTO is not allowed on tables with CHECKs.

USE WAREHOUSE HT_DEMO_WH;
USE SCHEMA DEMO.HYBRID_RETAIL;
-- Expect about 10-15 minutes on XSMALL (the 4M-row ORDER_ITEMS insert is the long one).
-- If you run this with the Snowflake CLI and it exits early, the INSERT keeps running in
-- Snowflake; check QUERY_HISTORY and run the remaining statements once it succeeds.

-- Drop children before parents so the script is safely re-runnable (FKs block dropping a referenced parent).
DROP TABLE IF EXISTS ORDER_ITEMS;
DROP TABLE IF EXISTS ORDERS;
DROP TABLE IF EXISTS CUSTOMERS;
DROP TABLE IF EXISTS PRODUCTS;
DROP TABLE IF EXISTS STORES;

------------------------------------------------------------
-- Hybrid tables
------------------------------------------------------------

CREATE OR REPLACE HYBRID TABLE STORES (
    store_id    INT PRIMARY KEY,
    store_name  VARCHAR(100) NOT NULL,
    region      VARCHAR(20)  NOT NULL
) AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4())                                   AS store_id,
    'Store #' || LPAD(ROW_NUMBER() OVER (ORDER BY SEQ4()), 4, '0')        AS store_name,
    ARRAY_CONSTRUCT('NORTHEAST','SOUTHEAST','MIDWEST','SOUTHWEST','WEST')[UNIFORM(0, 4, RANDOM())]::VARCHAR AS region
FROM TABLE(GENERATOR(ROWCOUNT => 500));

CREATE OR REPLACE HYBRID TABLE PRODUCTS (
    product_id    INT PRIMARY KEY,
    sku           VARCHAR(20)  NOT NULL UNIQUE,
    product_name  VARCHAR(100) NOT NULL,
    category      VARCHAR(30)  NOT NULL,
    price         NUMBER(10,2) NOT NULL,
    CONSTRAINT chk_price_positive CHECK (price > 0)
) AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4())                                   AS product_id,
    'SKU-' || LPAD(ROW_NUMBER() OVER (ORDER BY SEQ4()), 6, '0')           AS sku,
    'Product ' || ROW_NUMBER() OVER (ORDER BY SEQ4())                     AS product_name,
    ARRAY_CONSTRUCT('APPAREL','FOOTWEAR','HOME','ELECTRONICS','GROCERY','BEAUTY','TOYS')[UNIFORM(0, 6, RANDOM())]::VARCHAR AS category,
    ROUND(UNIFORM(199, 49999, RANDOM()) / 100, 2)                         AS price
FROM TABLE(GENERATOR(ROWCOUNT => 10000));

CREATE OR REPLACE HYBRID TABLE CUSTOMERS (
    customer_id   INT PRIMARY KEY,
    email         VARCHAR(100) NOT NULL UNIQUE,
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    loyalty_tier  VARCHAR(10)  NOT NULL,
    home_store_id INT,
    created_at    TIMESTAMP_NTZ NOT NULL,
    CONSTRAINT fk_customer_store FOREIGN KEY (home_store_id) REFERENCES STORES (store_id)
);

INSERT INTO CUSTOMERS
SELECT
    id                                                                    AS customer_id,
    'customer' || id || '@example.com'                                    AS email,
    ARRAY_CONSTRUCT('Ava','Liam','Mia','Noah','Emma','Lucas','Sofia','Ethan','Zoe','Mason')[UNIFORM(0, 9, RANDOM())]::VARCHAR AS first_name,
    ARRAY_CONSTRUCT('Smith','Garcia','Chen','Patel','Johnson','Kim','Lopez','Nguyen','Brown','Davis')[UNIFORM(0, 9, RANDOM())]::VARCHAR AS last_name,
    ARRAY_CONSTRUCT('BRONZE','BRONZE','BRONZE','SILVER','SILVER','GOLD')[UNIFORM(0, 5, RANDOM())]::VARCHAR AS loyalty_tier,
    UNIFORM(1, 500, RANDOM())                                             AS home_store_id,
    DATEADD('day', -UNIFORM(0, 1825, RANDOM()), '2026-11-01'::TIMESTAMP_NTZ) AS created_at
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id FROM TABLE(GENERATOR(ROWCOUNT => 1000000)));

CREATE OR REPLACE HYBRID TABLE ORDERS (
    order_id      INT PRIMARY KEY,
    customer_id   INT NOT NULL,
    store_id      INT NOT NULL,
    order_status  VARCHAR(20) NOT NULL,
    order_ts      TIMESTAMP_NTZ NOT NULL,
    order_total   NUMBER(12,2),
    CONSTRAINT fk_order_customer FOREIGN KEY (customer_id) REFERENCES CUSTOMERS (customer_id),
    CONSTRAINT fk_order_store    FOREIGN KEY (store_id)    REFERENCES STORES (store_id),
    INDEX idx_orders_ts (order_ts)
);

INSERT INTO ORDERS
SELECT
    id                                                                    AS order_id,
    UNIFORM(1, 1000000, RANDOM())                                         AS customer_id,
    UNIFORM(1, 500, RANDOM())                                             AS store_id,
    ARRAY_CONSTRUCT('COMPLETED','COMPLETED','COMPLETED','SHIPPED','PLACED','RETURNED')[UNIFORM(0, 5, RANDOM())]::VARCHAR AS order_status,
    DATEADD('minute', -UNIFORM(0, 525600, RANDOM()), '2026-11-01'::TIMESTAMP_NTZ) AS order_ts,
    ROUND(UNIFORM(500, 50000, RANDOM()) / 100, 2)                         AS order_total
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id FROM TABLE(GENERATOR(ROWCOUNT => 2000000)));

CREATE OR REPLACE HYBRID TABLE ORDER_ITEMS (
    order_id    INT NOT NULL,
    line_no     INT NOT NULL,
    product_id  INT NOT NULL,
    quantity    INT NOT NULL,
    unit_price  NUMBER(10,2) NOT NULL,
    PRIMARY KEY (order_id, line_no),
    CONSTRAINT fk_item_order   FOREIGN KEY (order_id)   REFERENCES ORDERS (order_id),
    CONSTRAINT fk_item_product FOREIGN KEY (product_id) REFERENCES PRODUCTS (product_id),
    CONSTRAINT chk_qty_positive CHECK (quantity > 0)
);

INSERT INTO ORDER_ITEMS
SELECT
    o.order_id,
    l.line_no,
    UNIFORM(1, 10000, RANDOM())                                           AS product_id,
    UNIFORM(1, 4, RANDOM())                                               AS quantity,
    ROUND(UNIFORM(199, 49999, RANDOM()) / 100, 2)                         AS unit_price
FROM ORDERS o
JOIN (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS line_no FROM TABLE(GENERATOR(ROWCOUNT => 3))) l
  ON l.line_no <= 1 + MOD(o.order_id, 3);

------------------------------------------------------------
-- Standard tables
------------------------------------------------------------

-- Same customer data in a standard table, for the side-by-side lookup comparison.
CREATE OR REPLACE TABLE CUSTOMERS_STD AS SELECT * FROM CUSTOMERS;

-- Historical sales for analytics (bulk loaded, scanned, aggregated: a standard-table workload).
CREATE OR REPLACE TABLE SALES_HISTORY AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4())                                   AS sale_id,
    UNIFORM(1, 1000000, RANDOM())                                         AS customer_id,
    UNIFORM(1, 500, RANDOM())                                             AS store_id,
    UNIFORM(1, 10000, RANDOM())                                           AS product_id,
    DATEADD('day', -UNIFORM(365, 1825, RANDOM()), '2026-11-01'::DATE)     AS sale_date,
    UNIFORM(1, 4, RANDOM())                                               AS quantity,
    ROUND(UNIFORM(199, 49999, RANDOM()) / 100, 2)                         AS amount
FROM TABLE(GENERATOR(ROWCOUNT => 20000000));

-- Audit trail written in the same transaction as hybrid order changes.
CREATE OR REPLACE TABLE ORDER_AUDIT (
    audit_id     INT AUTOINCREMENT,
    order_id     INT,
    action       VARCHAR(20),
    detail       VARCHAR(200),
    audit_ts     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
);

-- Order ids for new orders placed from the app (avoids a MAX(order_id) scan).
CREATE OR REPLACE SEQUENCE ORDER_ID_SEQ START = 3000000 INCREMENT = 1;

-- Quick sanity check
SELECT 'STORES' t, COUNT(*) n FROM STORES UNION ALL
SELECT 'PRODUCTS', COUNT(*) FROM PRODUCTS UNION ALL
SELECT 'CUSTOMERS', COUNT(*) FROM CUSTOMERS UNION ALL
SELECT 'ORDERS', COUNT(*) FROM ORDERS UNION ALL
SELECT 'ORDER_ITEMS', COUNT(*) FROM ORDER_ITEMS UNION ALL
SELECT 'CUSTOMERS_STD', COUNT(*) FROM CUSTOMERS_STD UNION ALL
SELECT 'SALES_HISTORY', COUNT(*) FROM SALES_HISTORY;
