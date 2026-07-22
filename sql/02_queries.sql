-- =============================================================
-- 02_queries.sql
-- E-Commerce 분석 실습 (종합실습 4) — Q1 ~ Q11 풀이
-- 작성자 : 신주용 / 광주 3반
-- 작성일 : 2026-07-21
-- 변경 이력 :
--   2026-07-21 최초 작성
-- =============================================================
-- 접속 대상 : psql -d ecom_db -f 02_queries.sql
-- 실행 전제 : 00_schema.sql, 01_seed.sql 완료
-- =============================================================

-- Q1. 지난 한 달간 GMV (Gross Merchandise Value)
-- =============================================================
-- 유효 거래(paid/shipped/delivered) 기준 총 판매금액 집계
-- order_items.qty * unit_price 합산, 지난 30일 주문으로 한정
-- =============================================================
-- Q1.
SELECT
    SUM(oi.qty * oi.unit_price)  AS gmv_last_30d  -- 총 판매금액
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('paid', 'shipped', 'delivered')  -- 유효 거래 필터
  AND o.order_date >= NOW() - INTERVAL '30 days';


-- Q2. 월별 주문수 / 매출 / AOV (평균주문금액)
-- =============================================================
-- DATE_TRUNC('month') 로 월 집계
-- AOV = 총매출 / 주문수 (유효 거래만 포함)
-- =============================================================
-- Q2.
SELECT
    DATE_TRUNC('month', o.order_date)::DATE   AS order_month,
    COUNT(DISTINCT o.order_id)                AS order_cnt,
    SUM(oi.qty * oi.unit_price)               AS revenue,
    ROUND(
        SUM(oi.qty * oi.unit_price)
        / NULLIF(COUNT(DISTINCT o.order_id), 0),   -- 0 나눗셈 방어
        0
    )                                         AS aov           -- 주문당 평균금액
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('paid', 'shipped', 'delivered')
GROUP BY DATE_TRUNC('month', o.order_date)
ORDER BY order_month;


-- Q3. 최근 90일 카테고리 Top 10 (매출 기준)
-- =============================================================
-- 소분류 카테고리 기준 집계, RANK() 로 순위 산출
-- 유효 거래 필터 동일 적용
-- =============================================================
-- Q3.
WITH cat_sales AS (
    -- 카테고리별 90일 매출 집계
    SELECT
        c.category_id,
        c.name                            AS category_name,
        SUM(oi.qty * oi.unit_price)       AS revenue_90d
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    JOIN products    p  ON p.product_id  = oi.product_id
    JOIN categories  c  ON c.category_id = p.category_id
    WHERE o.status   IN ('paid', 'shipped', 'delivered')
      AND o.order_date >= NOW() - INTERVAL '90 days'
    GROUP BY c.category_id, c.name
),
ranked AS (
    SELECT
        category_name,
        revenue_90d,
        RANK() OVER (ORDER BY revenue_90d DESC) AS rnk
    FROM cat_sales
)
SELECT rnk, category_name, revenue_90d
FROM ranked
WHERE rnk <= 10
ORDER BY rnk;


-- Q4. 제품별 누적매출 RANK() Top 20 (Window Function)
-- =============================================================
-- 전체 기간 유효 거래 기준 상품별 매출 누적 후 순위 산출
-- RANK() : 동점 허용 (Dense_rank 아님)
-- =============================================================
-- Q4.
WITH prod_sales AS (
    SELECT
        p.product_id,
        p.name                          AS product_name,
        SUM(oi.qty * oi.unit_price)     AS total_revenue
    FROM order_items oi
    JOIN products    p  ON p.product_id  = oi.product_id
    JOIN orders      o  ON o.order_id    = oi.order_id
    WHERE o.status IN ('paid', 'shipped', 'delivered')
    GROUP BY p.product_id, p.name
)
SELECT
    RANK() OVER (ORDER BY total_revenue DESC) AS rnk,
    product_id,
    product_name,
    total_revenue
FROM prod_sales
ORDER BY rnk
LIMIT 20;


