-- 03_load_postings.sql | PostgreSQL 18
-- raw.postings -> stg.postings, stg.posting_items.
-- Выполнять файл целиком в одной сессии после 01_create_objects.sql и 02_load_products.sql.
-- При ошибке транзакция прерывается: выполните ROLLBACK перед повторным запуском.
-- Повторный запуск обновляет состояния; исходные данные raw не изменяются.

-- 1. Общая транзакция и блокировка параллельного изменения целевых таблиц.
BEGIN;

SET LOCAL TIME ZONE 'Europe/Moscow';

LOCK TABLE stg.postings, stg.posting_items IN SHARE ROW EXCLUSIVE MODE;

-- 2. Последний успешно загруженный payload каждого отправления FBO и FBS.
-- При одинаковом loaded_at выбираем строку с большим raw_id.
-- Временная таблица автоматически удаляется после COMMIT.
CREATE TEMP TABLE tmp_postings ON COMMIT DROP AS
SELECT DISTINCT ON (r.scheme, r.posting_number)
    r.scheme,
    r.posting_number,
    r.payload,
    r.raw_id AS source_raw_id,
    r.loaded_at AS source_loaded_at,
    r.load_run_id
FROM raw.postings AS r
JOIN meta.load_runs AS m ON m.load_run_id = r.load_run_id
WHERE m.status = 'success'
ORDER BY r.scheme, r.posting_number, r.loaded_at DESC, r.raw_id DESC;

-- 3. Основные сведения: прямой маппинг и обновление по схеме и номеру отправления.
-- Пустые числовые значения и даты становятся NULL.
-- Отсутствующие поля одной из схем остаются NULL; даты друг другом не заменяем.
WITH mapped_postings AS (
    SELECT
        scheme,
        posting_number,
        NULLIF(BTRIM(payload ->> 'order_id'), '')::BIGINT AS order_id,
        payload ->> 'order_number' AS order_number,
        payload ->> 'status' AS status,
        payload ->> 'substatus' AS substatus,
        NULLIF(BTRIM(payload ->> 'created_at'), '')::TIMESTAMPTZ AS created_at,
        NULLIF(BTRIM(payload ->> 'in_process_at'), '')::TIMESTAMPTZ AS processing_started_at,
        NULLIF(BTRIM(payload ->> 'delivering_date'), '')::TIMESTAMPTZ AS delivering_at,
        NULLIF(BTRIM(payload ->> 'shipment_date'), '')::TIMESTAMPTZ AS shipment_date,
        source_raw_id,
        source_loaded_at,
        load_run_id
    FROM tmp_postings
)
INSERT INTO stg.postings (
    scheme,
    posting_number,
    order_id,
    order_number,
    status,
    substatus,
    created_at,
    processing_started_at,
    delivering_at,
    shipment_date,
    source_raw_id,
    source_loaded_at,
    load_run_id
)
SELECT
    scheme,
    posting_number,
    order_id,
    order_number,
    status,
    substatus,
    created_at,
    processing_started_at,
    delivering_at,
    shipment_date,
    source_raw_id,
    source_loaded_at,
    load_run_id
FROM mapped_postings
ORDER BY scheme, posting_number
ON CONFLICT (scheme, posting_number) DO UPDATE SET
    order_id = EXCLUDED.order_id,
    order_number = EXCLUDED.order_number,
    status = EXCLUDED.status,
    substatus = EXCLUDED.substatus,
    created_at = EXCLUDED.created_at,
    processing_started_at = EXCLUDED.processing_started_at,
    delivering_at = EXCLUDED.delivering_at,
    shipment_date = EXCLUDED.shipment_date,
    source_raw_id = EXCLUDED.source_raw_id,
    source_loaded_at = EXCLUDED.source_loaded_at,
    load_run_id = EXCLUDED.load_run_id;

-- 4. Позиции: заменяем состав только у отправлений из tmp_postings.
DELETE FROM stg.posting_items AS i
USING tmp_postings AS t
WHERE i.scheme = t.scheme
  AND i.posting_number = t.posting_number;

-- Один SKU может повторяться в источниках одного товара: сводим его к одной связи.
-- Если SKU связан с разными товарами, однозначной связи нет и product_id останется NULL.
-- MIN применяется только к SKU, для которых найден ровно один различный product_id.
WITH sku_map AS (
    SELECT
        sku,
        MIN(product_id) AS product_id
    FROM stg.product_sources
    WHERE sku IS NOT NULL
    GROUP BY sku
    HAVING COUNT(DISTINCT product_id) = 1
), mapped_items AS (
    SELECT
        t.scheme,
        t.posting_number,
        i.position::INTEGER AS position_no,
        NULLIF(BTRIM(i.item ->> 'sku'), '')::BIGINT AS sku,
        i.item ->> 'offer_id' AS offer_id,
        i.item ->> 'name' AS product_name,
        NULLIF(BTRIM(i.item ->> 'quantity'), '')::INTEGER AS quantity,
        NULLIF(BTRIM(i.item #>> '{price,amount}'), '')::NUMERIC AS unit_price,
        NULLIF(i.item #>> '{price,currency}', '') AS currency_code,
        t.source_raw_id,
        t.source_loaded_at,
        t.load_run_id
    FROM tmp_postings AS t
    CROSS JOIN LATERAL jsonb_array_elements(t.payload -> 'products') WITH ORDINALITY AS i(item, position)
)
INSERT INTO stg.posting_items (
    scheme,
    posting_number,
    position_no,
    sku,
    offer_id,
    product_id,
    product_name,
    quantity,
    unit_price,
    currency_code,
    source_raw_id,
    source_loaded_at,
    load_run_id
)
SELECT
    i.scheme,
    i.posting_number,
    i.position_no,
    i.sku,
    i.offer_id,
    m.product_id,
    i.product_name,
    i.quantity,
    i.unit_price,
    i.currency_code,
    i.source_raw_id,
    i.source_loaded_at,
    i.load_run_id
FROM mapped_items AS i
LEFT JOIN sku_map AS m ON m.sku = i.sku;

-- 5. Фиксация результата и автоматическое удаление временной таблицы.
COMMIT;

SELECT *
FROM stg.postings p;
