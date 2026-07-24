-- =============================================================
-- 02_queries.sql
-- E-Commerce 분석 실습 (종합실습 4) — Q1~Q11 · 문항별 튜닝 전/후
-- 작성자 : 신주용 / 광주 3반
-- 변경 이력 :
--   - 2026-07-21 최초 작성
--   - 2026-07-24 실습 제공 스키마(ecom) 기준 전면 재구성
-- =============================================================
-- 접속 대상 : psql -d ecom_db -f 02_queries.sql
-- 실행 전제 : 00_schema.sql → 01_seed.sql 완료
-- 구성 원칙 : 문항마다 [전] 기본 쿼리 + 실행계획 점검
--             → [튜닝] 인덱스/재작성 → [후] 실행계획 재점검
--             튜닝 인덱스는 누적 적용(운영처럼 앞 문항 개선을 재사용)
-- 판단 기준 : ms 단위 1회 실측보다 ① Buffers(shared read 최소·hit 비중)
--             ② 계획 구조(Seq → Index/Index Only · 불필요 연산 제거)
--             ③ 재현성(반복 평균 안정) — 말미 재현성 검증 참조
-- =============================================================

SET search_path = ecom, public;

-- =============================================================
-- Q1. 지난 한 달간 실제 팔린 총 금액 (paid + shipped + delivered)
-- =============================================================

-- [전] 유효 주문 필터 + 주문상세 조인 합계
--      실행계획 : orders Seq Scan(전체를 읽고 대부분 버림) + Hash Join
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(oi.line_total) AS gmv_last_30d
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
AND    o.order_ts >= now() - interval '30 days';

SELECT sum(oi.line_total) AS gmv_last_30d
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
AND    o.order_ts >= now() - interval '30 days';

-- [튜닝] 유효 상태 주문만 담는 부분 인덱스
--        → 무효 주문(created·cancelled·refunded)은 인덱스에서 제외
CREATE INDEX idx_orders_valid_ts ON orders(order_ts)
    WHERE order_status IN ('paid','shipped','delivered');
ANALYZE orders;

-- [후] Seq Scan → Bitmap Index Scan (필터 대상만 읽음)
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(oi.line_total) AS gmv_last_30d
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
AND    o.order_ts >= now() - interval '30 days';

-- =============================================================
-- Q2. 월별 주문수 · 매출 · AOV(주문당 평균 금액)
-- =============================================================

-- [전] count(DISTINCT) 방식 — 중복 제거를 위한 대형 Sort 발생
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('month', o.order_ts)::date AS month,
       count(DISTINCT o.order_id)            AS orders,
       sum(oi.line_total)                    AS revenue,
       round(sum(oi.line_total) / count(DISTINCT o.order_id), 2) AS aov
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
GROUP  BY 1 ORDER BY 1;

-- [튜닝 = 재작성] 주문 단위 선집계 → DISTINCT 제거(2단계 해시 집계)
-- [후] 대형 Sort 제거 · 비용 절반 수준
EXPLAIN (ANALYZE, BUFFERS)
SELECT month, count(*) AS orders, sum(order_rev) AS revenue,
       round(avg(order_rev), 2) AS aov
FROM (
    SELECT date_trunc('month', o.order_ts)::date AS month,
           o.order_id, sum(oi.line_total) AS order_rev
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    GROUP  BY 1, 2
) s GROUP BY month ORDER BY month;

SELECT month, count(*) AS orders, sum(order_rev) AS revenue,
       round(avg(order_rev), 2) AS aov
FROM (
    SELECT date_trunc('month', o.order_ts)::date AS month,
           o.order_id, sum(oi.line_total) AS order_rev
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    GROUP  BY 1, 2
) s GROUP BY month ORDER BY month;

-- (참고) 매출만 필요한 리포트는 mv_daily_gmv 월 롤업이 최속 — 03 참고
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('month', day)::date AS month, sum(gmv) AS revenue
FROM   mv_daily_gmv GROUP BY 1 ORDER BY 1;

-- =============================================================
-- Q3. 최근 90일 카테고리 Top 10 (매출 기준)
-- =============================================================

