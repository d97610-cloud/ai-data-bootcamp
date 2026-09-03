# D+34 [과제] Amazon 판매 데이터로 추천 시스템 설계하기

생성일: 2026년 9월 3일 오전 4:31
최종 편집 일시: 2026년 9월 3일 오전 11:20
작성자: 지선호
상태: 완료

####

---

# 데이터 준비 — 0

- Amazon 데이터셋은 `discounted_price`(₹399.00), `actual_price`(₹1,099), `rating_count`(24,269)처럼 **숫자에 기호가 섞인 텍스트**라서, 계산·정렬을 하려면 먼저 숫자형으로 바꿔야 함.
- `rating` 컬럼에 `|` 로 적힌 행이 1개 있어서 `CAST` 대신 **`SAFE_CAST`** 사용. 실패한 값은 NULL이 됨.
- 원본은 1,465행인데 `product_id` 기준으로는 **1,351개**. 같은 상품이 여러 카테고리 경로에 중복 등재된 것이라, `product_id`별로 **리뷰 수가 가장 많은 행 1개만** 대표로 남김. 컬럼마다 따로 `ANY_VALUE`를 쓰면 한 상품의 속성이 서로 다른 행에서 섞일 수 있어서 `ROW_NUMBER()` 방식을 택함.
- `user_id` 한 셀에는 리뷰어가 쉼표로 최대 8명까지 들어 있어서, `UNNEST(SPLIT(...))`으로 **(리뷰어 1명 ↔ 상품 1개)** 관계 테이블을 따로 만듦. 결과는 관계 10,604건 / 리뷰어 9,050명.

```jsx
CREATE OR REPLACE VIEW `project_id.dataset_id.v_product` AS
WITH cleaned AS (
  SELECT
    product_id,
    product_name,
    category,
    SPLIT(category, '|')[SAFE_OFFSET(0)] AS cat_l1,
    SPLIT(category, '|')[SAFE_OFFSET(1)] AS cat_l2,
    ARRAY_REVERSE(SPLIT(category, '|'))[SAFE_OFFSET(0)] AS cat_leaf,
    SAFE_CAST(REGEXP_REPLACE(discounted_price, r'[^0-9.]', '') AS FLOAT64) AS price,
    SAFE_CAST(REGEXP_REPLACE(actual_price, r'[^0-9.]', '') AS FLOAT64) AS list_price,
    SAFE_CAST(rating AS FLOAT64) AS rating,
    SAFE_CAST(REGEXP_REPLACE(rating_count, r'[^0-9]', '') AS INT64) AS rating_cnt
  FROM `project_id.dataset_id.amazon`
),
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY product_id
      ORDER BY rating_cnt DESC, product_name, category
    ) AS row_num
  FROM cleaned
)
SELECT * EXCEPT (row_num)
FROM ranked
WHERE row_num = 1;

CREATE OR REPLACE VIEW `project_id.dataset_id.v_user_product` AS
SELECT DISTINCT
  TRIM(user_id_value) AS user_id,
  product_id
FROM `project_id.dataset_id.amazon` AS a,
     UNNEST(SPLIT(a.user_id, ',')) AS user_id_value
WHERE TRIM(user_id_value) != '';
```

---

# 추천 시스템 — 1

**1. 추천 시스템 이름**  
➜ **"중복 옵션을 정리한 연관 상품 추천"**

**2. 추천 시스템의 테마: 추천 시스템의 고유 컨셉에 대한 설명**  
➜ "이 상품을 본 사람이 함께 본 상품"을 만들려면 리뷰어가 겹치는 상품을 찾으면 됩니다. 그런데 이 데이터에서 리뷰어가 겹치는 상품쌍을 그대로 쓰면, **같은 상품의 색상·용량·케이블 규격만 다른 등록건**이 대부분을 차지합니다. 이걸 걸러내지 않으면 연관 상품 영역이 방금 본 상품의 다른 옵션으로 채워집니다.  
➜ 그래서 **중복 옵션으로 보이는 상품들을 먼저 하나의 상품군으로 묶고**, 상품군 사이에서 실제로 리뷰어가 겹치는 **다른 카테고리** 상품을 추천합니다.

**3. 구현 로직: SQL 쿼리 설명 및 주요 로직 설명**  
➜ ① 리뷰어를 공유하는 상품쌍마다 **자카드 유사도** 계산 — `공통 리뷰어 ÷ (A리뷰어 + B리뷰어 − 공통 리뷰어)`  
➜ ② 자카드 **0.5 이상**이면 같은 상품의 옵션 관계로 판단  
➜ ③ 연결된 상품을 하나의 상품군으로 묶고, 리뷰 수가 가장 많은 상품을 대표로 선택  
➜ ④ 리뷰어–상품 관계를 **리뷰어–상품군 관계로 다시 집계**한 뒤 상품군쌍의 자카드를 계산  
➜ ⑤ 같은 세부 카테고리 밖에서 연관도가 높은 상품군만 추천

