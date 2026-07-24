-- =============================================================
-- 01_seed.sql
-- E-Commerce 분석 실습 (종합실습 4) — 실습 데이터 적재
-- 작성자 : 신주용 / 광주 3반
-- 변경 이력 :
--   - 2026-07-21 최초 작성
--   - 2026-07-24 실습 제공 시드(ecom) 기준 전면 재구성
-- =============================================================
-- 접속 대상 : psql -d ecom_db -f 01_seed.sql
-- 데이터 설계 의도 :
--   - 상품 600 · 고객 3,000 · 리프 카테고리 균등 분배(편중 최소화)
--   - 가격 이력 3구간(SCD2) → 주문 시점 가격 매칭
--   - 헤비 고객(1~30)이 최근 매출 집중 생성 → Q10 상위 고객 분석용
--   - 200명 첫 구매 후 30일 내 재구매 보장 → Q6 재구매율 분석용
--   - 히어로 상품 12개(평점 4.5+ · 리뷰 다수) → Q8 효자 상품 분석용
--   - 재고 50개 상품 임계치 미달 강제 → Q7 품절 위험 분석용
-- =============================================================

SET search_path = ecom, public;

-- 재실행 대비 전체 초기화 (시퀀스 포함)
TRUNCATE TABLE
  reviews, shipments, payments, order_items, orders,
  inventory, product_suppliers, product_prices,
  products, suppliers, addresses, customers, categories, country
RESTART IDENTITY CASCADE;

-- =============================================================
-- 1. 마스터 데이터
-- =============================================================

-- 국가
INSERT INTO country(country_code, country_name) VALUES
('US','United States'),('KR','Korea'),('JP','Japan'),('DE','Germany'),('GB','United Kingdom')
ON CONFLICT DO NOTHING;

-- 카테고리 트리 : 대분류 4 + 소분류 10 (LATERAL 로 부모별 자식 생성)
WITH roots AS (
  INSERT INTO categories(parent_id, category_name)
  VALUES
    (NULL,'Electronics'),
    (NULL,'Home & Kitchen'),
    (NULL,'Fashion'),
    (NULL,'Sports')
  RETURNING category_id, category_name
)
INSERT INTO categories(parent_id, category_name)
SELECT r.category_id, v.child_name
FROM roots r
JOIN LATERAL (
  VALUES
    (CASE WHEN r.category_name='Electronics'     THEN 'Phones' END),
    (CASE WHEN r.category_name='Electronics'     THEN 'Laptops' END),
    (CASE WHEN r.category_name='Electronics'     THEN 'Audio' END),
    (CASE WHEN r.category_name='Home & Kitchen'  THEN 'Appliances' END),
    (CASE WHEN r.category_name='Home & Kitchen'  THEN 'Cookware' END),
    (CASE WHEN r.category_name='Fashion'         THEN 'Men' END),
    (CASE WHEN r.category_name='Fashion'         THEN 'Women' END),
    (CASE WHEN r.category_name='Fashion'         THEN 'Shoes' END),
    (CASE WHEN r.category_name='Sports'          THEN 'Outdoor' END),
    (CASE WHEN r.category_name='Sports'          THEN 'Fitness' END)
) AS v(child_name) ON v.child_name IS NOT NULL;

-- 공급사 50
INSERT INTO suppliers(supplier_name, phone)
SELECT 'Supplier ' || gs::text, '+1-555-10' || lpad(gs::text,3,'0')
FROM generate_series(1,50) gs;

-- 상품 600 : 리프 카테고리에 라운드로빈 균등 분배 (편중 최소화)
WITH leaf AS (
  SELECT category_id,
        row_number() OVER (ORDER BY random()) AS rn
  FROM categories
  WHERE parent_id IS NOT NULL
),
leaf_cnt AS (
  SELECT count(*)::int AS cnt FROM leaf
),
prod AS (
  SELECT gs,
        row_number() OVER (ORDER BY gs) AS rn
  FROM generate_series(1,600) gs
)
INSERT INTO products(sku, product_name, category_id, unit, active, created_at)
SELECT
  'SKU-' || to_char(p.gs,'FM000000') AS sku,
  'Product ' || p.gs::text          AS product_name,
  l.category_id                      AS category_id,
  'each'                             AS unit,
  true                               AS active,
  now() - random()*365 * interval '1 day' AS created_at
FROM prod p
CROSS JOIN leaf_cnt c
JOIN leaf l
  ON l.rn = ((p.rn - 1) % c.cnt) + 1;

