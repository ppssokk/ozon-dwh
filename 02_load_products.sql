-- 02_load_products.sql | PostgreSQL 18
-- raw.products -> stg.products, stg.product_sources, stg.product_stocks.
-- Выполнять файл целиком в одной сессии после 01_create_objects.sql.
-- При ошибке транзакция прерывается: выполните ROLLBACK перед повторным запуском.
-- Повторный запуск обновляет состояния; исходные данные raw не изменяются.

-- 1. Общая транзакция и блокировка параллельного изменения целевых таблиц.
BEGIN;

SET LOCAL TIME ZONE 'Europe/Moscow';

LOCK TABLE stg.products, stg.product_sources, stg.product_stocks IN SHARE ROW EXCLUSIVE MODE;

-- 2. Последний успешно загруженный payload каждого товара.
-- При одинаковом loaded_at выбираем строку с большим raw_id.
-- Временная таблица автоматически удаляется после COMMIT.
CREATE TEMP TABLE tmp_products ON COMMIT DROP AS
SELECT DISTINCT ON (r.product_id)
    r.product_id,
    r.payload,
    r.raw_id AS source_raw_id,
    r.loaded_at AS source_loaded_at,
    r.load_run_id
FROM raw.products AS r
JOIN meta.load_runs AS m ON m.load_run_id = r.load_run_id
WHERE m.status = 'success'
ORDER BY r.product_id, r.loaded_at DESC, r.raw_id DESC;

-- 3. Основные сведения: извлечение, приведение типов и обновление по product_id.
-- Пустые числовые значения и даты становятся NULL; 0 и false сохраняются.
-- Артикул, название и обозначения Ozon сохраняем без изменения текста.
WITH mapped_products AS (
    SELECT
        product_id,
        payload ->> 'offer_id' AS offer_id,
        NULLIF(BTRIM(payload ->> 'sku'), '')::BIGINT AS sku,
        payload ->> 'name' AS name,
        NULLIF(BTRIM(payload ->> 'description_category_id'), '')::BIGINT AS description_category_id,
        NULLIF(BTRIM(payload ->> 'type_id'), '')::BIGINT AS type_id,
        NULLIF(BTRIM(payload ->> 'price'), '')::NUMERIC AS price,
        payload ->> 'currency_code' AS currency_code,
        (payload ->> 'is_archived')::BOOLEAN AS is_archived,
        (payload ->> 'is_autoarchived')::BOOLEAN AS is_autoarchived,
        payload #>> '{statuses,status}' AS product_status,
        NULLIF(BTRIM(payload ->> 'updated_at'), '')::TIMESTAMPTZ AS product_updated_at,
        source_raw_id,
        source_loaded_at,
        load_run_id
    FROM tmp_products
)
INSERT INTO stg.products (
    product_id,
    offer_id,
    sku,
    name,
    description_category_id,
    type_id,
    price,
    currency_code,
    is_archived,
    is_autoarchived,
    product_status,
    product_updated_at,
    source_raw_id,
    source_loaded_at,
    load_run_id
)
SELECT
    product_id,
    offer_id,
    sku,
    name,
    description_category_id,
    type_id,
    price,
    currency_code,
    is_archived,
    is_autoarchived,
    product_status,
    product_updated_at,
    source_raw_id,
    source_loaded_at,
    load_run_id
FROM mapped_products
ORDER BY product_id
ON CONFLICT (product_id) DO UPDATE SET
    offer_id = EXCLUDED.offer_id,
    sku = EXCLUDED.sku,
    name = EXCLUDED.name,
    description_category_id = EXCLUDED.description_category_id,
    type_id = EXCLUDED.type_id,
    price = EXCLUDED.price,
    currency_code = EXCLUDED.currency_code,
    is_archived = EXCLUDED.is_archived,
    is_autoarchived = EXCLUDED.is_autoarchived,
    product_status = EXCLUDED.product_status,
    product_updated_at = EXCLUDED.product_updated_at,
    source_raw_id = EXCLUDED.source_raw_id,
    source_loaded_at = EXCLUDED.source_loaded_at,
    load_run_id = EXCLUDED.load_run_id;

-- 4. Источники SKU: заменяем набор только у товаров из tmp_products.
DELETE FROM stg.product_sources AS s
USING tmp_products AS t
WHERE s.product_id = t.product_id;

-- WITH ORDINALITY нумерует элементы массива с 1.
-- Повторяющиеся SKU сохраняются как отдельные исходные элементы массива.
INSERT INTO stg.product_sources (
    product_id,
    source_position,
    sku,
    source,
    source_raw_id,
    source_loaded_at,
    load_run_id
)
SELECT
    t.product_id,
    s.position::INTEGER,
    NULLIF(BTRIM(s.item ->> 'sku'), '')::BIGINT,
    s.item ->> 'source',
    t.source_raw_id,
    t.source_loaded_at,
    t.load_run_id
FROM tmp_products AS t
CROSS JOIN LATERAL jsonb_array_elements(t.payload -> 'sources') WITH ORDINALITY AS s(item, position);

-- 5. Остатки: раскрываем отдельно от sources, чтобы строки не перемножались.
DELETE FROM stg.product_stocks AS s
USING tmp_products AS t
WHERE s.product_id = t.product_id;

INSERT INTO stg.product_stocks (
    product_id,
    stock_position,
    sku,
    source,
    present,
    reserved,
    source_raw_id,
    source_loaded_at,
    load_run_id
)
SELECT
    t.product_id,
    s.position::INTEGER,
    NULLIF(BTRIM(s.item ->> 'sku'), '')::BIGINT,
    s.item ->> 'source',
    NULLIF(BTRIM(s.item ->> 'present'), '')::INTEGER,
    NULLIF(BTRIM(s.item ->> 'reserved'), '')::INTEGER,
    t.source_raw_id,
    t.source_loaded_at,
    t.load_run_id
FROM tmp_products AS t
CROSS JOIN LATERAL jsonb_array_elements(t.payload #> '{stocks,stocks}') WITH ORDINALITY AS s(item, position);

-- 6. Фиксация результата и автоматическое удаление временных таблиц.
COMMIT;