-- [전] 4테이블 조인 + 90일 필터
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.category_name, sum(oi.line_total) AS revenue
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
JOIN   products p     ON p.product_id  = oi.product_id
JOIN   categories c   ON c.category_id = p.category_id
WHERE  o.order_status IN ('paid','shipped','delivered')
AND    o.order_ts >= now() - interval '90 days'
GROUP  BY c.category_name
ORDER  BY revenue DESC
LIMIT  10;

SELECT c.category_name, sum(oi.line_total) AS revenue
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
JOIN   products p     ON p.product_id  = oi.product_id
JOIN   categories c   ON c.category_id = p.category_id
WHERE  o.order_status IN ('paid','shipped','delivered')
AND    o.order_ts >= now() - interval '90 days'
GROUP  BY c.category_name
ORDER  BY revenue DESC
LIMIT  10;

-- [점검 판정] 90일 조건은 유효 주문의 대부분(선택도 높음)
--   → 옵티마이저가 Seq Scan 유지 = 비용상 정당(인덱스가 오히려 손해)
-- [시연] 같은 쿼리를 30일로 좁히면 Q1 부분 인덱스를 자동 채택
--   → 선택도에 따라 접근 경로가 바뀌는 비용 기반 판단 확인
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.category_name, sum(oi.line_total) AS revenue
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
JOIN   products p     ON p.product_id  = oi.product_id
JOIN   categories c   ON c.category_id = p.category_id
WHERE  o.order_status IN ('paid','shipped','delivered')
AND    o.order_ts >= now() - interval '30 days'
GROUP  BY c.category_name
ORDER  BY revenue DESC
LIMIT  10;

-- =============================================================
-- Q4. 제품별 누적매출 RANK() Top 20 (Window Function)
-- =============================================================

-- [전] 주문상세 전량 집계 → RANK() 윈도우
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.product_name, s.revenue,
       RANK() OVER (ORDER BY s.revenue DESC) AS rnk
FROM (
    SELECT oi.product_id, sum(oi.line_total) AS revenue
    FROM   order_items oi
    GROUP  BY oi.product_id
) s
JOIN   products p ON p.product_id = s.product_id
ORDER  BY s.revenue DESC
LIMIT  20;

SELECT p.product_name, s.revenue,
       RANK() OVER (ORDER BY s.revenue DESC) AS rnk
FROM (
    SELECT oi.product_id, sum(oi.line_total) AS revenue
    FROM   order_items oi
    GROUP  BY oi.product_id
) s
JOIN   products p ON p.product_id = s.product_id
ORDER  BY s.revenue DESC
LIMIT  20;

-- [점검 판정] 전량 집계는 Seq + HashAggregate 가 현 규모 최적
-- [시연] 커버링 인덱스를 만들어도 채택 안 됨(비용 동일 확인)
--        → Seq 차단 시 Index Only Scan 으로 전환됨을 확인(대규모 대비)
CREATE INDEX idx_oi_product_cover ON order_items(product_id) INCLUDE (line_total);
ANALYZE order_items;

EXPLAIN (ANALYZE, BUFFERS)
SELECT oi.product_id, sum(oi.line_total) AS revenue
FROM   order_items oi
GROUP  BY oi.product_id
ORDER  BY revenue DESC LIMIT 5;

SET enable_seqscan = off;   -- 시연용 : Seq 차단 시 대체 경로 확인
EXPLAIN (ANALYZE, BUFFERS)
SELECT oi.product_id, sum(oi.line_total) AS revenue
FROM   order_items oi
GROUP  BY oi.product_id
ORDER  BY revenue DESC LIMIT 5;
RESET enable_seqscan;

-- 시연 종료 → 채택되지 않는 인덱스는 유지 비용만 남으므로 제거
DROP INDEX idx_oi_product_cover;

-- =============================================================
-- Q5. RFM — 고객이 얼마나 최근에 · 자주 · 많이 샀는지
-- =============================================================

-- [전] count(DISTINCT) 방식 — 수백 kB 대형 Sort 발생
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.customer_id,
       max(o.order_ts)::date      AS recency_last_order,
       count(DISTINCT o.order_id) AS frequency,
       sum(oi.line_total)         AS monetary
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
GROUP  BY o.customer_id
ORDER  BY monetary DESC
LIMIT  10;

