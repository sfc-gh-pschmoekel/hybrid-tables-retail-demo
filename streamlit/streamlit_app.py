import time

import pandas as pd
import streamlit as st
from snowflake.snowpark.exceptions import SnowparkSQLException

st.set_page_config(page_title="Retail Associate App (Hybrid Tables)", layout="wide")

SCHEMA = "DEMO.HYBRID_RETAIL"


@st.cache_resource
def get_session():
    session = st.connection("snowflake").session()
    session.sql(f"USE SCHEMA {SCHEMA}").collect()
    # Hybrid tables never use the results cache; disable it so the standard comparison is fair.
    session.sql("ALTER SESSION SET USE_CACHED_RESULT = FALSE").collect()
    return session


session = get_session()


def timed_query(sql: str, params: list | None = None) -> tuple[pd.DataFrame, float]:
    start = time.perf_counter()
    df = session.sql(sql, params=params).to_pandas()
    return df, (time.perf_counter() - start) * 1000


def run_dml(sql: str, params: list | None = None) -> tuple[bool, str]:
    try:
        session.sql(sql, params=params).collect()
        return True, "Accepted"
    except SnowparkSQLException as e:
        return False, e.message


st.title("Retail Associate App")
st.caption("Powered by Snowflake hybrid tables: fast point lookups and enforced data integrity, next to your analytics.")

lookup_tab, order_tab, integrity_tab, analytics_tab = st.tabs(
    ["Customer Lookup", "Place Order", "Integrity Check", "Analytics"]
)

# ---------------------------------------------------------------- Customer Lookup
with lookup_tab:
    st.subheader("Look up a customer")
    col_mode, col_value = st.columns([1, 3])
    mode = col_mode.radio("Search by", ["Customer ID", "Email"], horizontal=False)
    default_value = "424242" if mode == "Customer ID" else "customer777777@example.com"
    value = col_value.text_input("Value", value=default_value)

    if st.button("Look up", type="primary"):
        if mode == "Customer ID":
            if not value.strip().isdigit():
                st.error("Customer ID must be a number.")
                st.stop()
            where, param = "customer_id = ?", int(value)
        else:
            where, param = "email = ?", value.strip()

        hybrid_df, hybrid_ms = timed_query(f"SELECT * FROM CUSTOMERS WHERE {where}", [param])
        std_df, std_ms = timed_query(f"SELECT * FROM CUSTOMERS_STD WHERE {where}", [param])

        m1, m2, m3 = st.columns(3)
        m1.metric("Hybrid table", f"{hybrid_ms:,.0f} ms")
        m2.metric("Standard table", f"{std_ms:,.0f} ms")
        m3.metric("Speedup", f"{std_ms / hybrid_ms:,.1f}x" if hybrid_ms else "n/a")
        st.caption("Round-trip time measured in the app. Server-side timings are in QUERY_HISTORY (see worksheet Section A).")

        if hybrid_df.empty:
            st.warning("No customer found.")
        else:
            st.markdown("**Customer profile**")
            st.dataframe(hybrid_df, hide_index=True, width="stretch")
            orders_df, orders_ms = timed_query(
                """SELECT order_id, order_ts, order_status, store_id, order_total
                   FROM ORDERS WHERE customer_id = ? ORDER BY order_ts DESC LIMIT 10""",
                [int(hybrid_df["CUSTOMER_ID"].iloc[0])],
            )
            st.markdown(f"**Recent orders** ({orders_ms:,.0f} ms)")
            st.dataframe(orders_df, hide_index=True, width="stretch")

# ---------------------------------------------------------------- Place Order
with order_tab:
    st.subheader("Place an order")
    st.caption("Writes the order and its line to hybrid tables and an audit row to a standard table, in one transaction.")
    with st.form("order_form"):
        c1, c2, c3 = st.columns(3)
        customer_id = c1.number_input("Customer ID", min_value=0, value=424242, step=1)
        store_id = c2.number_input("Store ID", min_value=0, value=17, step=1)
        product_id = c3.number_input("Product ID", min_value=0, value=1234, step=1)
        c4, c5 = st.columns(2)
        quantity = c4.number_input("Quantity", value=2, step=1)
        unit_price = c5.number_input("Unit price", value=19.99, step=1.0, format="%.2f")
        submitted = st.form_submit_button("Place order", type="primary")

    if submitted:
        new_id = int(session.sql("SELECT ORDER_ID_SEQ.NEXTVAL AS ID").collect()[0]["ID"])
        steps = []

        def step(label: str, table_type: str, sql: str, params: list | None = None) -> None:
            t = time.perf_counter()
            session.sql(sql, params=params).collect()
            steps.append({"Step": label, "Table type": table_type, "ms": round((time.perf_counter() - t) * 1000)})

        try:
            session.sql("BEGIN TRANSACTION").collect()
            step(
                "Insert order", "Hybrid",
                """INSERT INTO ORDERS (order_id, customer_id, store_id, order_status, order_ts, order_total)
                   VALUES (?, ?, ?, 'PLACED', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, ?)""",
                [new_id, int(customer_id), int(store_id), round(quantity * unit_price, 2)],
            )
            step(
                "Insert order line", "Hybrid",
                "INSERT INTO ORDER_ITEMS (order_id, line_no, product_id, quantity, unit_price) VALUES (?, 1, ?, ?, ?)",
                [new_id, int(product_id), int(quantity), float(unit_price)],
            )
            step(
                "Insert audit row", "Standard",
                "INSERT INTO ORDER_AUDIT (order_id, action, detail) VALUES (?, 'PLACED', 'Placed from associate app')",
                [new_id],
            )
            step("Commit", "Both", "COMMIT")
            st.success(f"Order {new_id} placed in {sum(s['ms'] for s in steps):,} ms (one atomic transaction).")
            st.dataframe(pd.DataFrame(steps), hide_index=True, width="stretch")
            st.caption(
                "Hybrid row inserts are fast. The standard-table audit write and the commit cost more because "
                "standard tables write micro-partitions. Drop the audit step and the order path is hybrid only."
            )
        except SnowparkSQLException as e:
            session.sql("ROLLBACK").collect()
            st.error("Order rejected and rolled back. Nothing was written, including the audit row.")
            st.code(e.message)

