-- =============================================================
-- 01_seed.sql
-- E-Commerce 분석 실습 (종합실습 4) — 테스트 데이터 적재
-- 작성자 : 신주용 / 광주 3반
-- 작성일 : 2026-07-21
-- 변경 이력 :
--   2026-07-21 최초 작성
-- =============================================================
-- 접속 대상 : psql -d ecom_db -f 01_seed.sql
-- =============================================================

-- 트랜잭션으로 묶어 원자적 적재 (중간 실패 시 롤백)
BEGIN;

-- =============================================================
-- 1. 카테고리 트리 (3단계: 대분류→중분류→소분류)
-- =============================================================
INSERT INTO categories(category_id, name, parent_id) VALUES
  -- 대분류
  (1, '전자제품',    NULL),
  (2, '패션',        NULL),
  (3, '식품',        NULL),
  (4, '가구/인테리어', NULL),
  -- 중분류
  (5, '스마트폰',    1),
  (6, '노트북',      1),
  (7, '오디오',      1),
  (8, '남성의류',    2),
  (9, '여성의류',    2),
  (10,'신발',        2),
  (11,'신선식품',    3),
  (12,'가공식품',    3),
  (13,'가구',        4),
  (14,'조명',        4),
  -- 소분류
  (15,'안드로이드폰', 5),
  (16,'아이폰',      5),
  (17,'게이밍노트북', 6),
  (18,'업무용노트북', 6),
  (19,'블루투스이어폰', 7),
  (20,'스피커',      7),
  (21,'청바지',      8),
  (22,'티셔츠',      8),
  (23,'원피스',      9),
  (24,'블라우스',    9),
  (25,'운동화',     10),
  (26,'구두',       10),
  (27,'채소/과일',  11),
  (28,'육류/수산',  11),
  (29,'라면/면류',  12),
  (30,'음료',       12),
  (31,'소파',       13),
  (32,'침대',       13),
  (33,'LED조명',    14),
  (34,'스탠드조명', 14);

-- 시퀀스 갱신
SELECT setval('categories_category_id_seq', 34);

-- =============================================================
-- 2. 상품 마스터 (200개)
--    generate_series 기반, 카테고리 소분류에 순환 배분
-- =============================================================
INSERT INTO products(product_id, name, category_id, base_price)
SELECT
    s.n,
    '상품_' || LPAD(s.n::TEXT, 3, '0') AS name,
    -- 소분류(15~34) 순환 배분
    15 + ((s.n - 1) % 20) AS category_id,
    -- 가격 : 카테고리별 대역 설정 (전자 비쌈, 식품 쌈)
    CASE 15 + ((s.n - 1) % 20)
        WHEN 15 THEN 450000 + (s.n % 10) * 30000   -- 안드로이드폰
        WHEN 16 THEN 900000 + (s.n % 10) * 50000   -- 아이폰
        WHEN 17 THEN 1200000 + (s.n % 10) * 60000  -- 게이밍노트북
        WHEN 18 THEN 800000 + (s.n % 10) * 40000   -- 업무용노트북
        WHEN 19 THEN 80000 + (s.n % 10) * 8000     -- 블루투스이어폰
        WHEN 20 THEN 120000 + (s.n % 10) * 10000   -- 스피커
        WHEN 21 THEN 35000 + (s.n % 10) * 3000     -- 청바지
        WHEN 22 THEN 18000 + (s.n % 10) * 2000     -- 티셔츠
        WHEN 23 THEN 45000 + (s.n % 10) * 4000     -- 원피스
        WHEN 24 THEN 32000 + (s.n % 10) * 3000     -- 블라우스
        WHEN 25 THEN 60000 + (s.n % 10) * 5000     -- 운동화
        WHEN 26 THEN 95000 + (s.n % 10) * 7000     -- 구두
        WHEN 27 THEN 5000 + (s.n % 10) * 500       -- 채소/과일
        WHEN 28 THEN 15000 + (s.n % 10) * 1500     -- 육류/수산
        WHEN 29 THEN 3500 + (s.n % 10) * 300       -- 라면/면류
        WHEN 30 THEN 2000 + (s.n % 10) * 200       -- 음료
        WHEN 31 THEN 250000 + (s.n % 10) * 20000   -- 소파
        WHEN 32 THEN 350000 + (s.n % 10) * 25000   -- 침대
        WHEN 33 THEN 30000 + (s.n % 10) * 2500     -- LED조명
        ELSE         22000 + (s.n % 10) * 2000     -- 스탠드조명
    END AS base_price
FROM generate_series(1, 200) s(n);

SELECT setval('products_product_id_seq', 200);