-- 상품·공급사 매핑 : 행마다 LATERAL 랜덤 선택 (고정화 방지)
INSERT INTO product_suppliers(product_id, supplier_id, primary_supplier)
SELECT
  p.product_id,
  s.supplier_id,
  (random() < 0.2)
FROM products p
CROSS JOIN LATERAL (
  SELECT supplier_id
  FROM suppliers
  ORDER BY random()
  LIMIT 1
) s;

-- =============================================================
-- 2. 가격 이력 (SCD2) : 과거 2구간 + 현재 1구간
-- =============================================================

-- 과거 1 : 365~180일 전
INSERT INTO product_prices(product_id, price, currency, valid_from, valid_to, is_current)
SELECT p.product_id,
      round((10 + random()*190)::numeric, 2),
      'USD',
      now() - interval '365 days',
      now() - interval '180 days',
      false
FROM products p;

-- 과거 2 : 180~30일 전
INSERT INTO product_prices(product_id, price, currency, valid_from, valid_to, is_current)
SELECT p.product_id,
      round((10 + random()*190)::numeric, 2),
      'USD',
      now() - interval '180 days',
      now() - interval '30 days',
      false
FROM products p;

-- 현재 : 30일 전 ~ 365일 후
INSERT INTO product_prices(product_id, price, currency, valid_from, valid_to, is_current)
SELECT p.product_id,
      round((10 + random()*190)::numeric, 2),
      'USD',
      now() - interval '30 days',
      now() + interval '365 days',
      true
FROM products p;

-- =============================================================
-- 3. 재고 : 기본 적재 후 50개 상품을 임계치 미달로 강제 (Q7)
-- =============================================================

INSERT INTO inventory(product_id, qty_on_hand, reorder_point, updated_at)
SELECT p.product_id,
      (20 + (random()*400)::int),
      30,
      now()
FROM products p;

UPDATE inventory i
SET qty_on_hand = (random()*10)::int,
    reorder_point = 30,
    updated_at = now()
WHERE i.product_id IN (SELECT product_id FROM products ORDER BY random() LIMIT 50);

-- =============================================================
-- 4. 고객 3,000 + 배송지 (기본 1 + 약 35% 추가 1)
-- =============================================================

INSERT INTO customers(email, full_name, phone, created_at, marketing_opt_in, country_code)
SELECT 'user' || gs::text || '@example.com',
      'Customer ' || gs::text,
      '+82-10-' || lpad((10000000 + gs)::text,8,'0'),
      now() - random()*720 * interval '1 hour',
      (random() < 0.4),
      (ARRAY['US','KR','JP','DE','GB'])[1 + (random()*4)::int]
FROM generate_series(1,3000) gs;

-- 기본 배송지
INSERT INTO addresses(customer_id, line1, line2, city, state, postal_code, country_code, is_default, created_at)
SELECT c.customer_id,
      'Street ' || (1 + (random()*999)::int),
      NULL,
      (ARRAY['Seoul','Busan','New York','London','Tokyo','Berlin'])[1 + (random()*5)::int],
      NULL,
      lpad((10000 + (random()*89999)::int)::text,5,'0'),
      COALESCE(c.country_code, 'US'),
      true,
      now() - random()*365 * interval '1 day'
FROM customers c;

-- 추가 배송지 (~35%)
INSERT INTO addresses(customer_id, line1, line2, city, state, postal_code, country_code, is_default, created_at)
SELECT c.customer_id,
      'Apt ' || (1 + (random()*999)::int),
      'Unit ' || (1 + (random()*30)::int),
      (ARRAY['Seoul','Busan','New York','London','Tokyo','Berlin'])[1 + (random()*5)::int],
      NULL,
      lpad((10000 + (random()*89999)::int)::text,5,'0'),
      COALESCE(c.country_code, 'US'),
      false,
      now() - random()*365 * interval '1 day'
FROM customers c
WHERE random() < 0.35;

-- =============================================================
-- 5. 주문
-- =============================================================

-- (A) 일반 고객 : 고객당 0~4건 · 상태 혼합 (r 은 행당 1회 평가)
INSERT INTO orders(customer_id, order_status, order_ts, shipping_address_id, coupon_code, channel)
SELECT c.customer_id,
      CASE
        WHEN rr.r < 0.08 THEN 'created'
        WHEN rr.r < 0.18 THEN 'cancelled'
        WHEN rr.r < 0.26 THEN 'refunded'
        WHEN rr.r < 0.52 THEN 'paid'
        WHEN rr.r < 0.72 THEN 'shipped'
        ELSE 'delivered'
      END AS order_status,
      now() - random()*120 * interval '1 day' AS order_ts,
      (SELECT address_id
        FROM addresses a
        WHERE a.customer_id = c.customer_id
        ORDER BY random()
        LIMIT 1),
      CASE WHEN random() < 0.22 THEN 'SAVE10' END,
      (ARRAY['web','mobile','marketplace'])[1 + (random()*2)::int]