```jsx
CREATE OR REPLACE VIEW `project_id.dataset_id.v_pair` AS
WITH product_reviewer_count AS (
  SELECT product_id, COUNT(DISTINCT user_id) AS reviewer_cnt
  FROM `project_id.dataset_id.v_user_product`
  GROUP BY product_id
),
co_review AS (
  SELECT
    a.product_id AS product_a,
    b.product_id AS product_b,
    COUNT(*) AS common_reviewer_cnt
  FROM `project_id.dataset_id.v_user_product` AS a
  JOIN `project_id.dataset_id.v_user_product` AS b
    ON a.user_id = b.user_id
   AND a.product_id < b.product_id
  GROUP BY product_a, product_b
)
SELECT
  c.product_a,
  c.product_b,
  c.common_reviewer_cnt,
  a.reviewer_cnt AS reviewer_cnt_a,
  b.reviewer_cnt AS reviewer_cnt_b,
  SAFE_DIVIDE(
    c.common_reviewer_cnt,
    a.reviewer_cnt + b.reviewer_cnt - c.common_reviewer_cnt
  ) AS jaccard
FROM co_review AS c
JOIN product_reviewer_count AS a ON a.product_id = c.product_a
JOIN product_reviewer_count AS b ON b.product_id = c.product_b;

CREATE OR REPLACE VIEW `project_id.dataset_id.v_variant_cluster` AS
WITH variant_edge AS (
  SELECT product_a AS product_id, product_b AS connected_product_id
  FROM `project_id.dataset_id.v_pair`
  WHERE jaccard >= 0.5

  UNION ALL

  SELECT product_b AS product_id, product_a AS connected_product_id
  FROM `project_id.dataset_id.v_pair`
  WHERE jaccard >= 0.5
)
SELECT
  p.product_id,
  LEAST(
    p.product_id,
    IFNULL(MIN(e.connected_product_id), p.product_id)
  ) AS cluster_id
FROM `project_id.dataset_id.v_product` AS p
LEFT JOIN variant_edge AS e USING (product_id)
GROUP BY p.product_id;

CREATE OR REPLACE VIEW `project_id.dataset_id.v_rep` AS
SELECT p.*, c.cluster_id
FROM `project_id.dataset_id.v_product` AS p
JOIN `project_id.dataset_id.v_variant_cluster` AS c USING (product_id)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY c.cluster_id
  ORDER BY p.rating_cnt DESC, p.product_id
) = 1;

CREATE OR REPLACE VIEW `project_id.dataset_id.v_user_cluster` AS
SELECT DISTINCT
  up.user_id,
  c.cluster_id
FROM `project_id.dataset_id.v_user_product` AS up
JOIN `project_id.dataset_id.v_variant_cluster` AS c USING (product_id);

CREATE OR REPLACE VIEW `project_id.dataset_id.v_cluster_pair` AS
WITH cluster_reviewer_count AS (
  SELECT cluster_id, COUNT(DISTINCT user_id) AS reviewer_cnt
  FROM `project_id.dataset_id.v_user_cluster`
  GROUP BY cluster_id
),
co_review AS (
  SELECT
    a.cluster_id AS cluster_a,
    b.cluster_id AS cluster_b,
    COUNT(*) AS common_reviewer_cnt
  FROM `project_id.dataset_id.v_user_cluster` AS a
  JOIN `project_id.dataset_id.v_user_cluster` AS b
    ON a.user_id = b.user_id
   AND a.cluster_id < b.cluster_id
  GROUP BY cluster_a, cluster_b
)
SELECT
  c.cluster_a,
  c.cluster_b,
  c.common_reviewer_cnt,
  a.reviewer_cnt AS reviewer_cnt_a,
  b.reviewer_cnt AS reviewer_cnt_b,
  SAFE_DIVIDE(
    c.common_reviewer_cnt,
    a.reviewer_cnt + b.reviewer_cnt - c.common_reviewer_cnt
  ) AS jaccard
FROM co_review AS c
JOIN cluster_reviewer_count AS a ON a.cluster_id = c.cluster_a
JOIN cluster_reviewer_count AS b ON b.cluster_id = c.cluster_b;

SELECT
  a.product_name AS 기준상품,
  a.cat_leaf AS 기준카테고리,
  b.product_name AS 추천상품,
  b.cat_leaf AS 추천카테고리,
  p.common_reviewer_cnt AS 공통리뷰어수,
  ROUND(p.jaccard, 3) AS 연관도_자카드
FROM `project_id.dataset_id.v_cluster_pair` AS p
JOIN `project_id.dataset_id.v_rep` AS a ON a.cluster_id = p.cluster_a
JOIN `project_id.dataset_id.v_rep` AS b ON b.cluster_id = p.cluster_b
WHERE a.cat_leaf != b.cat_leaf
ORDER BY 공통리뷰어수 DESC, 연관도_자카드 DESC
LIMIT 100;
```

**4. 결과**:

*(빅쿼리 실행 화면 캡처)*

자카드 분포가 **0.5 이상 305쌍 / 0.25 미만 347쌍**으로 뚜렷하게 갈렸습니다. 그 사이 구간에는 상품쌍이 하나도 없어서, 옵션 관계인지 아닌지가 데이터 안에서 깔끔하게 나뉩니다. 0.5 이상 305쌍이 전체 동시 리뷰 2,752건 중 **2,405건(87%)** 을 차지했습니다.

