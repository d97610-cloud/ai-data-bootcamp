-- =====================================================================================
-- [과제] Amazon 판매 데이터 기반 추천 시스템 설계
-- 데이터셋     : Amazon Sales Dataset (1,465행 / product_id 기준 1,351개 상품)
-- SQL 엔진     : BigQuery Standard SQL
-- 원본 테이블  : `project_id.dataset_id.amazon`
--
-- 분석 전제
--   1) 이 데이터에는 구매·클릭·노출 시각과 같은 행동 로그가 없다.
--      따라서 실제 구매 순서나 구매 확률을 예측하는 모델이 아니라, 상품 정보와 리뷰 관계를
--      이용해 추천 후보를 만드는 규칙 기반 추천 시스템을 설계한다.
--   2) rating_count는 상품이 받은 관심과 평가 근거의 양을 나타내는 대리 지표로 사용한다.
--      실제 노출 수와 동일한 값은 아니다.
--   3) user_id에는 해당 상품의 리뷰어가 쉼표로 연결되어 있다. 리뷰 작성 순서는 없으므로
--      여러 상품에 함께 등장했다는 사실은 알 수 있지만, 어느 상품을 먼저 봤는지는 알 수 없다.
--
-- 설계 방향
--   평점·리뷰 수·할인율을 단순 정렬하는 방식은 피하고, 서로 다른 문제를 해결하는 다섯 가지
--   추천 로직을 구성했다.
--     1) 동일 상품의 색상·용량 등 중복 옵션을 정리한 연관 상품 추천
--     2) 같은 리뷰어가 함께 평가한 카테고리를 이용한 교차 카테고리 추천
--     3) 카테고리 기준으로 과도하게 높은 정가를 걸러낸 할인 상품 추천
--     4) 리뷰 수 편향을 보정해 상대적으로 덜 알려진 우수 상품을 찾는 추천
--     5) 추가 지출 대비 보정평점이 실제로 높아지는 상품만 보여주는 예산 사다리 추천
--
-- 주의
--   아래 결과 설명의 수치는 원본 파일에 기록된 기존 실행 결과를 바탕으로 문장만 정리했다.
--   전처리 및 일부 쿼리를 보완했으므로 제출 전 현재 쿼리 결과와 수치·캡처가 일치하는지
--   반드시 다시 확인해야 한다.
-- =====================================================================================


-- =====================================================================================
-- 0. 공통 전처리 뷰
-- =====================================================================================

-- 0-1. 상품 단위 마스터 테이블
--      원본 1,465행에는 같은 product_id가 여러 번 등장한다. 먼저 가격·평점·리뷰 수를
--      숫자형으로 변환한 뒤, product_id별로 리뷰 수가 가장 많은 행을 대표 행으로 선택한다.
--      이 방식은 각 컬럼을 따로 임의 선택하는 것보다 한 행의 상품 속성을 일관되게 유지한다.
--      rating에 숫자가 아닌 값('|')이 한 건 포함되어 있으므로 SAFE_CAST를 사용해 NULL 처리한다.
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

-- 0-2. 리뷰어-상품 관계 테이블
--      user_id 한 셀에 쉼표로 저장된 여러 리뷰어를 각각의 행으로 분리한다.
--      한 행은 '리뷰어 1명과 상품 1개의 연결 관계'를 뜻한다.
CREATE OR REPLACE VIEW `project_id.dataset_id.v_user_product` AS
SELECT DISTINCT
  TRIM(user_id_value) AS user_id,
  product_id
FROM `project_id.dataset_id.amazon` AS a,
     UNNEST(SPLIT(a.user_id, ',')) AS user_id_value
WHERE TRIM(user_id_value) != '';


