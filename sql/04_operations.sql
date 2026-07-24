-- =============================================================
-- 04_operations.sql
-- E-Commerce 분석 실습 (종합실습 4) — 운영 심화 : 함수·프로시저 · 트리거 · RLS · 모니터링
-- 작성자 : 신주용 / 광주 3반
-- 변경 이력 :
--   - 2026-07-24 최초 작성
-- =============================================================
-- 접속 대상 : psql -d ecom_db -f 04_operations.sql
-- 실행 전제 : 00_schema.sql → 01_seed.sql 완료
-- 구성 : 1) 함수(IMMUTABLE) + 주문 생성 프로시저(트랜잭션)
--        2) 트리거 — 주문 상태 감사 로그 · updated_at 자동 갱신
--        3) 행 수준 보안(RLS) — 자기 주문만 조회 (검증 후 ROLLBACK)
--        4) 모니터링 — 인덱스 사용률 · 테이블 통계 · 크기
-- =============================================================

SET search_path = ecom, public;

-- =============================================================
-- 1. 함수 · 프로시저
-- =============================================================

-- 1-1. 부가세 계산 함수 : IMMUTABLE = 같은 입력이면 항상 같은 결과(캐시·인덱스 활용 가능)
CREATE OR REPLACE FUNCTION fn_vat(amount NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT round(amount * 0.1, 2)
$$;

-- 동작 확인 : 최근 유효 주문 3건의 부가세
SELECT o.order_id, p.amount, fn_vat(p.amount) AS vat
FROM   orders o
JOIN   payments p ON p.order_id = o.order_id
WHERE  o.order_status = 'paid'
ORDER  BY o.order_id
LIMIT  3;

-- 1-2. 주문 생성 프로시저 : 재고 확인·차감 → 주문 → 상세 → 결제를 한 트랜잭션으로
--      실패(재고 부족·가격 없음) 시 전체 자동 롤백 = 부분 반영 0
CREATE OR REPLACE PROCEDURE sp_place_order(p_customer BIGINT, p_product BIGINT, p_qty INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(12,2);
    v_order BIGINT;
BEGIN
    -- 현재가 조회 (없으면 중단)
    SELECT price INTO v_price
    FROM   product_prices
    WHERE  product_id = p_product AND is_current;
    IF v_price IS NULL THEN
        RAISE EXCEPTION '현재가 없음 : 상품 %', p_product;
    END IF;

    -- 재고 차감 (부족하면 중단 — 조건부 UPDATE 로 동시성 안전)
    UPDATE inventory
    SET    qty_on_hand = qty_on_hand - p_qty
    WHERE  product_id = p_product AND qty_on_hand >= p_qty;
    IF NOT FOUND THEN
        RAISE EXCEPTION '재고 부족 : 상품 %', p_product;
    END IF;

    -- 주문 + 상세 + 결제
    INSERT INTO orders(customer_id, order_status, channel)
    VALUES (p_customer, 'paid', 'web')
    RETURNING order_id INTO v_order;

    INSERT INTO order_items(order_id, product_id, qty, unit_price)
    VALUES (v_order, p_product, p_qty, v_price);

    INSERT INTO payments(order_id, method, amount, paid_at)
    SELECT v_order, 'card', sum(line_total), now()
    FROM   order_items WHERE order_id = v_order;
END $$;

-- 동작 확인 : 호출 → 재고·주문·결제 반영 확인 → ROLLBACK (실 데이터 무변경)
BEGIN;
SELECT qty_on_hand AS stock_before FROM inventory WHERE product_id = 1;
CALL sp_place_order(1, 1, 2);
SELECT qty_on_hand AS stock_after  FROM inventory WHERE product_id = 1;
SELECT o.order_id, o.order_status, oi.qty, oi.line_total, p.amount AS paid
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
JOIN   payments p     ON p.order_id  = o.order_id
WHERE  o.customer_id = 1 AND o.channel = 'web'
ORDER  BY o.order_id DESC LIMIT 1;
ROLLBACK;

-- 재고 부족 방어 확인 : 예외 발생 → 부분 반영 없이 전체 취소
DO $$
BEGIN
    CALL sp_place_order(1, 1, 999999);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '프로시저 방어 동작 : %', SQLERRM;
END $$;

-- =============================================================
-- 2. 트리거
-- =============================================================

-- 감사 테이블·트리거 2종을 트랜잭션 안에서 구성·검증 후 ROLLBACK
--   → 실 DB 무변경 (분석 대상 14테이블 유지 · 함수 정의만 잔존)
BEGIN;

-- 2-1. 주문 상태 변경 감사 로그 : 누가 언제 무엇을 바꿨는지 자동 기록
CREATE TABLE order_status_audit (
    audit_id   BIGSERIAL   PRIMARY KEY,
    order_id   BIGINT      NOT NULL,
    old_status TEXT,
    new_status TEXT,
    changed_by TEXT        NOT NULL DEFAULT current_user,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_order_status_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.order_status IS DISTINCT FROM OLD.order_status THEN
        INSERT INTO order_status_audit(order_id, old_status, new_status)
        VALUES (OLD.order_id, OLD.order_status, NEW.order_status);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER orders_status_audit
    AFTER UPDATE OF order_status ON orders
    FOR EACH ROW EXECUTE FUNCTION trg_order_status_audit();

-- 2-2. inventory.updated_at 자동 갱신 : 응용이 잊어도 DB 가 보장(기본값 보강)
CREATE OR REPLACE FUNCTION trg_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER inventory_touch
    BEFORE UPDATE ON inventory
    FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

-- 동작 확인 : 상태 변경 → 감사 자동 기록 · 재고 수정 → updated_at 자동 갱신
UPDATE orders SET order_status = 'delivered'
WHERE  order_id = (SELECT min(order_id) FROM orders WHERE order_status = 'shipped');
SELECT order_id, old_status, new_status, changed_by
FROM   order_status_audit ORDER BY audit_id DESC LIMIT 1;

UPDATE inventory SET qty_on_hand = qty_on_hand + 1 WHERE product_id = 2;
SELECT product_id, qty_on_hand, (updated_at >= now() - interval '5 seconds') AS touched_now
FROM   inventory WHERE product_id = 2;
ROLLBACK;

-- ROLLBACK 후 원복 확인 : 감사 테이블·트리거 잔존 0 (분석 대상 14테이블 유지)
SELECT count(*) AS audit_table_remaining
FROM   pg_class WHERE relname = 'order_status_audit' AND relnamespace = 'ecom'::regnamespace;
SELECT count(*) AS trigger_remaining
FROM   pg_trigger
WHERE  tgrelid IN ('ecom.orders'::regclass, 'ecom.inventory'::regclass) AND NOT tgisinternal;

-- =============================================================
-- 3. 행 수준 보안(RLS) : 상담 롤은 지정 고객의 주문만 조회
--    트랜잭션 안에서 구성·검증 후 ROLLBACK (실 DB 무변경)
-- =============================================================

BEGIN;
CREATE ROLE cs_agent NOLOGIN;
GRANT USAGE ON SCHEMA ecom TO cs_agent;
GRANT SELECT ON orders TO cs_agent;

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_orders ON orders
    FOR SELECT TO cs_agent
    USING (customer_id = current_setting('app.customer_id')::bigint);

-- 상담 세션 : 고객 7 담당으로 전환 → 해당 고객 주문만 보임
SET LOCAL app.customer_id = '7';
SET LOCAL ROLE cs_agent;
SELECT count(*) AS visible_orders,
       min(customer_id) AS min_cust, max(customer_id) AS max_cust
FROM   orders;
RESET ROLE;
ROLLBACK;

-- ROLLBACK 후 잔존 0 확인 (롤·정책·RLS 설정 모두 원복)
SELECT count(*) AS remaining_role FROM pg_roles WHERE rolname = 'cs_agent';
SELECT relrowsecurity AS rls_enabled FROM pg_class
WHERE  oid = 'ecom.orders'::regclass;

-- =============================================================
-- 4. 모니터링 : DB 건강 점검 쿼리 (인덱스·테이블·크기)
-- =============================================================

-- 4-1. 인덱스 사용률 : 한 번도 안 쓰인 인덱스 = 제거 후보 (쓰기 비용만 유발)
SELECT relname AS table_name, indexrelname AS index_name, idx_scan
FROM   pg_stat_user_indexes
WHERE  schemaname = 'ecom'
ORDER  BY idx_scan ASC, indexrelname
LIMIT  8;

-- 4-2. 테이블 접근 통계 : Seq vs Index 스캔 비율 → 인덱스 설계 점검 지표
SELECT relname AS table_name, seq_scan, idx_scan, n_live_tup
FROM   pg_stat_user_tables
WHERE  schemaname = 'ecom'
ORDER  BY seq_scan DESC
LIMIT  6;

-- 4-3. 크기 Top 5 : 용량 증가 추세 관리 대상 식별
SELECT relname AS table_name,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM   pg_catalog.pg_statio_user_tables
WHERE  schemaname = 'ecom'
ORDER  BY pg_total_relation_size(relid) DESC
LIMIT  5;