-- =============================================================
-- 3. 가격 이력 SCD Type-2
--    상품당 2~3구간 가격 이력 (valid_to NULL = 현재)
-- =============================================================
-- 구간 1 : 초기 가격 (7개월 전 ~ 4개월 전)
INSERT INTO product_prices(product_id, price, valid_from, valid_to)
SELECT
    p.product_id,
    p.base_price * 1.10 AS price,          -- 최초 가격은 10% 높음
    CURRENT_DATE - INTERVAL '210 days',
    CURRENT_DATE - INTERVAL '120 days'
FROM products p;

-- 구간 2 : 중간 가격 (4개월 전 ~ 1개월 전)
INSERT INTO product_prices(product_id, price, valid_from, valid_to)
SELECT
    p.product_id,
    p.base_price * 1.05,
    CURRENT_DATE - INTERVAL '120 days',
    CURRENT_DATE - INTERVAL '30 days'
FROM products p;

-- 구간 3 : 현재 가격 (1개월 전 ~ 현재, valid_to NULL)
INSERT INTO product_prices(product_id, price, valid_from, valid_to)
SELECT
    p.product_id,
    p.base_price,
    CURRENT_DATE - INTERVAL '30 days',
    NULL
FROM products p;

-- =============================================================
-- 4. 재고 (일부 품목 재주문시점 미달 — Q7 결과 확보)
--    product_id 홀수 : 재고 충분, 짝수 중 일부 : 재고 부족
-- =============================================================
INSERT INTO inventory(product_id, stock, reorder_point)
SELECT
    s.n,
    CASE
        WHEN s.n % 4 = 0 THEN 5          -- 재고 5개 (재주문시점 20 미달)
        WHEN s.n % 4 = 2 THEN 18         -- 재고 18개 (재주문시점 미달)
        WHEN s.n % 3 = 0 THEN 200        -- 재고 충분
        ELSE 80
    END AS stock,
    CASE
        WHEN s.n % 4 IN (0,2) THEN 30    -- 재주문시점 30
        ELSE 20
    END AS reorder_point
FROM generate_series(1, 200) s(n);

-- =============================================================
-- 5. 고객 500명
-- =============================================================
INSERT INTO customers(customer_id, name, email, channel, signup_date)
SELECT
    s.n,
    '고객_' || LPAD(s.n::TEXT, 3, '0'),
    'customer' || s.n || '@example.com',
    -- 채널 분포 : web 50%, mobile 35%, marketplace 15%
    CASE
        WHEN s.n % 20 < 10 THEN 'web'
        WHEN s.n % 20 < 17 THEN 'mobile'
        ELSE 'marketplace'
    END,
    CURRENT_DATE - (((s.n * 7) % 365) || ' days')::INTERVAL
FROM generate_series(1, 500) s(n);

SELECT setval('customers_customer_id_seq', 500);

-- =============================================================
-- 6. 쿠폰
-- =============================================================
INSERT INTO coupons(code, discount_rate, valid_from, valid_to) VALUES
  ('SAVE10', 10.00, '2026-01-01', '2026-12-31'),
  ('SUMMER5',  5.00, '2026-06-01', '2026-08-31'),
  ('NEWUSER15',15.00, '2026-01-01', '2026-12-31');

-- =============================================================
-- 7. 주문 헤더 (약 3,000건)
--    최근 6개월 분포, status/channel 다양, 일부 쿠폰 적용
-- =============================================================
INSERT INTO orders(order_id, customer_id, channel, status, order_date, coupon_code)
SELECT
    s.n                                              AS order_id,
    -- 고객 1~500 순환 (VIP 고객 집중 설계 — 상위 1% Q10용)
    CASE
        WHEN s.n <= 500 THEN (s.n - 1) % 5 + 1     -- 고객 1~5: 초고빈도 (100주문씩)
        WHEN s.n <= 1500 THEN ((s.n - 501) % 45) + 6  -- 고객 6~50: 중빈도
        ELSE ((s.n - 1501) % 450) + 51              -- 고객 51~500: 저빈도
    END                                              AS customer_id,
    -- 채널 분포
    CASE (s.n % 3)
        WHEN 0 THEN 'web'
        WHEN 1 THEN 'mobile'
        ELSE 'marketplace'
    END                                              AS channel,
    -- 상태 분포 (유효거래 다수, 취소/환불 소수)
    CASE
        WHEN s.n % 20 = 0 THEN 'cancelled'
        WHEN s.n % 25 = 0 THEN 'refunded'
        WHEN s.n % 7 = 0  THEN 'created'
        WHEN s.n % 5 = 0  THEN 'paid'
        WHEN s.n % 3 = 0  THEN 'shipped'
        ELSE 'delivered'
    END                                              AS status,
    -- 주문 일시 : 최근 180일 내 균등 분포
    NOW() - ((s.n % 180) || ' days')::INTERVAL
        - ((s.n % 86400) || ' seconds')::INTERVAL   AS order_date,
    -- 쿠폰 : 약 15% 주문에 적용
    CASE
        WHEN s.n % 7 = 0 THEN 'SAVE10'
        WHEN s.n % 13 = 0 THEN 'SUMMER5'
        ELSE NULL
    END                                              AS coupon_code