-- =====================================================================================
-- 추천 시스템 1
--   1) 추천 시스템 이름
--      "중복 옵션을 정리한 연관 상품 추천"
--
--   2) 추천 시스템의 테마
--      같은 상품이 색상·용량·케이블 규격만 달리해 별도 상품으로 등록되면 리뷰어 집합도 거의
--      동일하게 나타날 수 있다. 이를 그대로 사용하면 연관 상품 영역이 방금 본 상품의 다른
--      옵션으로 채워진다. 먼저 중복 옵션으로 보이는 상품들을 하나의 상품군으로 묶고,
--      상품군 사이에서 실제로 리뷰어가 겹치는 다른 카테고리 상품을 추천한다.
--
--   3) 구현 로직
--      ① 리뷰어를 공유하는 상품쌍마다 자카드 유사도를 계산한다.
--      ② 자카드 유사도가 0.5 이상이면 동일 상품의 옵션일 가능성이 높은 관계로 본다.
--      ③ 연결된 상품을 하나의 옵션 상품군으로 묶고, 리뷰 수가 가장 많은 상품을 대표로 선택한다.
--      ④ 리뷰어-상품 관계를 리뷰어-상품군 관계로 다시 집계한 뒤, 서로 다른 상품군 사이의
--         공통 리뷰어 수와 자카드 유사도를 계산한다.
--      ⑤ 같은 세부 카테고리 밖에서 연관도가 높은 상품군을 추천한다.
--
--   4) 기존 실행 결과 요약
--      리뷰어를 공유한 상품쌍은 652개였고, 자카드 유사도 0.5 이상인 쌍 305개와 0.25 미만인
--      쌍 347개로 뚜렷하게 나뉘었다. 높은 유사도의 상품들은 색상·용량·규격만 다른 상품인
--      경우가 많았으며, 97개 상품군에 267개 상품이 묶였다. 이 전처리를 통해 동일 상품의
--      여러 옵션이 추천 목록을 반복해서 차지하는 문제를 줄일 수 있다.
--
--   ※ 현재 상품군 생성은 이 데이터에서 높은 유사도 관계가 상품군 내부에서 거의 완전하게
--      연결된다는 점을 확인한 뒤 1회 라벨 전파로 구현했다. 일반 데이터에서는 재귀 CTE나
--      그래프 연결요소 알고리즘으로 수렴 여부를 별도로 확인해야 한다.
-- =====================================================================================

-- 1-1. 상품쌍별 리뷰어 자카드 유사도
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

-- 1-2. 유사 옵션 상품군 생성
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

-- 1-3. 상품군별 대표 상품 선택
CREATE OR REPLACE VIEW `project_id.dataset_id.v_rep` AS
SELECT p.*, c.cluster_id
FROM `project_id.dataset_id.v_product` AS p
JOIN `project_id.dataset_id.v_variant_cluster` AS c USING (product_id)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY c.cluster_id
  ORDER BY p.rating_cnt DESC, p.product_id
) = 1;

-- 1-4. 리뷰어-상품군 관계로 변환
CREATE OR REPLACE VIEW `project_id.dataset_id.v_user_cluster` AS
SELECT DISTINCT
  up.user_id,
  c.cluster_id
FROM `project_id.dataset_id.v_user_product` AS up
JOIN `project_id.dataset_id.v_variant_cluster` AS c USING (product_id);

-- 1-5. 상품군쌍별 리뷰어 자카드 유사도
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

-- 1-6. 최종 추천 결과
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