FROM customers c
CROSS JOIN LATERAL generate_series(1, ((random() + c.customer_id*0)*4)::int) g  -- 외부 참조로 상수 접힘 방지(고객별 난수)
CROSS JOIN LATERAL (
  -- 외부 참조 포함(상수화 방지) : 행마다 새 난수 보장
  SELECT (random() + (c.customer_id * 0)) AS r
) rr;

-- (B) 헤비 고객(1~30) : 최근 60일 유효 매출 주문 10~24건 (Q10)
INSERT INTO orders(customer_id, order_status, order_ts, shipping_address_id, coupon_code, channel)
SELECT c.customer_id,
      (ARRAY['paid','shipped','delivered'])[1 + (random()*2)::int],
      now() - random()*60 * interval '1 day',
      (SELECT address_id
        FROM addresses a
        WHERE a.customer_id = c.customer_id
        ORDER BY random()
        LIMIT 1),
      CASE WHEN random() < 0.35 THEN 'SAVE10' END,
      (ARRAY['web','mobile','marketplace'])[1 + (random()*2)::int]
FROM customers c
CROSS JOIN LATERAL generate_series(1, 10 + (random()*14)::int) g
WHERE c.customer_id BETWEEN 1 AND 30;

-- =============================================================
-- 6. 주문 상세 : 주문 시점 유효 가격 매칭 + 쿠폰 효과 반영
-- =============================================================

INSERT INTO order_items(order_id, product_id, qty, unit_price, discount)
SELECT o.order_id,
      x.product_id,
      x.qty,
      x.unit_price,
      x.discount
FROM orders o
CROSS JOIN LATERAL generate_series(
  1,
  CASE
    WHEN o.coupon_code IS NOT NULL THEN 2 + (random()*3)::int   -- 쿠폰 주문 2~5개 품목
    ELSE 1 + (random()*3)::int                                  -- 일반 주문 1~4개 품목
  END
) g
CROSS JOIN LATERAL (
  WITH picked AS (
    SELECT
      p.product_id,
      pp.price AS unit_price,
      CASE
        WHEN o.coupon_code IS NOT NULL THEN 1 + (random()*4)::int
        ELSE 1 + (random()*3)::int
      END AS qty
    FROM products p
    JOIN product_prices pp
      ON pp.product_id = p.product_id
    AND o.order_ts >= pp.valid_from AND o.order_ts < pp.valid_to
    ORDER BY
      -- 쿠폰 주문은 고가 상품 쪽으로 치우치게 선택
      CASE WHEN o.coupon_code IS NOT NULL THEN 0 ELSE 1 END,
      CASE WHEN o.coupon_code IS NOT NULL THEN pp.price END DESC,
      CASE WHEN o.coupon_code IS NULL THEN random() END,
      random()
    LIMIT 1
  )
  SELECT
    product_id,
    qty,
    unit_price,
    CASE
      WHEN o.coupon_code = 'SAVE10'
        THEN round((unit_price * qty) * 0.10, 2)
      ELSE 0
    END AS discount
  FROM picked
) x;

-- =============================================================
-- 7. 재구매 보장 (Q6) : 200명이 첫 구매 후 7~25일 내 재구매
-- =============================================================

WITH paid_orders AS (
  SELECT customer_id, order_id, order_ts
  FROM orders
  WHERE order_status IN ('paid','shipped','delivered')
),
first_buy AS (
  SELECT customer_id, min(order_ts) AS first_ts
  FROM paid_orders
  GROUP BY customer_id
),
target AS (
  SELECT customer_id, first_ts
  FROM first_buy
  WHERE customer_id NOT BETWEEN 1 AND 30
  ORDER BY random()
  LIMIT 200
),
ins_orders AS (
  INSERT INTO orders(customer_id, order_status, order_ts, shipping_address_id, coupon_code, channel)
  SELECT t.customer_id,
        (ARRAY['paid','delivered'])[1 + (random()*1)::int],
        t.first_ts + ((7 + (random()*18)::int) || ' days')::interval,
        (SELECT address_id FROM addresses a WHERE a.customer_id = t.customer_id ORDER BY random() LIMIT 1),
        CASE WHEN random() < 0.25 THEN 'SAVE10' END,
        (ARRAY['web','mobile','marketplace'])[1 + (random()*2)::int]
  FROM target t
  RETURNING order_id, order_ts, coupon_code
)
INSERT INTO order_items(order_id, product_id, qty, unit_price, discount)
SELECT o.order_id,
      x.product_id,
      x.qty,
      x.unit_price,
      x.discount