| 상품군 크기 | 상품군 개수 | 대표 사례 |
|---|---|---|
| 8개 | 2 | Samsung Galaxy M13 색상 6종 + M13 5G 2종 · FLiX 케이블 8종 |
| 6개 | 2 | iQOO Z6 44W 색상·용량 6종 · Wayona 라이트닝 케이블 6종 |
| 5개 | 4 | Fire-Boltt Ninja Call Pro Plus 등 |
| 2~4개 | 89 | 대부분 색상 변형 또는 케이블 길이 변형 |

정리하면 **97개 상품군에 267개 상품**이 묶였고, 1,351개 상품이 1,181개 상품군이 됐습니다.

| 기준상품 | 기준카테고리 | 추천상품 | 추천카테고리 | 공통리뷰어수 | 연관도(자카드) |
|---|---|---|---|---|---|
| SanDisk Ultra Dual 64 GB USB 3.0 OTG P | PenDrives | Sennheiser CX 80S in-Ear Wired Headpho | In-Ear | 1 | 0.111 |
| Zebronics, ZEB-NC3300 USB Powered Lapt | CoolingPads | ECOVACS DEEBOT N8 2-in-1 Robotic Vacuu | RoboticVacuums | 1 | 0.111 |
| AmazonBasics Micro USB Fast Charging C | USBCables | Sennheiser CX 80S in-Ear Wired Headpho | In-Ear | 1 | 0.111 |
| Philips GC1905 1440-Watt Steam Iron wi | SteamIrons | Sennheiser CX 80S in-Ear Wired Headpho | In-Ear | 1 | 0.111 |
| Sennheiser CX 80S in-Ear Wired Headpho | In-Ear | Mi 108 cm (43 inches) Full HD Android  | SmartTelevisions | 1 | 0.111 |
| Boya ByM1 Auxiliary Omnidirectional La | Condenser | Sennheiser CX 80S in-Ear Wired Headpho | In-Ear | 1 | 0.111 |

다만 옵션을 접고 나면 남는 신호가 얇아집니다. 상품군쌍 238개 중 **공통 리뷰어가 2명 이상인 쌍은 없습니다.** 그래서 이 추천은 "확실한 연관"이라기보다 후보 발굴용이고, 신호를 더 두껍게 쓰려면 다음 추천 시스템처럼 **분석 단위를 카테고리로 올려야** 합니다.

---

# 추천 시스템 — 2

**1. 추천 시스템 이름**  
➜ **"같은 고객이 함께 관심을 보인 카테고리 추천"**

**2. 추천 시스템의 테마: 추천 시스템의 고유 컨셉에 대한 설명**  
➜ 상품 단위로는 같은 리뷰어가 반복 등장하는 사례가 적어 근거가 희박합니다. 그래서 **분석 단위를 상품에서 2단계 카테고리로 넓힙니다.** 기준 카테고리에 리뷰를 남긴 사람 중 다른 카테고리에도 리뷰를 남긴 비율을 계산해, 함께 관심을 보일 가능성이 높은 카테고리를 추천합니다.  
➜ 상품 상세 페이지 하단이나 카테고리 페이지의 **"함께 둘러보기" 슬롯 편성 우선순위**로 바로 쓸 수 있는 형태입니다.  
➜ 다만 이 데이터에는 **리뷰 작성 시점이 없습니다.** 따라서 결과는 "다음에 이동한 카테고리"가 아니라, 같은 리뷰어 안에서 확인된 **교차 관심 관계**로만 읽어야 합니다.

**3. 구현 로직: SQL 쿼리 설명 및 주요 로직 설명**  
➜ ① 리뷰어별로 리뷰를 남긴 2단계 카테고리 목록을 만듦  
➜ ② **두 개 이상 카테고리에 등장한 리뷰어 148명**만 남김  
➜ ③ 기준 카테고리와 연관 카테고리의 공통 리뷰어 수를 계산  
➜ ④ 공통 리뷰어 수를 **기준 카테고리 리뷰어 수로 나눠** 교차관심률을 구함 (행 기준 정규화)  
➜ ⑤ 기준 카테고리 리뷰어가 **8명 미만이면 표본이 작다고 보고 제외**

```jsx
WITH user_category AS (
  SELECT DISTINCT
    up.user_id,
    p.cat_l2 AS category
  FROM `project_id.dataset_id.v_user_product` AS up
  JOIN `project_id.dataset_id.v_product` AS p USING (product_id)
  WHERE p.cat_l2 IS NOT NULL
),
multi_category_user AS (
  SELECT user_id
  FROM user_category
  GROUP BY user_id
  HAVING COUNT(*) >= 2
),
eligible_user_category AS (
  SELECT uc.*
  FROM user_category AS uc
  JOIN multi_category_user USING (user_id)
),
base_category_size AS (
  SELECT category, COUNT(*) AS reviewer_cnt
  FROM eligible_user_category
  GROUP BY category
),
category_affinity AS (
  SELECT
    a.category AS base_category,
    b.category AS related_category,
    COUNT(*) AS common_reviewer_cnt
  FROM eligible_user_category AS a
  JOIN eligible_user_category AS b
    ON a.user_id = b.user_id
   AND a.category != b.category
  GROUP BY base_category, related_category
)
SELECT
  a.base_category AS 기준_카테고리,
  a.related_category AS 함께_관심을_보인_카테고리,
  a.common_reviewer_cnt AS 공통리뷰어수,
  n.reviewer_cnt AS 기준카테고리_리뷰어수,
  ROUND(100 * SAFE_DIVIDE(a.common_reviewer_cnt, n.reviewer_cnt), 1) AS 교차관심률_pct
FROM category_affinity AS a
JOIN base_category_size AS n ON n.category = a.base_category
WHERE n.reviewer_cnt >= 8
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY a.base_category
  ORDER BY a.common_reviewer_cnt DESC
) <= 3
ORDER BY 기준카테고리_리뷰어수 DESC, 교차관심률_pct DESC;
```

