-- =============================================================
-- 00_schema.sql
-- E-Commerce 분석 실습 (종합실습 4) — 스키마 정의
-- 작성자 : 신주용 / 광주 3반
-- 작성일 : 2026-07-21
-- 변경 이력 :
--   2026-07-21 최초 작성
-- =============================================================
-- 접속 대상 : psql -d postgres -f 00_schema.sql
-- 실행 순서 : 00_schema.sql → 01_seed.sql → 02_queries.sql → 03_explain_mview.sql
-- =============================================================

\c postgres

-- 기존 DB 삭제 후 재생성 (멱등성 보장)
DROP DATABASE IF EXISTS ecom_db;
CREATE DATABASE ecom_db
    ENCODING    'UTF8'
    LC_COLLATE  'C'
    LC_CTYPE    'C'
    TEMPLATE    template0;

\c ecom_db

-- =============================================================
-- 1. 카테고리 트리 (재귀 CTE 대상)
--    parent_id NULL = 최상위 대분류
-- =============================================================
CREATE TABLE categories (
    category_id   SERIAL PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    parent_id     INT          REFERENCES categories(category_id)
);

-- =============================================================
-- 2. 상품 마스터
-- =============================================================
CREATE TABLE products (
    product_id    SERIAL       PRIMARY KEY,
    name          VARCHAR(200) NOT NULL,
    category_id   INT          NOT NULL REFERENCES categories(category_id),
    base_price    NUMERIC(12,2) NOT NULL CHECK (base_price > 0)
);

-- =============================================================
-- 3. 가격 이력 SCD Type-2
--    valid_to IS NULL = 현재 유효 가격
-- =============================================================
CREATE TABLE product_prices (
    price_id      SERIAL       PRIMARY KEY,
    product_id    INT          NOT NULL REFERENCES products(product_id),
    price         NUMERIC(12,2) NOT NULL CHECK (price > 0),
    valid_from    DATE         NOT NULL,
    valid_to      DATE         -- NULL = 현재 적용 중
);

-- =============================================================
-- 4. 재고 (재주문 시점 포함)
-- =============================================================
CREATE TABLE inventory (
    product_id     INT          PRIMARY KEY REFERENCES products(product_id),
    stock          INT          NOT NULL DEFAULT 0 CHECK (stock >= 0),
    reorder_point  INT          NOT NULL DEFAULT 50 CHECK (reorder_point >= 0)
);

-- =============================================================
-- 5. 고객
-- =============================================================
CREATE TABLE customers (
    customer_id    SERIAL       PRIMARY KEY,
    name           VARCHAR(100) NOT NULL,
    email          VARCHAR(200) NOT NULL UNIQUE,
    channel        VARCHAR(20)  NOT NULL CHECK (channel IN ('web','mobile','marketplace')),
    signup_date    DATE         NOT NULL
);

-- =============================================================
-- 6. 쿠폰
-- =============================================================
CREATE TABLE coupons (
    code           VARCHAR(50)  PRIMARY KEY,
    discount_rate  NUMERIC(5,2) NOT NULL CHECK (discount_rate BETWEEN 0 AND 100),
    valid_from     DATE         NOT NULL,
    valid_to       DATE         NOT NULL
);

-- =============================================================
-- 7. 주문 헤더
--    channel : 주문 채널 (web / mobile / marketplace)
--    status  : created → paid → shipped → delivered / cancelled / refunded
--    coupon_code : 쿠폰 미사용 시 NULL
-- =============================================================
CREATE TABLE orders (
    order_id       SERIAL       PRIMARY KEY,
    customer_id    INT          NOT NULL REFERENCES customers(customer_id),
    channel        VARCHAR(20)  NOT NULL CHECK (channel IN ('web','mobile','marketplace')),
    status         VARCHAR(20)  NOT NULL CHECK (status IN ('created','paid','shipped','delivered','cancelled','refunded')),
    order_date     TIMESTAMPTZ  NOT NULL,
    coupon_code    VARCHAR(50)  REFERENCES coupons(code)
);

-- =============================================================
-- 8. 주문 상세 (라인 아이템)
--    unit_price : 실제 결제 시 적용 가격 (SCD2 이력 반영)
-- =============================================================
CREATE TABLE order_items (
    item_id        SERIAL       PRIMARY KEY,
    order_id       INT          NOT NULL REFERENCES orders(order_id),
    product_id     INT          NOT NULL REFERENCES products(product_id),
    qty            INT          NOT NULL CHECK (qty > 0),
    unit_price     NUMERIC(12,2) NOT NULL CHECK (unit_price > 0)
);

-- =============================================================
-- 9. 리뷰 (별점 1~5)
-- =============================================================
CREATE TABLE reviews (
    review_id      SERIAL       PRIMARY KEY,
    product_id     INT          NOT NULL REFERENCES products(product_id),
    customer_id    INT          NOT NULL REFERENCES customers(customer_id),
    rating         SMALLINT     NOT NULL CHECK (rating BETWEEN 1 AND 5),
    review_date    DATE         NOT NULL,
    content        TEXT
);

-- =============================================================
-- 쿼리 가속용 인덱스 (기본)
-- =============================================================
CREATE INDEX idx_orders_customer   ON orders(customer_id);
CREATE INDEX idx_orders_date       ON orders(order_date);
CREATE INDEX idx_orders_status     ON orders(status);
CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_prod  ON order_items(product_id);
CREATE INDEX idx_product_prices_pid ON product_prices(product_id, valid_from, valid_to);
CREATE INDEX idx_reviews_product   ON reviews(product_id);
CREATE INDEX idx_inventory_stock   ON inventory(stock, reorder_point);