-- [튜닝 = 재작성] 주문 단위 선집계 → DISTINCT · 대형 Sort 제거
-- [후] 대형 Sort 제거 · 비용 절반 수준
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.customer_id,
       max(s.order_ts)::date AS recency_last_order,
       count(*)              AS frequency,
       sum(s.order_rev)      AS monetary
FROM (
    SELECT o.customer_id, o.order_id, o.order_ts,
           sum(oi.line_total) AS order_rev
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    GROUP  BY o.customer_id, o.order_id, o.order_ts
) s
GROUP  BY s.customer_id
ORDER  BY monetary DESC
LIMIT  10;

SELECT s.customer_id,
       max(s.order_ts)::date AS recency_last_order,
       count(*)              AS frequency,
       sum(s.order_rev)      AS monetary
FROM (
    SELECT o.customer_id, o.order_id, o.order_ts,
           sum(oi.line_total) AS order_rev
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    GROUP  BY o.customer_id, o.order_id, o.order_ts
) s
GROUP  BY s.customer_id
ORDER  BY monetary DESC
LIMIT  10;

-- =============================================================
-- Q6. 첫 구매 후 30일 내 재구매율  ★ 본 실습 대표 튜닝 사례
-- =============================================================

-- [전] 상관 EXISTS — 고객 수만큼 CTE 반복 스캔 → 비용 폭발
EXPLAIN (ANALYZE, BUFFERS)
WITH valid AS (
    SELECT customer_id, order_ts
    FROM   orders
    WHERE  order_status IN ('paid','shipped','delivered')
),
first_buy AS (
    SELECT customer_id, min(order_ts) AS first_ts
    FROM   valid GROUP BY customer_id
)
SELECT round(100.0 * count(*) FILTER (WHERE rebuy) / count(*), 1) AS rebuy_rate_pct
FROM (
    SELECT f.customer_id,
           EXISTS (SELECT 1 FROM valid v
                   WHERE v.customer_id = f.customer_id
                   AND   v.order_ts >  f.first_ts
                   AND   v.order_ts <= f.first_ts + interval '30 days') AS rebuy
    FROM first_buy f
) r;

-- [튜닝 1] 반복 스캔 자체를 없애는 재작성 :
--          윈도우 함수 min() OVER 로 첫 구매 시점을 같은 스캔에서 계산
-- [튜닝 2] 부분 복합 인덱스 → 유효 주문을 Index Only Scan 으로 공급
CREATE INDEX idx_orders_valid_cust ON orders(customer_id, order_ts)
    WHERE order_status IN ('paid','shipped','delivered');
ANALYZE orders;

-- [후] 단일 스캔 + 윈도우 : 비용 수백분의 1 · 실행시간 수십 배 단축
EXPLAIN (ANALYZE, BUFFERS)
SELECT round(100.0 * count(*) FILTER (WHERE rebuy) / count(*), 1) AS rebuy_rate_pct
FROM (
    SELECT customer_id,
           bool_or(order_ts > first_ts
               AND order_ts <= first_ts + interval '30 days') AS rebuy
    FROM (
        SELECT customer_id, order_ts,
               min(order_ts) OVER (PARTITION BY customer_id) AS first_ts
        FROM   orders
        WHERE  order_status IN ('paid','shipped','delivered')
    ) w GROUP BY customer_id
) r;

SELECT round(100.0 * count(*) FILTER (WHERE rebuy) / count(*), 1) AS rebuy_rate_pct
FROM (
    SELECT customer_id,
           bool_or(order_ts > first_ts
               AND order_ts <= first_ts + interval '30 days') AS rebuy
    FROM (
        SELECT customer_id, order_ts,
               min(order_ts) OVER (PARTITION BY customer_id) AS first_ts
        FROM   orders
        WHERE  order_status IN ('paid','shipped','delivered')
    ) w GROUP BY customer_id
) r;

-- =============================================================
-- Q7. 재고가 임계치보다 낮은 상품 (곧 품절 위험)
-- =============================================================

-- [전] inventory Seq Scan + 정렬
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.product_name, i.qty_on_hand, i.reorder_point
FROM   inventory i
JOIN   products p ON p.product_id = i.product_id
WHERE  i.qty_on_hand < i.reorder_point
ORDER  BY i.qty_on_hand
LIMIT  10;