**4. 결과**:

*(빅쿼리 실행 화면 캡처)*

| 기준 카테고리 | 함께 관심을 보인 카테고리 | 공통리뷰어수 | 기준카테고리 리뷰어수 | 교차관심률(%) |
|---|---|---|---|---|
| 컴퓨터 액세서리 | 모바일 액세서리 | 27 | 75 | 36.0 |
| 컴퓨터 액세서리 | 주방가전 | 13 | 75 | 17.3 |
| 컴퓨터 액세서리 | 헤드폰·이어폰 | 7 | 75 | 9.3 |
| 모바일 액세서리 | 컴퓨터 액세서리 | 27 | 46 | 58.7 |
| 모바일 액세서리 | 주방가전 | 8 | 46 | 17.4 |
| 모바일 액세서리 | 홈시어터·TV | 4 | 46 | 8.7 |
| 주방가전 | 컴퓨터 액세서리 | 13 | 44 | 29.5 |
| 주방가전 | 모바일 액세서리 | 8 | 44 | 18.2 |
| 주방가전 | 냉난방·공기 | 8 | 44 | 18.2 |
| 홈시어터·TV | 주방가전 | 5 | 23 | 21.7 |
| 홈시어터·TV | 컴퓨터 액세서리 | 4 | 23 | 17.4 |
| 홈시어터·TV | 모바일 액세서리 | 4 | 23 | 17.4 |
| 냉난방·공기 | 주방가전 | 8 | 21 | 38.1 |
| 냉난방·공기 | 컴퓨터 액세서리 | 4 | 21 | 19.0 |
| 냉난방·공기 | 웨어러블 | 2 | 21 | 9.5 |
| 헤드폰·이어폰 | 컴퓨터 액세서리 | 7 | 15 | 46.7 |
| 헤드폰·이어폰 | 웨어러블 | 2 | 15 | 13.3 |
| 헤드폰·이어폰 | 주방가전 | 2 | 15 | 13.3 |

두 개의 덩어리가 보입니다. **전자기기 축**(모바일·헤드폰·카메라)은 예외 없이 컴퓨터 액세서리로 수렴하고, **생활가전 축**(주방·냉난방·홈시어터)은 자기들끼리 순환합니다.  
컴퓨터 액세서리는 두 덩어리 모두에서 상위에 등장하는 유일한 카테고리라, **전 카테고리 공통 크로스셀 슬롯의 기본값**으로 쓸 수 있습니다.  
기준 카테고리별 리뷰어가 8~75명이므로, 각 행의 **상위 1~2개까지만** 편성 근거로 쓰고 그 아래는 참고값으로 두는 것이 안전합니다.

---

# 추천 시스템 — 3

**1. 추천 시스템 이름**  
➜ **"과도한 정가를 걸러낸 실질 할인 상품 추천"**

**2. 추천 시스템의 테마: 추천 시스템의 고유 컨셉에 대한 설명**  
➜ `discount_percentage`는 판매자가 스스로 적은 `actual_price`에서 계산됩니다. **정가를 높게 적으면 할인율은 얼마든지 커집니다.**  
➜ 그래서 할인율로 정렬하기 **전에**, 같은 세부 카테고리의 정가 중앙값과 비교해 **정가가 지나치게 높은 상품을 먼저 후보에서 뺍니다.** 사용자에게 보여주는 정렬 기준은 그대로 표기 할인율이고, 바뀌는 것은 후보 풀입니다.  
➜ 이 필터는 허위 정가를 확정하는 판정이 아니라 **정가 이상치를 걸러내는 휴리스틱**입니다. 브랜드·사양 차이로 정가가 실제로 높을 수도 있습니다.

**3. 구현 로직: SQL 쿼리 설명 및 주요 로직 설명**  
➜ ① 동일 옵션 상품을 대표 상품 하나로 정리 (추천 1의 `v_rep` 재사용)  
➜ ② **리뷰 수 500건 이상**만 남겨 평점의 최소 신뢰도 확보  
➜ ③ 세부 카테고리별 표시 정가 중앙값 계산 — BigQuery에는 `MEDIAN`이 없어서 **`APPROX_QUANTILES(list_price, 2)[OFFSET(1)]`** 사용  
➜ ④ 상품 정가 ÷ 카테고리 정가 중앙값 = **정가 배율**. **1.2배 이하만 통과**  
➜ ⑤ 표본 10개 미만 카테고리는 중앙값이 불안정해서 제외