FROM generate_series(1, 3000) s(n);

SELECT setval('orders_order_id_seq', 3000);

-- =============================================================
-- 8. 주문 상세 (order_items)
--    주문당 1~3개 라인아이템, 현재 유효 가격 적용
-- =============================================================
-- 라인 1 : 모든 주문에 1개 (상품 순환)
INSERT INTO order_items(order_id, product_id, qty, unit_price)
SELECT
    o.order_id,
    1 + (o.order_id % 200)                           AS product_id,
    1 + (o.order_id % 3)                             AS qty,
    pp.price                                          AS unit_price
FROM orders o
JOIN product_prices pp
  ON pp.product_id = 1 + (o.order_id % 200)
 AND pp.valid_to IS NULL;

-- 라인 2 : 짝수 주문에 추가 (다른 상품)
INSERT INTO order_items(order_id, product_id, qty, unit_price)
SELECT
    o.order_id,
    1 + ((o.order_id + 50) % 200)                    AS product_id,
    1 + (o.order_id % 2)                             AS qty,
    pp.price                                          AS unit_price
FROM orders o
JOIN product_prices pp
  ON pp.product_id = 1 + ((o.order_id + 50) % 200)
 AND pp.valid_to IS NULL
WHERE o.order_id % 2 = 0;

-- 라인 3 : 3의 배수 주문에 추가 (또 다른 상품)
INSERT INTO order_items(order_id, product_id, qty, unit_price)
SELECT
    o.order_id,
    1 + ((o.order_id + 100) % 200)                   AS product_id,
    2                                                 AS qty,
    pp.price                                          AS unit_price
FROM orders o
JOIN product_prices pp
  ON pp.product_id = 1 + ((o.order_id + 100) % 200)
 AND pp.valid_to IS NULL
WHERE o.order_id % 3 = 0;

-- =============================================================
-- 9. 리뷰 (약 2,000건)
--    상품 1~20 : 리뷰 100개 이상, 평균 4.5↑ (Q8 효자상품)
--    나머지 : 적은 리뷰, 낮은 평점도 포함
-- =============================================================
-- 효자 상품 (product_id 1~20) : 고평점 대량 리뷰
INSERT INTO reviews(product_id, customer_id, rating, review_date, content)
SELECT
    1 + (s.n % 20)                                   AS product_id,
    1 + (s.n % 500)                                  AS customer_id,
    -- 평균 약 4.6 (5,5,5,4,5 패턴)
    CASE s.n % 5
        WHEN 0 THEN 4
        ELSE 5
    END                                              AS rating,
    CURRENT_DATE - (s.n % 90 || ' days')::INTERVAL  AS review_date,
    '만족스러운 구매였습니다.'
FROM generate_series(1, 1200) s(n);

-- 일반 상품 (product_id 21~200) : 소량·다양한 평점
INSERT INTO reviews(product_id, customer_id, rating, review_date, content)
SELECT
    21 + (s.n % 180)                                 AS product_id,
    1 + (s.n % 500)                                  AS customer_id,
    1 + (s.n % 5)                                    AS rating,
    CURRENT_DATE - (s.n % 180 || ' days')::INTERVAL AS review_date,
    '상품 후기입니다.'
FROM generate_series(1, 800) s(n);

COMMIT;

-- =============================================================
-- 적재 결과 확인 (행수 출력)
-- =============================================================
SELECT
    'categories'    AS tbl, COUNT(*) AS rows FROM categories UNION ALL
SELECT 'products',           COUNT(*) FROM products           UNION ALL
SELECT 'product_prices',     COUNT(*) FROM product_prices     UNION ALL
SELECT 'inventory',          COUNT(*) FROM inventory          UNION ALL
SELECT 'customers',          COUNT(*) FROM customers          UNION ALL
SELECT 'coupons',            COUNT(*) FROM coupons            UNION ALL
SELECT 'orders',             COUNT(*) FROM orders             UNION ALL
SELECT 'order_items',        COUNT(*) FROM order_items        UNION ALL
SELECT 'reviews',            COUNT(*) FROM reviews
ORDER BY tbl;