FROM ins_orders o
CROSS JOIN LATERAL generate_series(
  1,
  CASE WHEN o.coupon_code IS NOT NULL THEN 2 + (random()*2)::int ELSE 1 + (random()*2)::int END
) g
CROSS JOIN LATERAL (
  WITH picked AS (
    SELECT
      p.product_id,
      pp.price AS unit_price,
      CASE WHEN o.coupon_code IS NOT NULL THEN 1 + (random()*3)::int ELSE 1 + (random()*2)::int END AS qty
    FROM products p
    JOIN product_prices pp
      ON pp.product_id = p.product_id
    AND o.order_ts >= pp.valid_from AND o.order_ts < pp.valid_to
    ORDER BY random()
    LIMIT 1
  )
  SELECT
    product_id,
    qty,
    unit_price,
    CASE WHEN o.coupon_code='SAVE10' THEN round((unit_price * qty)*0.10, 2) ELSE 0 END AS discount
  FROM picked
) x;

-- =============================================================
-- 8. 결제 · 배송 (주문 상태와 정합)
-- =============================================================

INSERT INTO payments(order_id, method, amount, paid_at)
SELECT o.order_id,
      (ARRAY['card','bank','paypal','cod'])[1 + (random()*3)::int],
      COALESCE(
        (SELECT round(sum(oi.qty * oi.unit_price - oi.discount), 2)
          FROM order_items oi
          WHERE oi.order_id = o.order_id),
        0
      ) AS amount,
      o.order_ts + (random()*2) * INTERVAL '1 hour'
FROM orders o
WHERE o.order_status IN ('paid','shipped','delivered','refunded');

INSERT INTO shipments(order_id, carrier, tracking_no, shipped_at, delivered_at)
SELECT o.order_id,
      (ARRAY['DHL','UPS','FedEx','CJ','Kerry'])[1 + (random()*4)::int],
      'TRK' || o.order_id::text,
      o.order_ts + interval '1 day',
      CASE WHEN o.order_status = 'delivered' THEN o.order_ts + interval '3 days' END
FROM orders o
WHERE o.order_status IN ('shipped','delivered');

-- =============================================================
-- 9. 리뷰 (Q8) : 히어로 상품 12개(평점 4.5+ · 리뷰 다수) + 롱테일
-- =============================================================

WITH hero_products AS (
  SELECT product_id
  FROM products
  ORDER BY random()
  LIMIT 12
),
reviewers AS (
  SELECT customer_id
  FROM customers
  ORDER BY random()
  LIMIT 1500
),
pairs AS (
  SELECT hp.product_id, r.customer_id,
        CASE WHEN random() < 0.78 THEN 5 ELSE 4 END AS rating
  FROM hero_products hp
  CROSS JOIN LATERAL (
    SELECT customer_id FROM reviewers ORDER BY random() LIMIT 160
  ) r
)
INSERT INTO reviews(product_id, customer_id, rating, review_text, created_at)
SELECT product_id, customer_id, rating,
      'Great product ' || product_id::text,
      now() - random()*120 * interval '1 day'
FROM pairs
ON CONFLICT (product_id, customer_id) DO NOTHING;

-- 롱테일 랜덤 리뷰 (~22% 상품)
INSERT INTO reviews(product_id, customer_id, rating, review_text, created_at)
SELECT p.product_id, c.customer_id,
      1 + (random()*4)::int,
      'Review ' || p.product_id::text,
      now() - random()*180 * interval '1 day'
FROM products p
JOIN LATERAL (SELECT customer_id FROM customers ORDER BY random() LIMIT 1) c ON true
WHERE random() < 0.22
ON CONFLICT (product_id, customer_id) DO NOTHING;

-- =============================================================
-- 10. 마무리 : 안전 나눗셈 UDF(Q11) + MView 갱신 + 통계 수집
-- =============================================================

-- 0/NULL 분모 방어 (SQL 버전)
CREATE OR REPLACE FUNCTION safe_div(n numeric, d numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN d IS NULL OR d = 0 THEN NULL ELSE n / d END
$$;

-- MView 는 자동 갱신되지 않으므로 적재 직후 갱신
REFRESH MATERIALIZED VIEW mv_daily_gmv;

-- 플래너 통계 최신화 (실행계획 실습 전 필수)
ANALYZE;