-- [튜닝] 임계치 미달 행만 담는 부분 인덱스
--        → 인덱스가 qty_on_hand 정렬까지 제공(Sort 제거 + LIMIT 조기 종료)
CREATE INDEX idx_inventory_low ON inventory(qty_on_hand)
    WHERE qty_on_hand < reorder_point;
ANALYZE inventory;

-- [후] Hash Join + Sort → Nested Loop + Index Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.product_name, i.qty_on_hand, i.reorder_point
FROM   inventory i
JOIN   products p ON p.product_id = i.product_id
WHERE  i.qty_on_hand < i.reorder_point
ORDER  BY i.qty_on_hand
LIMIT  10;

SELECT p.product_name, i.qty_on_hand, i.reorder_point
FROM   inventory i
JOIN   products p ON p.product_id = i.product_id
WHERE  i.qty_on_hand < i.reorder_point
ORDER  BY i.qty_on_hand
LIMIT  10;

-- =============================================================
-- Q8. 리뷰 4.5↑ & 50개↑ 효자상품
-- =============================================================

-- [전] 조인 후 집계 — 리뷰 전체 행을 조인에 태움
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.product_name, round(avg(r.rating), 2) AS avg_rating, count(*) AS review_cnt
FROM   reviews r
JOIN   products p ON p.product_id = r.product_id
GROUP  BY p.product_id, p.product_name
HAVING avg(r.rating) >= 4.5 AND count(*) >= 50
ORDER  BY review_cnt DESC;

-- [튜닝 = 재작성] 리뷰 선집계 후 조인 — 조인 입력을 효자 소수 행으로 축소
-- [후] 조인 입력 축소로 비용 감소
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.product_name, s.avg_rating, s.review_cnt
FROM (
    SELECT product_id, round(avg(rating), 2) AS avg_rating, count(*) AS review_cnt
    FROM   reviews
    GROUP  BY product_id
    HAVING avg(rating) >= 4.5 AND count(*) >= 50
) s
JOIN   products p ON p.product_id = s.product_id
ORDER  BY s.review_cnt DESC;

SELECT p.product_name, s.avg_rating, s.review_cnt
FROM (
    SELECT product_id, round(avg(rating), 2) AS avg_rating, count(*) AS review_cnt
    FROM   reviews
    GROUP  BY product_id
    HAVING avg(rating) >= 4.5 AND count(*) >= 50
) s
JOIN   products p ON p.product_id = s.product_id
ORDER  BY s.review_cnt DESC;

-- =============================================================
-- Q9. 쿠폰 사용 영향 — 쿠폰 주문 vs 미사용 주문 AOV 비교
-- =============================================================

-- [전] count(DISTINCT) 방식 — 수백 kB 대형 Sort
EXPLAIN (ANALYZE, BUFFERS)
SELECT (o.coupon_code IS NOT NULL) AS with_coupon,
       count(DISTINCT o.order_id)  AS orders,
       round(sum(oi.line_total) / count(DISTINCT o.order_id), 2) AS aov
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
GROUP  BY 1 ORDER BY 1;

-- [튜닝 = 재작성] 주문 단위 선집계 → avg() 로 AOV 직접 계산
-- [후] 대형 Sort 제거 · 비용 감소
EXPLAIN (ANALYZE, BUFFERS)
SELECT with_coupon, count(*) AS orders, round(avg(order_rev), 2) AS aov
FROM (
    SELECT (o.coupon_code IS NOT NULL) AS with_coupon,
           o.order_id, sum(oi.line_total) AS order_rev
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    GROUP  BY 1, 2
) s GROUP BY with_coupon ORDER BY with_coupon;

SELECT with_coupon, count(*) AS orders, round(avg(order_rev), 2) AS aov
FROM (
    SELECT (o.coupon_code IS NOT NULL) AS with_coupon,
           o.order_id, sum(oi.line_total) AS order_rev
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    GROUP  BY 1, 2
) s GROUP BY with_coupon ORDER BY with_coupon;

-- =============================================================
-- Q10. 상위 1% 고객의 최근 60일 매출
-- =============================================================