-- Q5. RFM 분석 (고객별 최근성 / 빈도 / 금액)
-- =============================================================
-- R(Recency)  : 마지막 주문일 ~ 오늘 경과 일수 (작을수록 최근)
-- F(Frequency): 총 주문 횟수
-- M(Monetary) : 총 결제 금액
-- 유효 거래(paid/shipped/delivered)만 집계
-- =============================================================
-- Q5.
SELECT
    o.customer_id,
    MAX(o.order_date::DATE)                      AS last_order_date,
    (CURRENT_DATE - MAX(o.order_date::DATE))     AS recency_days,     -- R
    COUNT(DISTINCT o.order_id)                   AS frequency,         -- F
    SUM(oi.qty * oi.unit_price)                  AS monetary           -- M
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('paid', 'shipped', 'delivered')
GROUP BY o.customer_id
ORDER BY monetary DESC
LIMIT 30;   -- 상위 30명만 출력 (전체 출력 억제)


-- Q6. 첫 구매 후 30일 내 재구매율
-- =============================================================
-- 고객별 첫 구매일 산출 → 30일 이내 2번 이상 구매 여부 판단
-- 재구매율 = 30일 내 재구매 고객 수 / 전체 구매 경험 고객 수
-- =============================================================
-- Q6.
WITH first_purchase AS (
    -- 고객별 첫 구매일 (유효 거래 기준)
    SELECT
        customer_id,
        MIN(order_date) AS first_order_date
    FROM orders
    WHERE status IN ('paid', 'shipped', 'delivered')
    GROUP BY customer_id
),
repurchase AS (
    -- 첫 구매 후 30일 이내 추가 구매 존재 여부
    SELECT
        fp.customer_id,
        COUNT(o.order_id) AS orders_in_30d
    FROM first_purchase fp
    JOIN orders o
      ON o.customer_id = fp.customer_id
     AND o.status      IN ('paid', 'shipped', 'delivered')
     AND o.order_date  > fp.first_order_date               -- 첫 구매 이후
     AND o.order_date <= fp.first_order_date + INTERVAL '30 days'
    GROUP BY fp.customer_id
)
SELECT
    COUNT(DISTINCT fp.customer_id)                        AS total_buyers,
    COUNT(DISTINCT rp.customer_id)                        AS repurchase_buyers,
    ROUND(
        COUNT(DISTINCT rp.customer_id)::NUMERIC
        / NULLIF(COUNT(DISTINCT fp.customer_id), 0) * 100,
        2
    )                                                     AS repurchase_rate_pct
FROM first_purchase fp
LEFT JOIN repurchase rp ON rp.customer_id = fp.customer_id;


-- Q7. 재고 임계치 미달 상품 (품절 위험)
-- =============================================================
-- stock < reorder_point 조건 : 즉시 재주문 필요 상품
-- 현재 가격(valid_to IS NULL)도 함께 조회
-- =============================================================
-- Q7.
SELECT
    p.product_id,
    p.name                  AS product_name,
    i.stock                 AS current_stock,
    i.reorder_point,
    i.reorder_point - i.stock AS shortage,   -- 부족 수량
    pp.price                AS current_price
FROM inventory i
JOIN products       p  ON p.product_id  = i.product_id
JOIN product_prices pp ON pp.product_id = i.product_id
                      AND pp.valid_to IS NULL          -- 현재 가격
WHERE i.stock < i.reorder_point                       -- 재주문 시점 미달
ORDER BY shortage DESC
LIMIT 30;


-- Q8. 효자 상품 (리뷰 4.5점 이상 & 리뷰 50개 이상)
-- =============================================================
-- 고평점 + 충분한 리뷰량 두 조건 동시 만족하는 상품
-- HAVING 절로 집계 후 필터
-- =============================================================
-- Q8.
SELECT
    p.product_id,
    p.name                          AS product_name,
    ROUND(AVG(r.rating), 2)         AS avg_rating,
    COUNT(r.review_id)              AS review_cnt
FROM reviews r
JOIN products p ON p.product_id = r.product_id
GROUP BY p.product_id, p.name
HAVING AVG(r.rating) >= 4.5          -- 평균 별점 4.5 이상
   AND COUNT(r.review_id) >= 50       -- 리뷰 50개 이상
