-- =============================================================
-- 03_explain_mview.sql
-- E-Commerce 분석 실습 (종합실습 4) — 조인 3종 비교 + Materialized View
-- 작성자 : 신주용 / 광주 3반
-- 변경 이력 :
--   - 2026-07-21 최초 작성
--   - 2026-07-24 실습 제공 스키마(ecom) 기준 전면 재구성
-- =============================================================
-- 접속 대상 : psql -d ecom_db -f 03_explain_mview.sql
-- 실행 전제 : 00_schema.sql → 01_seed.sql (→ 02_queries.sql) 완료
-- 구성 : 1) 조인 3종(NLJ·Hash·Merge) 차이 비교
--        2) Materialized View 가속 · 갱신 전략(오후 3시 기준)
-- =============================================================

SET search_path = ecom, public;

-- =============================================================
-- 1. 조인 3종 비교 — 같은 데이터, 상황별로 다른 조인이 최적
-- =============================================================

-- -------------------------------------------------------------
-- 1-1. Nested Loop Join (NLJ) : 한쪽이 소량 + 상대편에 인덱스
--      바깥 행마다 안쪽을 인덱스로 콕 집어 조회 → 단건·소량 최강
-- -------------------------------------------------------------
EXPLAIN (ANALYZE)
SELECT o.order_id, o.order_ts, oi.product_id, oi.qty, oi.line_total
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_id = 1000;

-- -------------------------------------------------------------
-- 1-2. Hash Join : 대량 × 대량 등가 조인
--      작은 쪽으로 해시테이블 생성 → 큰 쪽을 흘려보내며 매칭
--      정렬·인덱스 불필요, 대량 배치 집계의 기본기
-- -------------------------------------------------------------
EXPLAIN (ANALYZE)
SELECT o.order_status, count(oi.order_item_id) AS items
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
GROUP  BY o.order_status ORDER BY o.order_status;

-- -------------------------------------------------------------
-- 1-3. Merge Join : 양쪽을 조인키 순으로 정렬해 지퍼처럼 병합
--      이미 정렬돼 있으면(인덱스·PK) 최적, 아니면 Sort 비용 추가
--      플래너 강제 스위치로 유도(시연용) 후 원복
-- -------------------------------------------------------------
SET enable_hashjoin = off;
SET enable_nestloop = off;
EXPLAIN (ANALYZE)
SELECT o.order_status, count(oi.order_item_id) AS items
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
GROUP  BY o.order_status ORDER BY o.order_status;
RESET enable_hashjoin;
RESET enable_nestloop;

-- -------------------------------------------------------------
-- 1-4. (참고) 인덱스 접근 경로 2종 — 같은 부분 인덱스라도
--      count(*) 처럼 인덱스만으로 답이 나오면 Index Only Scan(히프 방문 0),
--      테이블 컬럼까지 읽으면 Bitmap Heap Scan(블록 지도 일괄 방문 — Q1·Q10)
-- -------------------------------------------------------------
EXPLAIN (ANALYZE)
SELECT count(*)
FROM   orders
WHERE  order_status IN ('paid','shipped','delivered')
AND    order_ts >= now() - interval '30 days';

-- =============================================================
-- 2. Materialized View — 리포트 쿼리 가속 + 갱신 전략
-- =============================================================

-- -------------------------------------------------------------
-- 2-1. 가속 비교 : 원본 조인 집계 vs MView 조회
--      매일 GMV 리포트를 매번 JOIN+SUM 하면 느림 → 미리 구체화
-- -------------------------------------------------------------

-- [전] 원본 : orders × order_items 조인 후 일 단위 집계
EXPLAIN (ANALYZE)
SELECT date_trunc('day', o.order_ts)::date AS day, sum(oi.line_total) AS gmv
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
WHERE  o.order_status IN ('paid','shipped','delivered')
GROUP  BY 1 ORDER BY 1 DESC LIMIT 7;

-- [후] MView : 이미 집계된 결과를 바로 읽음 (00_schema 에서 생성)
EXPLAIN (ANALYZE)
SELECT day::date AS day, gmv
FROM   mv_daily_gmv
ORDER  BY day DESC LIMIT 7;

SELECT day::date AS day, gmv
FROM   mv_daily_gmv
ORDER  BY day DESC LIMIT 7;

-- -------------------------------------------------------------
-- 2-2. 갱신(REFRESH) — MView 는 자동 갱신되지 않음
-- -------------------------------------------------------------

-- 기본 갱신 : 갱신 중 조회 잠금 발생(짧은 리포트 창엔 무방)
REFRESH MATERIALIZED VIEW mv_daily_gmv;

-- 동시 갱신(CONCURRENTLY) : 조회 차단 없이 갱신 — UNIQUE 인덱스 필수
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_daily_gmv_day ON mv_daily_gmv(day);
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_gmv;

-- 갱신 확인 : 최신 7일 GMV
SELECT day::date AS day, gmv
FROM   mv_daily_gmv
ORDER  BY day DESC LIMIT 7;

-- -------------------------------------------------------------
-- 2-3. 갱신 주기 설계 — 오후 3시 기준
--      주문 데이터는 하루 종일 쌓이고, 일 마감 리포트는 오후에 소비
--      → 매일 15:00 1회 CONCURRENTLY 갱신으로 설계
--        (조회 무중단 + 리포트 소비 시점 직전 최신화)
--      crontab 등록 예 :
--        0 15 * * *  psql -d ecom_db -c "REFRESH MATERIALIZED VIEW CONCURRENTLY ecom.mv_daily_gmv;"
--      데이터 변경이 잦아지면 주기를 좁히되(예: 매시), 갱신 비용과
--      최신성 요구를 저울질해 결정
-- -------------------------------------------------------------