```jsx
WITH candidate_product AS (
  SELECT *
  FROM `project_id.dataset_id.v_rep`
  WHERE price IS NOT NULL
    AND list_price > 0
    AND rating IS NOT NULL
    AND rating_cnt >= 500
),
category_price_benchmark AS (
  SELECT
    cat_leaf,
    COUNT(*) AS product_cnt,
    APPROX_QUANTILES(list_price, 2)[OFFSET(1)] AS median_list_price
  FROM `project_id.dataset_id.v_rep`
  WHERE list_price > 0
  GROUP BY cat_leaf
  HAVING COUNT(*) >= 10
),
scored AS (
  SELECT
    p.product_name,
    p.cat_leaf,
    p.price,
    p.list_price,
    p.rating,
    p.rating_cnt,
    b.median_list_price,
    1 - SAFE_DIVIDE(p.price, p.list_price) AS nominal_discount,
    SAFE_DIVIDE(p.list_price, b.median_list_price) AS list_price_ratio
  FROM candidate_product AS p
  JOIN category_price_benchmark AS b USING (cat_leaf)
)
SELECT
  product_name AS 상품명,
  cat_leaf AS 카테고리,
  ROUND(nominal_discount * 100) AS 표기_할인율,
  list_price AS 표기_정가,
  median_list_price AS 카테고리_정가중앙값,
  ROUND(list_price_ratio, 2) AS 정가_중앙값대비_배율,
  price AS 판매가,
  rating AS 평점,
  rating_cnt AS 리뷰수
FROM scored
WHERE list_price_ratio <= 1.2
ORDER BY nominal_discount DESC, rating DESC, rating_cnt DESC
LIMIT 100;
```

**4. 결과**:

*(빅쿼리 실행 화면 캡처)*

정가 배율의 **중앙값은 정확히 1.00**입니다. 대부분의 판매자는 카테고리 통념대로 정가를 적는다는 뜻입니다. 그런데 상위 10%가 2.00배, 상위 1%가 4.06배, 최대 8.04배까지 벌어집니다.  
후보 593개 중 **35.8%가 게이트에서 탈락**했고, 표기 할인율 TOP 20만 보면 **12개(60%)가 탈락**합니다. 즉 할인율 상위권일수록 정가 이상치가 몰려 있습니다.

**게이트에서 걸러진 상품**

| 상품명 | 카테고리 | 표기 할인율 | 정가 배율 | 표기 정가 | 카테고리 정가중앙값 |
|---|---|---|---|---|---|
| Fire-Boltt Ninja Call Pro Plus 1.83" S | SmartWatches | 91 | 2.5 | ₹19,999 | ₹7,990 |
| Sounce Fast Phone Charging Cable & Dat | USBCables | 90 | 2.11 | ₹1,899 | ₹899 |
| Rts™ High Speed 3D Full HD 1080p Suppo | HDMICables | 88 | 5.55 | ₹4,999 | ₹900 |
| Macmillan Aquafresh 5 Micron PS-05 10" | WaterPurifierAccessories | 86 | 2.14 | ₹1,499 | ₹699 |
| Wembley LCD Writing Pad/Tab \| Writing, | GraphicTablets | 85 | 1.6 | ₹1,599 | ₹999 |

Rts HDMI 케이블은 정가를 카테고리 중앙값의 **5.55배**로 적어 두고 "88% 할인"으로 표시됩니다.

**게이트를 통과한 추천 목록**

| 상품명 | 카테고리 | 표기 할인율 | 표기 정가 | 카테고리 정가중앙값 | 정가 배율 | 판매가 | 평점 | 리뷰수 |
|---|---|---|---|---|---|---|---|---|
| beatXP Kitchen Scale Multipurpose Port | DigitalKitchenScales | 90 | ₹1,999 | ₹1,949 | 1.03 | ₹199 | 3.7 | 2,031 |
| pTron Solero M241 2.4A Micro USB Data  | USBCables | 89 | ₹800 | ₹899 | 0.89 | ₹89 | 3.9 | 1,075 |
| PTron Solero T241 2.4A Type-C Data & C | USBCables | 88 | ₹800 | ₹899 | 0.89 | ₹99 | 3.9 | 24,871 |
| Lapster 1.5 mtr USB 2.0 Type A Male to | USBCables | 86 | ₹999 | ₹899 | 1.11 | ₹139 | 4.0 | 1,313 |
| PTron Boom Ultima 4D Dual Driver, in-E | In-Ear | 84 | ₹1,900 | ₹1,990 | 0.95 | ₹299 | 3.6 | 18,202 |
| Posh 1.5 Meter High Speed Gold Plated  | HDMICables | 83 | ₹999 | ₹900 | 1.11 | ₹173 | 4.3 | 1,237 |

통과한 상단은 정가 배율이 0.89~1.11로 **카테고리 가격대에서 벗어나지 않으면서 실제 판매가가 낮은 상품**입니다.

---

# 추천 시스템 — 4

**1. 추천 시스템 이름**  
➜ **"리뷰 수 편향을 보정한 숨은 우수 상품 추천"**

