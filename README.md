# 종합실습 4 · E-Commerce 매출 분석

전자상거래 스키마에서 매출·고객·재고를 분석하고 실행계획을 개선한 실습.

- 작성자 : 광주 3반 신주용
- 작성일 : 2026-07-21
- GitHub : https://github.com/kimddong23/skala-database-sql-practicum-4
- 주제 : **매출 분석 쿼리 + 실행계획 개선 + Materialized View**
- DB : `ecom_db (9테이블)` · PostgreSQL 17

## 개요
- 스키마 : categories(계층)·products·product_prices(가격이력)·inventory·customers·coupons·orders·order_items·reviews
- 분석 : GMV·월별매출·AOV·카테고리 Top10·RFM·재구매율·재고임계·쿠폰효과·상위1% 고객
- 성능 : EXPLAIN Before/After · Hash Join vs Nested Loop · Materialized View(mv_daily_gmv)

## 코드 구조
```
Day4_종합실습4_ecommerce/
├── sql/                     # SQL 스크립트
│   ├── 00_schema.sql        # 스키마 (ecom_db · 9테이블)
│   ├── 01_seed.sql          # 데이터 적재
│   ├── 02_queries.sql       # Q1~Q11 매출 분석
│   ├── 03_explain_mview.sql # 실행계획 비교 + mview
├── erd/                     # ERD 도식(png·html)
├── docs/                    # 리포트 PDF · pdf_pages(페이지 미리보기)
└── README.md · .gitignore
```

## 실행 방법
```bash
psql -d postgres -f sql/00_schema.sql
psql -d ecom_db -f sql/01_seed.sql
psql -d ecom_db -f sql/02_queries.sql
psql -d ecom_db -f sql/03_explain_mview.sql
```

## 문항 (02_queries.sql)
- Q1 GMV·Q2 월별매출/AOV·Q3 카테고리 Top10·Q4 제품 누적매출 RANK·Q5 RFM·Q6 재구매율
- Q7 재고임계·Q8 효자상품·Q9 쿠폰효과·Q10 상위1%·Q11 NULLIF 0-나눗셈 방어

## 분석 리포트
제출 리포트 [`docs/광주_3반_신주용_종합실습4_리포트.pdf`](docs/광주_3반_신주용_종합실습4_리포트.pdf) 전체 페이지 미리보기.

![리포트 p1](docs/pdf_pages/page-01.png)
![리포트 p2](docs/pdf_pages/page-02.png)
![리포트 p3](docs/pdf_pages/page-03.png)
![리포트 p4](docs/pdf_pages/page-04.png)
![리포트 p5](docs/pdf_pages/page-05.png)
![리포트 p6](docs/pdf_pages/page-06.png)
![리포트 p7](docs/pdf_pages/page-07.png)
![리포트 p8](docs/pdf_pages/page-08.png)
![리포트 p9](docs/pdf_pages/page-09.png)
![리포트 p10](docs/pdf_pages/page-10.png)
![리포트 p11](docs/pdf_pages/page-11.png)
![리포트 p12](docs/pdf_pages/page-12.png)
![리포트 p13](docs/pdf_pages/page-13.png)
![리포트 p14](docs/pdf_pages/page-14.png)
![리포트 p15](docs/pdf_pages/page-15.png)
![리포트 p16](docs/pdf_pages/page-16.png)
![리포트 p17](docs/pdf_pages/page-17.png)
![리포트 p18](docs/pdf_pages/page-18.png)
![리포트 p19](docs/pdf_pages/page-19.png)
![리포트 p20](docs/pdf_pages/page-20.png)

## 설계·간결화 방법
- 집계는 CTE·윈도우로 단계화, NULLIF 로 0-나눗셈 방어
- 병목을 EXPLAIN 으로 파악 → 파셜·커버링 인덱스로 개선, Join 전략 비교
- 반복 집계는 Materialized View(mv_daily_gmv)로 캐시, CONCURRENTLY 갱신 설계

## 변경 이력
- 2026-07-21 최초 작성