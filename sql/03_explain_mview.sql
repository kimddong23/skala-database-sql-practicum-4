-- =============================================================
-- 03_explain_mview.sql
-- E-Commerce 분석 실습 (종합실습 4) — 실행계획 개선 + Materialized View
-- 작성자 : 신주용 / 광주 3반
-- 작성일 : 2026-07-21
-- 변경 이력 :
--   2026-07-21 최초 작성
-- =============================================================
-- 접속 대상 : psql -d ecom_db -f 03_explain_mview.sql
-- =============================================================

-- =============================================================
-- [1] 병목 쿼리 EXPLAIN ANALYZE — 인덱스 추가 전
-- =============================================================
-- 월별 GMV 리포트 : orders × order_items 조인 + 날짜 범위 필터
-- 데이터 규모가 커질수록 Seq Scan → 큰 비용 발생 예상
-- =============================================================
\echo '=== [Before] 인덱스 추가 전 실행계획 ==='

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    DATE_TRUNC('month', o.order_date)::DATE  AS order_month,
    COUNT(DISTINCT o.order_id)               AS order_cnt,
    SUM(oi.qty * oi.unit_price)              AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status    IN ('paid', 'shipped', 'delivered')
  AND o.order_date >= NOW() - INTERVAL '90 days'
GROUP BY DATE_TRUNC('month', o.order_date)
ORDER BY order_month;


-- =============================================================
-- [2] 복합 인덱스 추가 (status + order_date 복합 → 필터 가속)
-- =============================================================
-- status IN (...) 필터 + order_date 범위 검색을 한 인덱스로 처리
-- 파셜 인덱스 : 유효 거래만 대상으로 크기 최소화
-- =============================================================
\echo '=== 인덱스 추가 ==='

-- 유효 거래 필터 + 날짜 범위에 최적화된 복합 인덱스
CREATE INDEX IF NOT EXISTS idx_orders_status_date
    ON orders(status, order_date DESC)
    WHERE status IN ('paid', 'shipped', 'delivered');

-- order_items 조인 키 + qty*unit_price 커버링 인덱스
CREATE INDEX IF NOT EXISTS idx_items_orderid_covering
    ON order_items(order_id)
    INCLUDE (qty, unit_price);

-- 참고 : 플래너는 비용 기반 선택 → 현재 seed 규모(주문 수천 건)에서는
--        Seq Scan 이 더 싸 인덱스가 선택되지 않을 수 있음
--        데이터가 수십만 건 이상으로 커질수록 인덱스 이득이 커짐


-- =============================================================
-- [3] EXPLAIN ANALYZE — 인덱스 추가 후 재측정
-- =============================================================
\echo '=== [After] 인덱스 추가 후 실행계획 ==='

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    DATE_TRUNC('month', o.order_date)::DATE  AS order_month,
    COUNT(DISTINCT o.order_id)               AS order_cnt,
    SUM(oi.qty * oi.unit_price)              AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status    IN ('paid', 'shipped', 'delivered')
  AND o.order_date >= NOW() - INTERVAL '90 days'
GROUP BY DATE_TRUNC('month', o.order_date)
ORDER BY order_month;


-- =============================================================
-- [3-2] Join 전략 비교 — Hash Join vs Nested Loop
-- =============================================================
-- 플래너는 통계·비용으로 조인 방식을 자동 선택
--   · Hash Join   : 대량 × 대량 조인에 유리(해시 테이블 구축 후 탐색)
--   · Nested Loop : 한쪽이 소량 + 인덱스 있을 때 유리(행별 반복 탐색)
--   · Bitmap Heap Scan : 중간 선택도 필터에서 인덱스→힙 접근 결합
-- enable_* 토글로 강제해 실행계획·시간 차이를 관찰
-- =============================================================
\echo '=== [Join] 기본 — 플래너 자동 선택 ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT o.order_id, oi.qty
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'paid';

\echo '=== [Join] Nested Loop 강제 (Hash/Merge 비활성) ==='
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN (ANALYZE, COSTS OFF)
SELECT o.order_id, oi.qty
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'paid';
RESET enable_hashjoin;
RESET enable_mergejoin;
-- 관찰 : 기본은 Hash Join(대량 조인 효율), 강제 시 Nested Loop 로 전환 →
--        대량 데이터에서는 반복 탐색으로 실행시간 증가

-- =============================================================
-- [4] Materialized View : mv_daily_gmv (일자별 총 판매금액)
-- =============================================================
-- 목적 : 일 단위 GMV 집계를 미리 구체화해 리포트 쿼리 응답 가속
-- 갱신 주기 전략 :
--   - REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_gmv;
--     → CONCURRENTLY 옵션 : 뷰 조회를 블로킹하지 않고 갱신 가능
--     → 단, UNIQUE INDEX 가 반드시 존재해야 CONCURRENTLY 사용 가능
--   - 권장 갱신 시점 : 매일 오후 3시 (업무시간 외 트래픽 감소 구간)
--     cron 예시 (crontab -e) :
--       0 15 * * * psql -d ecom_db -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_gmv;"
--   - pg_cron 사용 시 :
--       SELECT cron.schedule('daily-gmv-refresh', '0 15 * * *',
--         $$REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_gmv;$$);
-- =============================================================
\echo '=== Materialized View 생성 ==='

DROP MATERIALIZED VIEW IF EXISTS mv_daily_gmv;

CREATE MATERIALIZED VIEW mv_daily_gmv AS
SELECT
    o.order_date::DATE                AS order_day,
    o.channel,
    COUNT(DISTINCT o.order_id)        AS order_cnt,
    SUM(oi.qty * oi.unit_price)       AS daily_revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('paid', 'shipped', 'delivered')
GROUP BY o.order_date::DATE, o.channel
ORDER BY order_day, channel;

-- CONCURRENTLY REFRESH 를 위한 UNIQUE INDEX (order_day + channel 복합 유일)
CREATE UNIQUE INDEX uix_mv_daily_gmv_day_channel
    ON mv_daily_gmv(order_day, channel);


-- =============================================================
-- [5] Materialized View 조회 결과 확인
-- =============================================================
\echo '=== mv_daily_gmv 최근 7일 조회 ==='

SELECT order_day, channel, order_cnt, daily_revenue
FROM mv_daily_gmv
WHERE order_day >= CURRENT_DATE - 7
ORDER BY order_day DESC, channel
LIMIT 20;

\echo '=== mv_daily_gmv 전체 행수 ==='
SELECT COUNT(*) AS total_rows FROM mv_daily_gmv;

-- =============================================================
-- [6] REFRESH 예시 (실행 시점 즉시 갱신 시뮬레이션)
-- =============================================================
\echo '=== REFRESH MATERIALIZED VIEW CONCURRENTLY ==='

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_gmv;

\echo '=== REFRESH 완료 — mv_daily_gmv 최신 상태 ==='

SELECT
    MIN(order_day) AS earliest_day,
    MAX(order_day) AS latest_day,
    COUNT(*)        AS total_rows,
    SUM(daily_revenue) AS total_gmv
FROM mv_daily_gmv;