**2. 추천 시스템의 테마: 추천 시스템의 고유 컨셉에 대한 설명**  
➜ 추천이 리뷰 수를 따라가면 리뷰 수는 더 몰립니다. 실제로 **USB 케이블 107개 중 상위 20%가 리뷰의 80.3%**를, 팬히터는 95.1%를 가져갑니다.  
➜ 반대로 평점만 보면 **리뷰가 몇 건 없는 5점 상품**이 지나치게 높게 평가됩니다. 그래서 리뷰 수가 적을수록 카테고리 평균 쪽으로 평점을 끌어당긴 뒤, 같은 카테고리에서 **리뷰 수는 적지만 보정평점은 높은 상품**을 찾습니다.  
➜ 여기서 리뷰 수는 실제 노출 수가 아니라 **관심도의 대리 지표**입니다. 따라서 결과는 "노출이 부족하다고 확정된 상품"이 아니라 **추가 노출 실험을 해볼 만한 후보**로 해석합니다.

**3. 구현 로직: SQL 쿼리 설명 및 주요 로직 설명**  
➜ ① 카테고리별 리뷰 수 중앙값 `m` 과 평균 평점 `C` 를 계산  
➜ ② 상품 평점 `R` 을 리뷰 수 `v` 에 따라 보정 — **`보정평점 = (v×R + m×C) ÷ (v+m)`**  
➜ ③ 카테고리 안에서 `PERCENT_RANK()`로 리뷰 수 백분위와 보정평점 백분위를 각각 계산  
➜ ④ **리뷰 수 하위 50% × 보정평점 상위 25%** 교집합만 남김  
➜ ⑤ 근거가 지나치게 얇은 상품을 빼기 위해 **리뷰 200건 이상** 조건 추가

```jsx
WITH product_pool AS (
  SELECT *
  FROM `project_id.dataset_id.v_rep`
  WHERE rating IS NOT NULL
    AND rating_cnt IS NOT NULL
    AND price IS NOT NULL
),
category_rating_stats AS (
  SELECT
    cat_leaf,
    COUNT(*) AS product_cnt,
    APPROX_QUANTILES(rating_cnt, 2)[OFFSET(1)] AS median_rating_cnt,
    AVG(rating) AS category_avg_rating
  FROM product_pool
  GROUP BY cat_leaf
  HAVING COUNT(*) >= 10
),
scored AS (
  SELECT
    p.product_name,
    p.cat_leaf,
    p.price,
    p.rating,
    p.rating_cnt,
    SAFE_DIVIDE(
      p.rating_cnt * p.rating + s.median_rating_cnt * s.category_avg_rating,
      p.rating_cnt + s.median_rating_cnt
    ) AS adjusted_rating,
    PERCENT_RANK() OVER (
      PARTITION BY p.cat_leaf
      ORDER BY p.rating_cnt
    ) AS attention_percentile
  FROM product_pool AS p
  JOIN category_rating_stats AS s USING (cat_leaf)
),
ranked AS (
  SELECT
    *,
    PERCENT_RANK() OVER (
      PARTITION BY cat_leaf
      ORDER BY adjusted_rating
    ) AS quality_percentile
  FROM scored
)
SELECT
  product_name AS 상품명,
  cat_leaf AS 카테고리,
  rating AS 원_평점,
  rating_cnt AS 리뷰수,
  ROUND(adjusted_rating, 2) AS 보정평점,
  price AS 판매가,
  ROUND(attention_percentile * 100) AS 카테고리내_관심백분위,
  ROUND(quality_percentile * 100) AS 카테고리내_보정평점백분위
FROM ranked
WHERE attention_percentile <= 0.5
  AND quality_percentile >= 0.75
  AND rating_cnt >= 200
ORDER BY 보정평점 DESC, 리뷰수 ASC
LIMIT 100;
```

**4. 결과**:

*(빅쿼리 실행 화면 캡처)*

| 단계 | 조건 | 잔존 상품 수 | 직전 대비 통과율 |
|---|---|---|---|
| 0 | 전체 상품(product_id 기준) | 1,351 | — |
| 1 | 변종 접기 + 카테고리 모수 10개 이상 | 742 | 54.9% |
| 2 | 카테고리 내 리뷰수 하위 50%(=묻힌 상품) | 379 | 51.1% |
| 3 | 베이지안 보정 평점 카테고리 상위 25% | 41 | 10.8% |
| 4 | 리뷰 200건 이상(신뢰 확보) | 39 | 95.1% |

가장 크게 걸리는 구간은 **보정평점 상위 25%(통과율 10.8%)** 입니다. 리뷰가 적게 달린 상품 대부분은 실제로 평범하다는 뜻이고, 이 조건이 추천기의 핵심입니다. 마지막 리뷰 200건 조건은 95.1%가 통과하므로 사실상 안전장치 역할만 합니다.