-- =====================================================================================
-- 추천 시스템 2
--   1) 추천 시스템 이름
--      "같은 고객이 함께 관심을 보인 카테고리 추천"
--
--   2) 추천 시스템의 테마
--      상품 단위에서는 같은 리뷰어가 여러 상품에 반복해서 등장하는 사례가 적어 추천 근거가
--      희박하다. 따라서 분석 단위를 상품에서 2단계 카테고리로 넓힌다. 기준 카테고리에 리뷰를
--      남긴 사람 중 다른 카테고리에도 리뷰를 남긴 비율을 계산해, 함께 관심을 보일 가능성이
--      높은 카테고리를 추천한다.
--
--      이 데이터에는 리뷰 작성 시점이 없으므로 '다음에 이동한 카테고리'나 구매 순서를 뜻하지
--      않는다. 결과는 시간적 전이가 아니라 동일 리뷰어 집합에서 확인된 교차 관심 관계다.
--
--   3) 구현 로직
--      ① 리뷰어별로 리뷰를 작성한 2단계 카테고리 목록을 만든다.
--      ② 두 개 이상의 카테고리에 등장한 리뷰어만 남긴다.
--      ③ 기준 카테고리와 연관 카테고리의 공통 리뷰어 수를 계산한다.
--      ④ 공통 리뷰어 수를 기준 카테고리 리뷰어 수로 나눠 교차 관심률을 구한다.
--      ⑤ 기준 카테고리의 리뷰어가 8명 미만이면 표본이 너무 작다고 보고 제외한다.
--
--   4) 기존 실행 결과 요약
--      모바일 액세서리 리뷰어의 58.7%가 컴퓨터 액세서리에도 리뷰를 남겼고, 헤드폰 리뷰어의
--      46.7%도 컴퓨터 액세서리에 등장했다. 냉난방과 주방가전 사이에서도 비교적 높은 교차
--      관심이 확인됐다. 이는 상품 상세 페이지나 카테고리 페이지에서 함께 보여줄 카테고리의
--      우선순위를 정하는 근거로 활용할 수 있다. 다만 기준 카테고리별 표본이 작으므로 상위
--      1~2개 관계만 제한적으로 해석하는 것이 안전하다.
-- =====================================================================================

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


-- =====================================================================================
-- 추천 시스템 3
--   1) 추천 시스템 이름
--      "과도한 정가를 걸러낸 실질 할인 상품 추천"
--
--   2) 추천 시스템의 테마
--      할인율은 판매가와 표시 정가의 차이로 계산되므로, 표시 정가가 비정상적으로 높으면
--      할인율도 과장되어 보일 수 있다. 따라서 할인율이 높은 상품을 바로 추천하지 않고,
--      동일한 세부 카테고리의 정가 중앙값과 비교해 정가가 지나치게 높은 상품을 먼저 제외한다.
--
--      이 필터는 허위 정가를 확정하는 판정이 아니라 정가 이상치를 걸러내는 휴리스틱이다.
--      브랜드·사양·용량 차이로 정가가 실제로 높을 수도 있으므로 실서비스에서는 추가 상품
--      속성과 함께 사용해야 한다.
--
--   3) 구현 로직
--      ① 동일 옵션 상품을 하나의 대표 상품으로 정리한다.
--      ② 리뷰 수가 500건 이상인 상품만 남겨 평점의 최소 신뢰도를 확보한다.
--      ③ 세부 카테고리별 표시 정가 중앙값을 계산한다.
--      ④ 상품 정가가 해당 중앙값의 몇 배인지 계산하고, 1.2배 이하인 상품만 통과시킨다.
--      ⑤ 통과한 상품을 실제 표시 할인율이 높은 순으로 추천한다.
--
--   4) 기존 실행 결과 요약
--      기존 분석에서는 정가 중앙값보다 크게 높은 상품이 할인율 상위권에 집중됐다. 특히 일부
--      상품은 동일 카테고리 정가 중앙값의 5배 이상을 정가로 표시해 할인율이 매우 높게 보였다.
--      정가 기준 필터를 적용하면 이런 이상치가 후보에서 제외되고, 카테고리 가격대와 크게
--      어긋나지 않으면서 실제 할인 폭이 큰 상품이 상위에 남았다.
-- =====================================================================================

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