ORDER BY avg_rating DESC, review_cnt DESC;


-- Q9. 쿠폰 사용 vs 미사용 평균 주문금액 비교
-- =============================================================
-- coupon_code IS NULL : 미사용 / NOT NULL : 쿠폰 적용
-- 유효 거래 기준 주문별 합산 후 그룹 평균 비교
-- =============================================================
-- Q9.
WITH order_amount AS (
    -- 주문별 총액 계산
    SELECT
        o.order_id,
        CASE WHEN o.coupon_code IS NOT NULL
             THEN '쿠폰사용'
             ELSE '쿠폰미사용'
        END                          AS coupon_yn,
        SUM(oi.qty * oi.unit_price)  AS order_total
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status IN ('paid', 'shipped', 'delivered')
    GROUP BY o.order_id, o.coupon_code
)
SELECT
    coupon_yn,
    COUNT(*)                       AS order_cnt,
    ROUND(AVG(order_total), 0)     AS avg_order_amount,
    ROUND(SUM(order_total), 0)     AS total_revenue
FROM order_amount
GROUP BY coupon_yn
ORDER BY coupon_yn;


-- Q10. 상위 1% 고객의 최근 60일 매출
-- =============================================================
-- NTILE(100) 또는 PERCENT_RANK() 로 1% 고객 분류
-- 이후 60일 주문 기준 매출 집계
-- =============================================================
-- Q10.
WITH customer_total AS (
    -- 전체 기간 고객별 누적 매출 (상위 1% 분류용)
    SELECT
        o.customer_id,
        SUM(oi.qty * oi.unit_price) AS lifetime_revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status IN ('paid', 'shipped', 'delivered')
    GROUP BY o.customer_id
),
top1pct AS (
    -- 상위 1% 고객 추출
    SELECT customer_id
    FROM (
        SELECT
            customer_id,
            NTILE(100) OVER (ORDER BY lifetime_revenue DESC) AS pct_tile
        FROM customer_total
    ) t
    WHERE pct_tile = 1
),
recent_60d AS (
    -- 상위 1% 고객의 최근 60일 매출
    SELECT
        o.customer_id,
        SUM(oi.qty * oi.unit_price)  AS revenue_60d,
        COUNT(DISTINCT o.order_id)   AS orders_60d
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status IN ('paid', 'shipped', 'delivered')
      AND o.order_date >= NOW() - INTERVAL '60 days'
      AND o.customer_id IN (SELECT customer_id FROM top1pct)
    GROUP BY o.customer_id
)
SELECT
    r.customer_id,
    c.name             AS customer_name,
    r.orders_60d,
    r.revenue_60d
FROM recent_60d r
JOIN customers   c ON c.customer_id = r.customer_id
ORDER BY revenue_60d DESC;


-- Q11. NULLIF를 활용한 안전한 평균 계산 (0 나눗셈 방어)
-- =============================================================
-- 채널별 주문 건수·배송완료 건수를 집계해
-- 배송완료 건수가 0인 채널에서도 나눗셈 오류 없이 완료율 산출
-- NULLIF(분모, 0) → 분모가 0이면 NULL로 치환하여 NULL / 값 = NULL 반환
-- =============================================================
-- Q11.
SELECT
    channel,
    COUNT(*)                                               AS total_orders,
    COUNT(*) FILTER (WHERE status = 'delivered')           AS delivered_cnt,
    -- NULLIF(분모, 0) : 0 나눗셈 방지
    ROUND(
        COUNT(*) FILTER (WHERE status = 'delivered')::NUMERIC
        / NULLIF(COUNT(*), 0) * 100,
        2
    )                                                      AS delivery_rate_pct,
    -- 채널별 주문당 평균 금액도 안전하게 산출
    ROUND(
        SUM(oi.qty * oi.unit_price)
        / NULLIF(COUNT(DISTINCT o.order_id), 0),
        0
    )                                                      AS aov_safe
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY channel
ORDER BY channel;