| 상품명 | 카테고리 | 원 평점 | 리뷰수 | 보정평점 | 판매가 | 관심 백분위 | 보정평점 백분위 |
|---|---|---|---|---|---|---|---|
| Borosil Electric Egg Boiler, 8 Egg Cap | EggBoilers | 4.4 | 461 | 4.32 | ₹1,399 | 10 | 90 |
| Zuvexa Egg Boiler Poacher Automatic Of | EggBoilers | 4.4 | 227 | 4.31 | ₹419 | 0 | 80 |
| Sujata Dynamix DX Mixer Grinder, 900W, | MixerGrinders | 4.6 | 6,550 | 4.31 | ₹6,120 | 50 | 100 |
| Kodak 139 cm (55 inches) 4K Ultra HD S | SmartTelevisions | 4.4 | 1,712 | 4.26 | ₹29,999 | 47 | 81 |
| Belkin Apple Certified Lightning To Ty | USBCables | 4.4 | 1,951 | 4.26 | ₹1,599 | 48 | 87 |
| Duracell USB Lightning Apple Certified | USBCables | 4.5 | 815 | 4.24 | ₹970 | 33 | 82 |
| ZEBRONICS Aluminium Alloy Laptop Stand | Lapdesks | 4.4 | 1,667 | 4.22 | ₹899 | 38 | 85 |
| Havells Instanio 10 Litre Storage Wate | StorageWaterHeaters | 4.4 | 1,771 | 4.22 | ₹6,990 | 9 | 91 |

목록 상단에 **Belkin·Duracell의 애플 인증(MFi) 케이블**이 올라옵니다. 같은 진열대에서 무인증 저가 케이블이 리뷰를 독식하는 동안 평점 4.4~4.5를 유지하면서 노출은 하위권에 머문 상품들입니다. 브랜드를 조건에 넣지 않았는데 분포에서 저절로 떠오른 결과입니다.

---

# 추천 시스템 — 5

**1. 추천 시스템 이름**  
➜ **"추가 지출의 가치가 보이는 예산 사다리 추천"**

**2. 추천 시스템의 테마: 추천 시스템의 고유 컨셉에 대한 설명**  
➜ 앞의 넷이 목록을 **거르는** 방식이었다면, 이건 목록을 **계단으로 바꿉니다.**  
➜ 같은 세부 카테고리 안에서 가격과 보정평점을 함께 봅니다. **더 싸거나 같은 가격인데 보정평점이 더 높은 상품이 있으면 그 상품은 추천에서 뺍니다.** 남은 상품을 가격순으로 세우면, 예산을 올릴 때 품질이 실제로 얼마나 오르는지 단계별로 확인할 수 있습니다.  
➜ **예산 슬라이더 UI**에 그대로 붙일 수 있는 형태입니다.

**3. 구현 로직: SQL 쿼리 설명 및 주요 로직 설명**  
➜ ① 추천 4와 같은 방식으로 카테고리별 보정평점 계산  
➜ ② 가격 오름차순으로 정렬  
➜ ③ **`MAX(adjusted_rating) OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)`** 으로 자기보다 싼 상품들의 최대 보정평점을 누적  
➜ ④ 그 값을 넘어서는 상품만 남기면 **가격–보정평점 파레토 프론티어**가 됨. 자기결합 없이 윈도 함수 한 번으로 계산  
➜ ⑤ `LAG`로 이전 단계 대비 **추가 지불액**과 **보정평점 상승폭**을 함께 출력

```jsx
WITH product_pool AS (
  SELECT *
  FROM `project_id.dataset_id.v_rep`
  WHERE rating IS NOT NULL
    AND rating_cnt IS NOT NULL
    AND price IS NOT NULL
),
category_rating_stats AS (
  SELECT
    cat_leaf,
    APPROX_QUANTILES(rating_cnt, 2)[OFFSET(1)] AS median_rating_cnt,
    AVG(rating) AS category_avg_rating
  FROM product_pool
  GROUP BY cat_leaf
  HAVING COUNT(*) >= 10
),
scored AS (
  SELECT
    p.product_name,
    p.cat_leaf,
    p.price,
    p.rating,
    p.rating_cnt,
    SAFE_DIVIDE(
      p.rating_cnt * p.rating + s.median_rating_cnt * s.category_avg_rating,
      p.rating_cnt + s.median_rating_cnt
    ) AS adjusted_rating
  FROM product_pool AS p
  JOIN category_rating_stats AS s USING (cat_leaf)
),
frontier_candidate AS (
  SELECT
    *,
    MAX(adjusted_rating) OVER (
      PARTITION BY cat_leaf
      ORDER BY price ASC, adjusted_rating DESC
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS best_previous_rating
  FROM scored
),
frontier AS (
  SELECT *
  FROM frontier_candidate
  WHERE best_previous_rating IS NULL
     OR adjusted_rating > best_previous_rating
)
SELECT
  cat_leaf AS 카테고리,
  product_name AS 상품명,
  price AS 판매가,
  rating AS 원_평점,
  rating_cnt AS 리뷰수,
  ROUND(adjusted_rating, 2) AS 보정평점,
  ROW_NUMBER() OVER (
    PARTITION BY cat_leaf
    ORDER BY price
  ) AS 예산단계,
  ROUND(
    price - LAG(price) OVER (PARTITION BY cat_leaf ORDER BY price)
  ) AS 이전단계대비_추가지불액,
  ROUND(
    adjusted_rating - LAG(adjusted_rating) OVER (PARTITION BY cat_leaf ORDER BY price),
    3
  ) AS 이전단계대비_보정평점상승폭
FROM frontier
ORDER BY 카테고리, 판매가;
```

