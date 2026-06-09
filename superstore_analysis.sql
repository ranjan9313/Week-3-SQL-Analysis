-- ============================================================
-- SUPERSTORE SALES ANALYSIS
-- SQL Techniques: Subqueries, CTEs, Window Functions
-- Database: SQLite 3.45  |  Rows: 9,994 orders
-- ============================================================


-- ──────────────────────────────────────────────────────────
-- SECTION 1: SCHEMA SETUP
-- ──────────────────────────────────────────────────────────

-- Step 1: Raw staging table (loaded from CSV via pandas / .import)
-- superstore_raw contains all 21 original columns as-is.

-- Step 2: Normalized dimension tables
CREATE TABLE IF NOT EXISTS customers (
    customer_id   TEXT PRIMARY KEY,
    customer_name TEXT NOT NULL,
    segment       TEXT          -- Consumer | Corporate | Home Office
);

CREATE TABLE IF NOT EXISTS products (
    product_id   TEXT PRIMARY KEY,
    product_name TEXT NOT NULL,
    category     TEXT,          -- Furniture | Office Supplies | Technology
    sub_category TEXT
);

CREATE TABLE IF NOT EXISTS orders (
    row_id      INTEGER PRIMARY KEY,
    order_id    TEXT,
    order_date  TEXT,
    ship_date   TEXT,
    ship_mode   TEXT,
    customer_id TEXT REFERENCES customers(customer_id),
    product_id  TEXT,
    city        TEXT,
    state       TEXT,
    region      TEXT,           -- Central | East | South | West
    sales       REAL,
    quantity    INTEGER,
    discount    REAL,
    profit      REAL
);

-- Step 3: INSERT DISTINCT — populate dimension tables from raw
INSERT INTO customers (customer_id, customer_name, segment)
SELECT Customer_ID, MIN(Customer_Name), MIN(Segment)
FROM   superstore_raw
GROUP  BY Customer_ID;

INSERT INTO products (product_id, product_name, category, sub_category)
SELECT Product_ID, MIN(Product_Name), MIN(Category), MIN(Sub_Category)
FROM   superstore_raw
GROUP  BY Product_ID;

INSERT INTO orders
SELECT Row_ID, Order_ID, Order_Date, Ship_Date, Ship_Mode,
       Customer_ID, Product_ID, City, State, Region,
       Sales, Quantity, Discount, Profit
FROM   superstore_raw;


-- ──────────────────────────────────────────────────────────
-- SECTION 2: SUBQUERIES
-- ──────────────────────────────────────────────────────────

-- Q-SQ1: Orders with sales ABOVE the store-wide average
--        (avg ≈ $229.86 → 3,756 qualifying rows)
SELECT o.order_id,
       c.customer_name,
       p.category,
       ROUND(o.sales, 2) AS sales
FROM   orders o
JOIN   customers c USING(customer_id)
JOIN   products  p USING(product_id)
WHERE  o.sales > (SELECT AVG(sales) FROM orders)   -- scalar subquery
ORDER  BY o.sales DESC
LIMIT  10;

-- Q-SQ2: Each customer's single highest-value order line
--        (correlated subquery — runs once per outer row)
SELECT c.customer_name,
       o.order_id,
       ROUND(o.sales, 2) AS max_order_sales
FROM   orders o
JOIN   customers c USING(customer_id)
WHERE  o.sales = (
           SELECT MAX(o2.sales)
           FROM   orders o2
           WHERE  o2.customer_id = o.customer_id   -- correlated
       )
ORDER  BY max_order_sales DESC
LIMIT  10;


-- ──────────────────────────────────────────────────────────
-- SECTION 3: CTEs (Common Table Expressions)
-- ──────────────────────────────────────────────────────────

-- Q-CTE1: Total sales / profit / order count per customer
WITH customer_sales AS (
    SELECT   customer_id,
             ROUND(SUM(sales),  2)          AS total_sales,
             ROUND(SUM(profit), 2)          AS total_profit,
             COUNT(DISTINCT order_id)       AS num_orders,
             ROUND(AVG(sales),  2)          AS avg_order_sales
    FROM     orders
    GROUP BY customer_id
)
SELECT c.customer_name,
       c.segment,
       cs.total_sales,
       cs.num_orders,
       cs.total_profit
FROM   customer_sales cs
JOIN   customers c USING(customer_id)
ORDER  BY cs.total_sales DESC
LIMIT  10;


-- ──────────────────────────────────────────────────────────
-- SECTION 4: WINDOW FUNCTIONS
-- ──────────────────────────────────────────────────────────

-- Q-WF1: ROW_NUMBER — pick each customer's best single order
WITH ranked AS (
    SELECT order_id,
           customer_id,
           order_date,
           ROUND(sales, 2) AS sales,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER     BY sales DESC
           ) AS rn                -- 1 = top order for that customer
    FROM   orders
)
SELECT c.customer_name,
       r.order_id,
       r.order_date,
       r.sales