-- =====================================================================================
-- 추천 시스템 4
--   1) 추천 시스템 이름
--      "리뷰 수 편향을 보정한 숨은 우수 상품 추천"
--
--   2) 추천 시스템의 테마
--      인기 상품이 계속 상위에 노출되면 리뷰 수가 많은 상품에 관심이 더 집중되는 순환이 생긴다.
--      반대로 평점만 보면 평가가 몇 건 없는 5점 상품이 지나치게 높게 평가될 수 있다. 따라서
--      리뷰 수가 적을수록 카테고리 평균 쪽으로 평점을 보정한 뒤, 같은 카테고리에서 리뷰 수는
--      상대적으로 적지만 보정평점은 높은 상품을 찾는다.
--
--      여기서 리뷰 수는 실제 노출 수가 아니라 관심도를 대신하는 지표다. 따라서 결과는
--      '노출이 부족하다고 확정된 상품'이 아니라 추가 노출 실험을 해볼 만한 후보로 해석한다.
--
--   3) 구현 로직
--      ① 카테고리별 리뷰 수 중앙값(m)과 평균 평점(C)을 계산한다.
--      ② 상품 평점(R)을 리뷰 수(v)에 따라 카테고리 평균 쪽으로 보정한다.
--         보정평점 = (v×R + m×C) / (v+m)
--      ③ 카테고리 안에서 리뷰 수 백분위와 보정평점 백분위를 각각 계산한다.
--      ④ 리뷰 수 하위 50%이면서 보정평점 상위 25%인 상품만 남긴다.
--      ⑤ 평가 근거가 지나치게 적은 상품을 제외하기 위해 리뷰 수 200건 이상 조건을 추가한다.
--
--   4) 기존 실행 결과 요약
--      기존 분석에서는 1,351개 상품이 대표 상품·카테고리 표본·관심도·보정평점 조건을 거치며
--      최종 39개 후보로 좁혀졌다. 최종 목록에는 평점은 높지만 같은 카테고리의 초인기 상품보다
--      리뷰 수가 적은 인증 케이블, 온수기, 믹서그라인더, TV 등이 포함됐다. 이 추천은 인기순
--      추천과 별도로 신규 노출 실험 대상을 선정하는 데 활용할 수 있다.
-- =====================================================================================

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


-- =====================================================================================
-- 추천 시스템 5
--   1) 추천 시스템 이름
--      "추가 지출의 가치가 보이는 예산 사다리 추천"
--
--   2) 추천 시스템의 테마
--      단순히 저가 상품이나 고평점 상품을 나열하는 대신, 같은 세부 카테고리 안에서 가격과
--      보정평점을 함께 비교한다. 더 저렴하거나 같은 가격에 보정평점이 더 높은 상품이 있으면
--      해당 상품은 추천에서 제외한다. 남은 상품을 가격순으로 배열하면 사용자는 예산을 더
--      지출할 때 보정평점이 실제로 얼마나 높아지는지 단계별로 확인할 수 있다.
--
--   3) 구현 로직
--      ① 추천 시스템 4와 같은 방식으로 카테고리별 보정평점을 계산한다.
--      ② 가격 오름차순으로 상품을 정렬한다.
--      ③ 현재 상품보다 앞선 저가 후보들의 최대 보정평점을 누적 계산한다.
--      ④ 그 최대값보다 보정평점이 높은 상품만 남겨 가격-보정평점 파레토 프론티어를 만든다.
--      ⑤ 각 단계마다 이전 상품 대비 추가 지불액과 보정평점 상승폭을 함께 출력한다.
--
--   4) 기존 실행 결과 요약
--      기존 분석에서는 후보 742개 중 156개만 가격-보정평점 프론티어에 남았다. 이는 다수의
--      상품이 더 저렴하면서 보정평점도 높은 다른 상품에 의해 대체될 수 있다는 뜻이다.
--      예를 들어 USB 케이블과 TV 카테고리에서는 예산을 조금 올렸을 때 보정평점이 크게 오르는
--      구간과, 가격은 크게 오르지만 보정평점 차이는 작은 구간을 구분할 수 있었다.
--
--   5) 한계
--      파레토 비교는 같은 세부 카테고리 안에서만 수행한다. 하나의 세부 카테고리에 단자 규격,
--      용량, 크기 등이 섞이면 서로 대체할 수 없는 상품을 비교할 수 있다. 실서비스에서는
--      about_product에서 핵심 사양을 추출해 비교 집단을 더 세분화해야 한다.
-- =====================================================================================

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


-- =====================================================================================
-- 전체 해석 및 운영상 한계
--   · 추천 시스템 1·2는 리뷰어의 공동 등장 관계를 사용하지만, 구매 순서나 인과관계를 뜻하지 않는다.
--   · 추천 시스템 3의 정가 필터와 추천 시스템 4·5의 보정평점은 데이터 특성에 맞춘 휴리스틱이다.
--   · 실제 서비스에서는 클릭률·구매전환율·반품률·노출 로그를 추가하고, A/B 테스트로 추천 성과를
--     검증해야 한다.
-- =====================================================================================
