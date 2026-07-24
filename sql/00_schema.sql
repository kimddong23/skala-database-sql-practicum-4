-- =============================================================
-- 00_schema.sql
-- E-Commerce 분석 실습 (종합실습 4) — ecom 스키마 · 테이블 14종
-- 작성자 : 신주용 / 광주 3반
-- 변경 이력 :
--   - 2026-07-21 최초 작성
--   - 2026-07-24 실습 제공 스키마(ecom) 기준 전면 재구성
-- =============================================================
-- 접속 대상 : psql -d postgres -f 00_schema.sql
-- 실행 순서 : 00_schema.sql → 01_seed.sql → 02_queries.sql → 03_explain_mview.sql
-- 구성 : 차원(country·customers·addresses·categories·products·product_prices
--        ·suppliers·product_suppliers·inventory)
--        + 팩트(orders·order_items·payments·shipments·reviews)
--        + Materialized View · UDF · View
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

-- 확장 : CITEXT(대소문자 무시 이메일) · btree_gist(EXCLUDE 제약용)
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ecom 스키마 생성 + 기본 검색 경로 고정
CREATE SCHEMA ecom;
ALTER DATABASE ecom_db SET search_path TO ecom, public;
SET search_path = ecom, public;

-- =============================================================
-- 1. 차원(마스터) 테이블
-- =============================================================

-- 국가 코드 마스터
CREATE TABLE country (
    country_code CHAR(2) PRIMARY KEY,
    country_name TEXT    NOT NULL
);

-- 고객 : 이메일은 CITEXT 로 대소문자 구분 없이 UNIQUE
CREATE TABLE customers (
    customer_id      BIGSERIAL   PRIMARY KEY,
    email            CITEXT      UNIQUE NOT NULL,
    full_name        TEXT        NOT NULL,
    phone            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    marketing_opt_in BOOLEAN     NOT NULL DEFAULT false,
    country_code     CHAR(2)     REFERENCES country(country_code)
);
CREATE INDEX idx_customers_created_at ON customers(created_at);
CREATE INDEX idx_customers_country    ON customers(country_code);