-- [점검] Q1 의 부분 인덱스가 60일 조건에도 자동 재사용(Bitmap) 확인
EXPLAIN (ANALYZE, BUFFERS)
WITH cust_rev AS (
    SELECT o.customer_id, sum(oi.line_total) AS revenue
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    AND    o.order_ts >= now() - interval '60 days'
    GROUP  BY o.customer_id
),
ranked AS (
    SELECT customer_id, revenue,
           NTILE(100) OVER (ORDER BY revenue DESC) AS pct
    FROM   cust_rev
)
SELECT count(*)     AS top1pct_customers,
       sum(revenue) AS top1pct_revenue
FROM   ranked WHERE pct = 1;

-- [대조 실험] 같은 쿼리에서 Bitmap 차단 → Seq 복귀 비용 비교(인덱스 이득 정량화)
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS)
WITH cust_rev AS (
    SELECT o.customer_id, sum(oi.line_total) AS revenue
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    AND    o.order_ts >= now() - interval '60 days'
    GROUP  BY o.customer_id
),
ranked AS (
    SELECT customer_id, revenue,
           NTILE(100) OVER (ORDER BY revenue DESC) AS pct
    FROM   cust_rev
)
SELECT count(*)     AS top1pct_customers,
       sum(revenue) AS top1pct_revenue
FROM   ranked WHERE pct = 1;
RESET enable_bitmapscan;

-- 상위 1% 명단 (NTILE 1분위)
WITH cust_rev AS (
    SELECT o.customer_id, sum(oi.line_total) AS revenue
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    AND    o.order_ts >= now() - interval '60 days'
    GROUP  BY o.customer_id
),
ranked AS (
    SELECT customer_id, revenue,
           NTILE(100) OVER (ORDER BY revenue DESC) AS pct
    FROM   cust_rev
)
SELECT customer_id, revenue
FROM   ranked WHERE pct = 1
ORDER  BY revenue DESC
LIMIT  10;

-- 상위 1% 합계 요약
WITH cust_rev AS (
    SELECT o.customer_id, sum(oi.line_total) AS revenue
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    AND    o.order_ts >= now() - interval '60 days'
    GROUP  BY o.customer_id
),
ranked AS (
    SELECT customer_id, revenue,
           NTILE(100) OVER (ORDER BY revenue DESC) AS pct
    FROM   cust_rev
)
SELECT count(*)     AS top1pct_customers,
       sum(revenue) AS top1pct_revenue
FROM   ranked WHERE pct = 1;

-- =============================================================
-- Q11. 0으로 나누어도 에러 안 나는 나눗셈 — 안전한 평균 계산
-- =============================================================

-- [전] 0 나눗셈 에러 재현 : created 상태(주문상세 0건 가능) 고객 예시
--      division by zero → 트랜잭션으로 감싸 에러 확인 후 롤백
BEGIN;
DO $$
BEGIN
    PERFORM 10 / 0;
EXCEPTION WHEN division_by_zero THEN
    RAISE NOTICE '0 나눗셈 에러 재현 : division_by_zero';
END $$;
ROLLBACK;

-- [후 1] NULLIF : 분모 0 → NULL 로 치환해 나눗셈 자체를 회피
SELECT round(sum(oi.line_total) / NULLIF(count(DISTINCT o.order_id), 0), 2) AS aov_safe
FROM   orders o
LEFT   JOIN order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status = 'created'
AND    o.coupon_code IS NULL
AND    o.channel = 'marketplace'
AND    o.customer_id > 2990;      -- 일부러 좁혀 0건 유도 → NULL 반환 확인

-- [후 2] safe_div UDF : 분모 0/NULL 방어를 함수로 캡슐화
SELECT safe_div(100, 0)    AS div_by_zero,
       safe_div(100, NULL) AS div_by_null,
       safe_div(100, 4)    AS div_normal;

-- 실전 적용 : 고객별 안전 AOV (주문 0건 고객도 에러 없이 NULL)
SELECT c.customer_id, c.full_name,
       safe_div(sum(oi.line_total), count(DISTINCT o.order_id)) AS aov_safe
FROM   customers c
LEFT   JOIN orders o  ON o.customer_id = c.customer_id
                     AND o.order_status IN ('paid','shipped','delivered')