**4. 결과**:

*(빅쿼리 실행 화면 캡처)*

후보 **742개 중 156개(21%)** 만 프론티어에 남았습니다. 나머지 79%는 더 싸면서 보정평점도 높은 다른 상품에 대체된다는 뜻입니다.

**스마트 TV 사다리**

| 예산단계 | 상품명 | 판매가 | 원 평점 | 보정평점 | 추가 지불액 | 보정평점 상승폭 |
|---|---|---|---|---|---|---|
| 1 | SKYWALL 81.28 cm (32 inches) HD Ready Sm | ₹7,299 | 3.4 | 4.00 | — | — |
| 2 | VW 80 cm (32 inches) Playwall Frameless  | ₹8,499 | 4.3 | 4.20 | +₹1,200 | +0.20 |
| 3 | LG 80 cm (32 inches) HD Ready Smart LED  | ₹13,490 | 4.3 | 4.28 | +₹4,991 | +0.08 |
| 4 | Mi 80 cm (32 inches) HD Ready Android Sm | ₹14,999 | 4.3 | 4.29 | +₹1,509 | +0.01 |
| 5 | Sony Bravia 164 cm (65 inches) 4K Ultra  | ₹77,990 | 4.7 | 4.53 | +₹62,991 | +0.24 |

₹7,299 → ₹8,499 구간은 **1,200루피로 보정평점 +0.20**이 오르는 반면, ₹13,490 → ₹14,999 구간은 1,509루피를 더 내도 **+0.01**에 그칩니다. 예산을 어디서 멈춰야 하는지가 표에 그대로 드러납니다.

**USB 케이블 사다리**

| 예산단계 | 상품명 | 판매가 | 원 평점 | 보정평점 | 추가 지불액 | 보정평점 상승폭 |
|---|---|---|---|---|---|---|
| 1 | FLiX (Beetel USB to Micro USB PVC Data S | ₹59 | 4.0 | 4.03 | — | — |
| 2 | pTron Solero M241 2.4A Micro USB Data &  | ₹89 | 3.9 | 4.07 | +₹30 | +0.04 |
| 3 | Amazon Brand - Solimo 3A Fast Charging T | ₹119 | 3.8 | 4.14 | +₹30 | +0.07 |
| 4 | Zebronics CU3100V Fast charging Type C c | ₹128 | 3.9 | 4.14 | +₹9 | +0.00 |
| 5 | Amazon Brand - Solimo Fast Charging Brai | ₹129 | 4.1 | 4.14 | +₹0 | +0.00 |
| 6 | Portronics Konnect L POR-1081 Fast Charg | ₹154 | 4.3 | 4.28 | +₹25 | +0.14 |
| 7 | AmazonBasics USB 2.0 Cable - A-Male to B | ₹209 | 4.5 | 4.49 | +₹55 | +0.21 |

₹999 Belkin 케이블은 ₹209 AmazonBasics에 가격·보정평점 모두 밀려 프론티어에서 빠집니다.

**한계**  
파레토 비교는 **같은 세부 카테고리 안에서만** 유효합니다. `USBCables` 한 칸에 Lightning·Type-C·A-B 규격이 섞여 있어서, 서로 대체할 수 없는 상품끼리 비교되고 있습니다. 실서비스에서는 `about_product`에서 단자·용량 같은 핵심 사양을 뽑아 비교 집단을 한 단계 더 쪼개야 합니다.

---

# 전체 정리

다섯 개를 임계값만 바꾼 변주가 아니라 **서로 다른 열, 서로 다른 연산** 위에 올렸습니다.

| # | 추천 시스템 | 주 사용 열 | 핵심 연산 | 사용자에게 주는 것 |
|---|---|---|---|---|
| 1 | 중복 옵션을 정리한 연관 상품 추천 | `user_id` | 자카드 + 연결요소 | 추천 목록의 다양성 |
| 2 | 같은 고객이 함께 관심을 보인 카테고리 추천 | `user_id` × `category` | 행 정규화 교차관심률 | 다음에 둘러볼 카테고리 |
| 3 | 과도한 정가를 걸러낸 실질 할인 상품 추천 | `actual_price` | 카테고리 중앙값 게이트 | 과장되지 않은 할인 |
| 4 | 리뷰 수 편향을 보정한 숨은 우수 상품 추천 | `rating` × `rating_count` | 베이지안 보정 + 백분위 | 1페이지 밖의 좋은 상품 |
| 5 | 추가 지출의 가치가 보이는 예산 사다리 추천 | `discounted_price` × `rating` | 파레토 프론티어 윈도 | 얼마를 더 쓸지에 대한 답 |

**운영상 한계**  
➜ 추천 1·2는 리뷰어의 **공동 등장 관계**를 쓰지만 구매 순서나 인과관계를 뜻하지 않습니다.  
➜ 추천 3의 정가 필터와 추천 4·5의 보정평점은 이 데이터 특성에 맞춘 **휴리스틱**입니다.  
➜ 실서비스에서는 클릭률·구매전환율·반품률·노출 로그를 더하고 **A/B 테스트로 추천 성과를 검증**해야 합니다.