-- 배송지 : 고객 1명당 N개 · 기본 배송지 플래그
CREATE TABLE addresses (
    address_id   BIGSERIAL   PRIMARY KEY,
    customer_id  BIGINT      NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    line1        TEXT        NOT NULL,
    line2        TEXT,
    city         TEXT        NOT NULL,
    state        TEXT,
    postal_code  TEXT,
    country_code CHAR(2)     NOT NULL REFERENCES country(country_code),
    is_default   BOOLEAN     NOT NULL DEFAULT false,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_addresses_customer ON addresses(customer_id);

-- 카테고리 : parent_id 자기참조 계층 (대분류 → 소분류)
CREATE TABLE categories (
    category_id   BIGSERIAL PRIMARY KEY,
    parent_id     BIGINT    REFERENCES categories(category_id) ON DELETE SET NULL,
    category_name TEXT      NOT NULL
);
CREATE INDEX idx_categories_parent ON categories(parent_id);

-- 상품 : SKU 유일 · 활성 플래그
CREATE TABLE products (
    product_id   BIGSERIAL   PRIMARY KEY,
    sku          TEXT        UNIQUE NOT NULL,
    product_name TEXT        NOT NULL,
    category_id  BIGINT      REFERENCES categories(category_id),
    unit         TEXT        NOT NULL DEFAULT 'each',
    active       BOOLEAN     NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_products_category ON products(category_id);
CREATE INDEX idx_products_active   ON products(active);

-- 가격 이력(SCD2) : 기간 창 + 같은 상품 기간 겹침 금지(EXCLUDE gist)
CREATE TABLE product_prices (
    price_id   BIGSERIAL     PRIMARY KEY,
    product_id BIGINT        NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    price      NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    currency   CHAR(3)       NOT NULL DEFAULT 'USD',
    valid_from TIMESTAMPTZ   NOT NULL,
    valid_to   TIMESTAMPTZ   NOT NULL,
    is_current BOOLEAN       NOT NULL DEFAULT true,
    CHECK (valid_from < valid_to),               -- 기간 뒤집힘 방지
    EXCLUDE USING gist (                         -- 겹침 금지 · '[)' = 맞닿음 허용
        product_id WITH =,
        tstzrange(valid_from, valid_to, '[)') WITH &&
    )
);

-- "현재 가격"은 상품당 1개만 허용 (부분 유니크 인덱스)
CREATE UNIQUE INDEX ux_product_prices_current
    ON product_prices(product_id) WHERE is_current;

-- 공급사 + 상품·공급사 N:M 교차 테이블
CREATE TABLE suppliers (
    supplier_id   BIGSERIAL PRIMARY KEY,
    supplier_name TEXT      NOT NULL,
    phone         TEXT
);

CREATE TABLE product_suppliers (
    product_id       BIGINT  NOT NULL REFERENCES products(product_id)   ON DELETE CASCADE,
    supplier_id      BIGINT  NOT NULL REFERENCES suppliers(supplier_id) ON DELETE CASCADE,
    primary_supplier BOOLEAN NOT NULL DEFAULT false,
    PRIMARY KEY (product_id, supplier_id)
);

-- 재고 : 상품과 1:1 (product_id 가 PK 이자 FK)
CREATE TABLE inventory (
    product_id    BIGINT      PRIMARY KEY REFERENCES products(product_id) ON DELETE CASCADE,
    qty_on_hand   INT         NOT NULL DEFAULT 0  CHECK (qty_on_hand >= 0),
    reorder_point INT         NOT NULL DEFAULT 10 CHECK (reorder_point >= 0),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================
-- 2. 팩트 테이블
-- =============================================================

-- 주문 : 상태 도메인 CHECK · 고객별 최근 주문 조회용 복합 인덱스
CREATE TABLE orders (
    order_id            BIGSERIAL   PRIMARY KEY,
    customer_id         BIGINT      NOT NULL REFERENCES customers(customer_id),
    order_status        TEXT        NOT NULL CHECK (order_status IN
                          ('created','paid','shipped','delivered','cancelled','refunded')),
    order_ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
    shipping_address_id BIGINT      REFERENCES addresses(address_id),
    coupon_code         TEXT,
    channel             TEXT        NOT NULL DEFAULT 'web'   -- web · mobile · marketplace
);
CREATE INDEX idx_orders_customer_ts ON orders(customer_id, order_ts DESC);
CREATE INDEX idx_orders_status      ON orders(order_status);

-- 주문 상세 : line_total 은 생성 컬럼(GENERATED)으로 자동 계산
CREATE TABLE order_items (
    order_item_id BIGSERIAL     PRIMARY KEY,
    order_id      BIGINT        NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id    BIGINT        NOT NULL REFERENCES products(product_id),
    qty           INT           NOT NULL CHECK (qty > 0),
    unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
    discount      NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
    CHECK (discount <= unit_price * qty),        -- 할인 과다로 라인합계 음수 방지
    line_total    NUMERIC(12,2) GENERATED ALWAYS AS ((unit_price * qty) - discount) STORED
);
CREATE INDEX idx_order_items_order   ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);

-- 결제 : 수단 도메인 CHECK
CREATE TABLE payments (
    payment_id BIGSERIAL     PRIMARY KEY,
    order_id   BIGINT        NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    method     TEXT          NOT NULL CHECK (method IN ('card','bank','paypal','cod')),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    paid_at    TIMESTAMPTZ
);
CREATE INDEX idx_payments_order ON payments(order_id);

-- 배송
CREATE TABLE shipments (
    shipment_id  BIGSERIAL   PRIMARY KEY,
    order_id     BIGINT      NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    carrier      TEXT        NOT NULL,
    tracking_no  TEXT,
    shipped_at   TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ
);
CREATE INDEX idx_shipments_order ON shipments(order_id);

-- 리뷰 : (상품, 고객) 조합 1회 제한
CREATE TABLE reviews (
    review_id   BIGSERIAL   PRIMARY KEY,
    product_id  BIGINT      NOT NULL REFERENCES products(product_id)   ON DELETE CASCADE,
    customer_id BIGINT      NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    rating      INT         NOT NULL CHECK (rating BETWEEN 1 AND 5),
    review_text TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(product_id, customer_id)
);

-- =============================================================
-- 3. Materialized View · UDF · View
-- =============================================================

-- 일 단위 GMV 집계 MView (자동 갱신 없음 → 시드 적재 후 REFRESH 필요)
CREATE MATERIALIZED VIEW mv_daily_gmv AS
SELECT date_trunc('day', o.order_ts) AS day,
       sum(oi.line_total)            AS gmv
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
GROUP  BY 1;
CREATE INDEX idx_mv_daily_gmv_day ON mv_daily_gmv(day);

-- 0 나눗셈 방어 UDF (AOV 계산용)
CREATE OR REPLACE FUNCTION f_safe_div(numer numeric, denom numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF denom = 0 THEN
        RETURN 0;
    END IF;
    RETURN numer/denom;
END $$;

-- 상품별 현재 가격 View
CREATE OR REPLACE VIEW v_product_current_price AS
SELECT p.product_id, p.product_name, pp.price, pp.currency
FROM   products p
JOIN   product_prices pp
       ON pp.product_id = p.product_id AND pp.is_current;

-- 카테고리 경로 View (재귀 CTE : 대분류 > 소분류)
CREATE OR REPLACE VIEW v_category_path AS
WITH RECURSIVE r AS (
    SELECT category_id, parent_id, category_name, category_name::text AS path
    FROM   categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, c.parent_id, c.category_name, r.path || ' > ' || c.category_name
    FROM   categories c JOIN r ON c.parent_id = r.category_id
)
SELECT * FROM r;