# ---------------------------------------------------------------- Integrity Check
with integrity_tab:
    st.subheader("Try to insert bad data")
    st.caption("Hybrid tables enforce PRIMARY KEY, UNIQUE, FOREIGN KEY, and CHECK constraints. Each test below should be rejected.")

    tests = {
        "Duplicate customer ID (PRIMARY KEY)": (
            """INSERT INTO CUSTOMERS (customer_id, email, first_name, last_name, loyalty_tier, home_store_id, created_at)
               VALUES (1, 'brand.new@example.com', 'Dup', 'Key', 'GOLD', 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)""",
        ),
        "Duplicate email (UNIQUE)": (
            """INSERT INTO CUSTOMERS (customer_id, email, first_name, last_name, loyalty_tier, home_store_id, created_at)
               VALUES (2000001, 'customer1@example.com', 'Dup', 'Email', 'GOLD', 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)""",
        ),
        "Order for a customer that does not exist (FOREIGN KEY)": (
            """INSERT INTO ORDERS (order_id, customer_id, store_id, order_status, order_ts, order_total)
               VALUES (9000001, 99999999, 1, 'PLACED', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 25.00)""",
        ),
        "Order line for a product that does not exist (FOREIGN KEY)": (
            "INSERT INTO ORDER_ITEMS (order_id, line_no, product_id, quantity, unit_price) VALUES (1, 99, 99999999, 1, 9.99)",
        ),
        "Negative quantity (CHECK)": (
            "INSERT INTO ORDER_ITEMS (order_id, line_no, product_id, quantity, unit_price) VALUES (1, 99, 1, -5, 9.99)",
        ),
        "Delete a customer who has orders (FOREIGN KEY)": (
            "DELETE FROM CUSTOMERS WHERE customer_id = (SELECT customer_id FROM ORDERS WHERE order_id = 1)",
        ),
    }

    if st.button("Run all integrity tests", type="primary"):
        rows = []
        for name, (sql,) in tests.items():
            ok, msg = run_dml(sql)
            rows.append({"Test": name, "Result": "ACCEPTED (unexpected)" if ok else "REJECTED", "Snowflake message": msg})
        st.dataframe(pd.DataFrame(rows), hide_index=True, width="stretch")

    st.divider()
    st.markdown("**Contrast: a standard table with the same declared key**")
    if st.button("Insert a duplicate into CUSTOMERS_STD"):
        ok, msg = run_dml(
            """INSERT INTO CUSTOMERS_STD (customer_id, email, first_name, last_name, loyalty_tier, home_store_id, created_at)
               VALUES (1, 'customer1@example.com', 'Dup', 'Key', 'GOLD', 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)"""
        )
        dup_df = session.sql(
            "SELECT customer_id, email, first_name, last_name FROM CUSTOMERS_STD WHERE customer_id = 1"
        ).to_pandas()
        st.warning(f"Standard table accepted the duplicate. Rows with customer_id = 1: {len(dup_df)}")
        st.dataframe(dup_df, hide_index=True, width="stretch")
        run_dml("DELETE FROM CUSTOMERS_STD WHERE customer_id = 1 AND first_name = 'Dup'")
        st.caption("Duplicate removed again so the demo can be rerun.")

# ---------------------------------------------------------------- Analytics
with analytics_tab:
    st.subheader("Live orders next to historical sales")
    st.caption("Hybrid ORDERS joined with standard SALES_HISTORY in the same engine. No ETL, no second database.")
    df, ms = timed_query(
        """WITH live AS (
               SELECT s.region, SUM(o.order_total) AS live_revenue
               FROM ORDERS o JOIN STORES s ON s.store_id = o.store_id
               WHERE o.order_status <> 'RETURNED'
               GROUP BY s.region
           ), hist AS (
               SELECT s.region, SUM(h.amount) AS historical_revenue
               FROM SALES_HISTORY h JOIN STORES s ON s.store_id = h.store_id
               GROUP BY s.region
           )
           SELECT l.region AS REGION, l.live_revenue AS LIVE_REVENUE, h.historical_revenue AS HISTORICAL_REVENUE
           FROM live l JOIN hist h ON h.region = l.region
           ORDER BY l.live_revenue DESC"""
    )
    c1, c2 = st.columns(2)
    c1.markdown("**Live revenue by region (hybrid)**")
    c1.bar_chart(df, x="REGION", y="LIVE_REVENUE")
    c2.markdown("**Historical revenue by region (standard)**")
    c2.bar_chart(df, x="REGION", y="HISTORICAL_REVENUE")
    st.caption(f"Query time: {ms:,.0f} ms")

    audit_df = session.sql("SELECT * FROM ORDER_AUDIT ORDER BY audit_ts DESC LIMIT 10").to_pandas()
    st.markdown("**Latest audit entries (standard table, written in the same transaction as orders)**")
    st.dataframe(audit_df, hide_index=True, width="stretch")
