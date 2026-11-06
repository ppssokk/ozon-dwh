-- 05_load_stock_overview.sql | PostgreSQL 18
-- Текущие остатки, сведения о товарах и количество заказанных единиц.
-- Выполнять после 04_load_assortment_performance.sql.
-- При ошибке выполнить ROLLBACK.

-- 1. Начало транзакции и настройка времени.
BEGIN;

SET LOCAL TIME ZONE 'Europe/Moscow';

-- Не допускаем одновременный пересчёт витрины двумя загрузчиками.
LOCK TABLE marts.stock_overview IN SHARE ROW EXCLUSIVE MODE;

-- 2. Удаляем предыдущее состояние витрины.
-- При ошибке дальнейшего наполнения удаление тоже откатится.
DELETE FROM marts.stock_overview;

-- 3. Подготавливаем остатки и показатели заказов.
WITH parameters AS (
    -- Тот же период, который рассчитывает скрипт 04.
    SELECT
        NOW()::DATE - 28 AS period_start,
        NOW()::DATE - 1 AS period_end
), stock_totals AS (
    -- Собираем остатки на уровне товара, SKU и схемы.
    -- Если несколько элементов относятся к одному сочетанию, складываем их.
    -- SUM сохраняет NULL, если все исходные значения неизвестны.
    SELECT
        product_id,
        sku,
        UPPER(source) AS scheme,
        SUM(present)::INTEGER AS present,
        SUM(reserved)::INTEGER AS reserved,
        MAX(source_loaded_at) AS stock_loaded_at
    FROM stg.product_stocks
    WHERE UPPER(source) IN ('FBO', 'FBS')
    GROUP BY product_id, sku, UPPER(source)
), ordered_totals AS (
    -- Суммируем заказанные единицы по SKU и схеме независимо от валюты.
    -- Денежные показатели в эту витрину не переносим.
    SELECT
        a.sku,
        a.scheme,
        SUM(a.ordered_units)::INTEGER AS ordered_units_28d
    FROM marts.assortment_performance AS a
    CROSS JOIN parameters AS t
    WHERE a.period_start = t.period_start
      AND a.period_end = t.period_end
    GROUP BY a.sku, a.scheme
)
INSERT INTO marts.stock_overview (
    product_id,
    sku,
    scheme,
    offer_id,
    product_name,
    product_status,
    present,
    reserved,
    ordered_units_28d,
    avg_daily_ordered_units,
    period_start,
    period_end,
    stock_loaded_at,
    refreshed_at
)
SELECT
    s.product_id,
    s.sku,
    s.scheme,
    p.offer_id,
    p.name,
    p.product_status,
    s.present,
    s.reserved,
    COALESCE(o.ordered_units_28d, 0),
    (COALESCE(o.ordered_units_28d, 0)::NUMERIC / 28)::NUMERIC(18,3),
    t.period_start,
    t.period_end,
    s.stock_loaded_at,
    CURRENT_TIMESTAMP
FROM stock_totals AS s
JOIN stg.products AS p
    ON p.product_id = s.product_id
LEFT JOIN ordered_totals AS o
    ON o.sku = s.sku
   AND o.scheme = s.scheme
CROSS JOIN parameters AS t;

-- 4. Фиксация нового состояния витрины.
COMMIT;