FROM   ranked r
JOIN   customers c USING(customer_id)
WHERE  r.rn = 1
ORDER  BY r.sales DESC
LIMIT  10;

-- Q-WF2: RANK — customers ranked by total sales globally AND within segment
WITH customer_sales AS (
    SELECT   customer_id,
             ROUND(SUM(sales), 2) AS total_sales
    FROM     orders
    GROUP BY customer_id
)
SELECT c.customer_name,
       c.segment,
       cs.total_sales,
       RANK() OVER (
           PARTITION BY c.segment
           ORDER BY cs.total_sales DESC
       ) AS segment_rank,
       RANK() OVER (
           ORDER BY cs.total_sales DESC
       ) AS overall_rank
FROM   customer_sales cs
JOIN   customers c USING(customer_id)
ORDER  BY cs.total_sales DESC
LIMIT  15;


-- ──────────────────────────────────────────────────────────
-- SECTION 5: COMBINED — JOIN + CTE + WINDOW FUNCTIONS
-- ──────────────────────────────────────────────────────────

-- Full customer performance profile with tiers
WITH sales_agg AS (
    SELECT   customer_id,
             ROUND(SUM(sales),  2) AS total_sales,
             ROUND(SUM(profit), 2) AS total_profit,
             COUNT(DISTINCT order_id)   AS num_orders,
             ROUND(AVG(sales),  2) AS avg_order_sales
    FROM     orders
    GROUP BY customer_id
),
ranked AS (
    SELECT *,
           RANK()   OVER (ORDER BY total_sales  DESC) AS sales_rank,
           RANK()   OVER (ORDER BY total_profit DESC) AS profit_rank,
           NTILE(4) OVER (ORDER BY total_sales  DESC) AS sales_quartile
    FROM   sales_agg
)
SELECT c.customer_name,
       c.segment,
       r.total_sales,
       r.total_profit,
       r.num_orders,
       r.avg_order_sales,
       r.sales_rank,
       r.profit_rank,
       CASE r.sales_quartile
           WHEN 1 THEN 'Top 25%'
           WHEN 2 THEN 'Upper-Mid'
           WHEN 3 THEN 'Lower-Mid'
           WHEN 4 THEN 'Bottom 25%'
       END AS customer_tier
FROM   ranked r
JOIN   customers c USING(customer_id)
ORDER  BY r.sales_rank
LIMIT  10;


-- ──────────────────────────────────────────────────────────
-- SECTION 6: BUSINESS QUERIES
-- ──────────────────────────────────────────────────────────

-- BQ1: Top 5 customers by lifetime sales
WITH cs AS (
    SELECT customer_id,
           ROUND(SUM(sales),  2) AS total_sales,
           ROUND(SUM(profit), 2) AS total_profit
    FROM   orders
    GROUP  BY customer_id
)
SELECT ROW_NUMBER() OVER (ORDER BY cs.total_sales DESC) AS rank,
       c.customer_name,
       c.segment,
       cs.total_sales,
       cs.total_profit
FROM   cs
JOIN   customers c USING(customer_id)
ORDER  BY cs.total_sales DESC
LIMIT  5;

-- BQ2: Bottom 5 customers by lifetime sales (churn / re-engagement targets)
WITH cs AS (
    SELECT customer_id,
           ROUND(SUM(sales),  2) AS total_sales,
           ROUND(SUM(profit), 2) AS total_profit
    FROM   orders
    GROUP  BY customer_id
)
SELECT c.customer_name,
       c.segment,
       cs.total_sales,
       cs.total_profit
FROM   cs
JOIN   customers c USING(customer_id)
ORDER  BY cs.total_sales ASC
LIMIT  5;

-- BQ3: Customers who placed exactly ONE order (retention opportunity)
WITH order_counts AS (
    SELECT customer_id,
           COUNT(DISTINCT order_id) AS num_orders
    FROM   orders
    GROUP  BY customer_id
)
SELECT c.customer_name,
       c.segment,
       oc.num_orders
FROM   order_counts oc
JOIN   customers c USING(customer_id)
WHERE  oc.num_orders = 1
ORDER  BY c.customer_name;

-- BQ4: Sub-category performance vs store-wide average sales
WITH cat_sales AS (
    SELECT p.category,
           p.sub_category,
           ROUND(SUM(o.sales),  2) AS total_sales,
           ROUND(AVG(o.sales),  2) AS avg_sales,
           ROUND(SUM(o.profit), 2) AS total_profit
    FROM   orders o
    JOIN   products p USING(product_id)
    GROUP  BY p.category, p.sub_category
)
SELECT category,
       sub_category,
       total_sales,
       avg_sales,
       total_profit,
       CASE WHEN avg_sales > (SELECT AVG(sales) FROM orders)
            THEN 'Above Avg'
            ELSE 'Below Avg'
       END AS vs_store_avg
FROM   cat_sales
ORDER  BY total_sales DESC;

-- ── END OF SCRIPT ─────────────────────────────────────────