LEFT   JOIN order_items oi ON oi.order_id = o.order_id
GROUP  BY c.customer_id, c.full_name
ORDER  BY c.customer_id
LIMIT  5;

-- =============================================================
-- 재현성 검증 : 같은 쿼리 5회 반복 → 평균·표준편차 (1회 실측의 우연 배제)
-- =============================================================

-- 반복 측정 헬퍼 : EXECUTE 로 p_runs 회 실행해 통계 반환
CREATE OR REPLACE FUNCTION bench(p_label text, p_sql text, p_runs int DEFAULT 5)
RETURNS TABLE(label text, runs int, avg_ms numeric, stddev_ms numeric, min_ms numeric, max_ms numeric)
LANGUAGE plpgsql
AS $fn$
DECLARE
    t0  timestamptz;
    arr numeric[] := '{}';
    i   int;
BEGIN
    FOR i IN 1..p_runs LOOP
        t0 := clock_timestamp();
        EXECUTE p_sql;
        arr := arr || (extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric;
    END LOOP;
    RETURN QUERY SELECT p_label, p_runs,
        round((SELECT avg(v)         FROM unnest(arr) v), 2),
        round((SELECT stddev_samp(v) FROM unnest(arr) v), 2),
        round((SELECT min(v)         FROM unnest(arr) v), 2),
        round((SELECT max(v)         FROM unnest(arr) v), 2);
END $fn$;

-- 대표 문항 반복 측정 : 재작성 전/후 형태 비교 + 인덱스 경로 안정성
SELECT * FROM bench('Q1 후 (부분 인덱스 경로)', $q$
    SELECT sum(oi.line_total)
    FROM   orders o JOIN order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    AND    o.order_ts >= now() - interval '30 days' $q$)
UNION ALL
SELECT * FROM bench('Q5 전 (count DISTINCT 형태)', $q$
    SELECT o.customer_id, max(o.order_ts)::date, count(DISTINCT o.order_id), sum(oi.line_total)
    FROM   orders o JOIN order_items oi ON oi.order_id = o.order_id
    WHERE  o.order_status IN ('paid','shipped','delivered')
    GROUP  BY o.customer_id ORDER BY 4 DESC LIMIT 10 $q$)
UNION ALL
SELECT * FROM bench('Q5 후 (주문단위 선집계 형태)', $q$
    SELECT s.customer_id, max(s.order_ts)::date, count(*), sum(s.order_rev)
    FROM (SELECT o.customer_id, o.order_id, o.order_ts, sum(oi.line_total) AS order_rev
          FROM   orders o JOIN order_items oi ON oi.order_id = o.order_id
          WHERE  o.order_status IN ('paid','shipped','delivered')
          GROUP  BY o.customer_id, o.order_id, o.order_ts) s
    GROUP  BY s.customer_id ORDER BY 4 DESC LIMIT 10 $q$)
UNION ALL
SELECT * FROM bench('Q6 전 (상관 EXISTS 형태)', $q$
    WITH valid AS (SELECT customer_id, order_ts FROM orders
                   WHERE order_status IN ('paid','shipped','delivered')),
    first_buy AS (SELECT customer_id, min(order_ts) AS first_ts FROM valid GROUP BY customer_id)
    SELECT round(100.0 * count(*) FILTER (WHERE rebuy) / count(*), 1)
    FROM (SELECT f.customer_id,
                 EXISTS (SELECT 1 FROM valid v
                         WHERE v.customer_id = f.customer_id
                         AND   v.order_ts >  f.first_ts
                         AND   v.order_ts <= f.first_ts + interval '30 days') AS rebuy
          FROM first_buy f) r $q$)
UNION ALL
SELECT * FROM bench('Q6 후 (윈도우 단일 스캔 형태)', $q$
    SELECT round(100.0 * count(*) FILTER (WHERE rebuy) / count(*), 1)
    FROM (SELECT customer_id,
                 bool_or(order_ts > first_ts AND order_ts <= first_ts + interval '30 days') AS rebuy
          FROM (SELECT customer_id, order_ts,
                       min(order_ts) OVER (PARTITION BY customer_id) AS first_ts
                FROM   orders
                WHERE  order_status IN ('paid','shipped','delivered')) w
          GROUP  BY customer_id) r $q$);
