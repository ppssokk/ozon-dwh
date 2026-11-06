-- 04_load_assortment_performance.sql | PostgreSQL 18
-- stg.postings + stg.posting_items + stg.products -> marts.assortment_performance.
-- Выполнять файл целиком после обновления stg. При ошибке выполните ROLLBACK.
-- Периоды относятся к началу обработки отправления, статусы берём текущие.

-- 1. Общая транзакция и последовательное обновление витрины.
BEGIN;

SET LOCAL TIME ZONE 'Europe/Moscow';

LOCK TABLE marts.assortment_performance IN SHARE ROW EXCLUSIVE MODE;

-- 2. Последние 28 полных дней по МСК: обе даты включительно.
-- Предыдущий период примыкает к текущему и содержит столько же дней.
CREATE TEMP TABLE tmp_assortment_period ON COMMIT DROP AS
WITH parameters AS (
    SELECT
        NOW()::DATE - 28 AS period_start,
        NOW()::DATE - 1 AS period_end
)
SELECT
    period_start,
    period_end,
    period_start - (period_end - period_start + 1) AS previous_period_start
FROM parameters;

-- 3. Удаляем прежний результат только для выбранного периода.
-- Результаты остальных периодов сохраняются.
DELETE FROM marts.assortment_performance AS a
USING tmp_assortment_period AS t
WHERE a.period_start = t.period_start
  AND a.period_end = t.period_end;

-- 4. Собираем позиции обоих периодов и отмечаем текущий период.
WITH items_in_periods AS (
    SELECT
        i.scheme,
        i.posting_number,
        i.position_no,
        i.sku,
        i.currency_code,
        i.product_id,
        i.offer_id,
        i.product_name,
        i.quantity,
        i.unit_price,
        p.status,
        p.processing_started_at,
        i.source_loaded_at,
        i.source_raw_id,
        p.processing_started_at::DATE >= t.period_start AS is_current_period
    FROM stg.posting_items AS i
    JOIN stg.postings AS p ON p.scheme = i.scheme AND p.posting_number = i.posting_number
    CROSS JOIN tmp_assortment_period AS t
    WHERE p.processing_started_at >= t.previous_period_start::TIMESTAMPTZ
      AND p.processing_started_at < (t.period_end + 1)::TIMESTAMPTZ
), item_labels AS (
    -- Выбираем сведения из последней позиции каждого SKU, схемы и валюты.
    SELECT DISTINCT ON (scheme, sku, currency_code)
        scheme,
        sku,
        currency_code,
        product_id,
        offer_id,
        product_name
    FROM items_in_periods
    ORDER BY scheme, sku, currency_code, processing_started_at DESC, source_loaded_at DESC, source_raw_id DESC, position_no DESC
), aggregated AS (
    -- Группа существует, если SKU встречался хотя бы в одном из двух периодов.
    -- FILTER ограничивает строки для конкретного показателя.
    -- Если подходящих позиций нет, количество и сумма равны нулю.
    SELECT
        scheme,
        sku,
        currency_code,
        COUNT(DISTINCT posting_number) FILTER (WHERE is_current_period) AS postings_count,
        COALESCE(SUM(quantity) FILTER (WHERE is_current_period), 0) AS ordered_units,
        COALESCE(SUM(quantity) FILTER (WHERE is_current_period AND status = 'delivered'), 0) AS delivered_units,
        COALESCE(SUM(quantity) FILTER (WHERE is_current_period AND status = 'cancelled'), 0) AS cancelled_units,
        COALESCE(SUM(quantity) FILTER (WHERE is_current_period AND (status NOT IN ('delivered', 'cancelled') OR status IS NULL)), 0) AS other_units,
        COALESCE(SUM(quantity * unit_price) FILTER (WHERE is_current_period AND status = 'delivered'), 0) AS delivered_gross_amount,
        COALESCE(SUM(quantity) FILTER (WHERE NOT is_current_period), 0) AS previous_ordered_units
    FROM items_in_periods
    GROUP BY scheme, sku, currency_code
), calculated AS (
    -- Оконная сумма даёт общий результат по схеме и валюте выбранного периода.
    -- NULLIF защищает деление на ноль: при нулевом знаменателе процент будет NULL.
    SELECT
        a.*,
        100.0 * (ordered_units::NUMERIC - previous_ordered_units)
            / NULLIF(previous_ordered_units, 0) AS ordered_units_change_pct,
        100.0 * delivered_gross_amount
            / NULLIF(SUM(delivered_gross_amount) OVER (PARTITION BY scheme, currency_code), 0) AS delivered_gross_share_pct,
        100.0 * cancelled_units
            / NULLIF(delivered_units + cancelled_units, 0) AS cancelled_units_share_pct
    FROM aggregated AS a
)
INSERT INTO marts.assortment_performance (
    period_start,
    period_end,
    scheme,
    sku,
    currency_code,
    product_id,
    offer_id,
    product_name,
    postings_count,
    ordered_units,
    delivered_units,
    cancelled_units,
    other_units,
    delivered_gross_amount,
    previous_ordered_units,
    ordered_units_change_pct,
    delivered_gross_share_pct,
    cancelled_units_share_pct,
    refreshed_at
)
SELECT
    t.period_start,
    t.period_end,
    a.scheme,
    a.sku,
    a.currency_code,
    l.product_id,
    COALESCE(p.offer_id, l.offer_id),
    COALESCE(p.name, l.product_name),
    a.postings_count::INTEGER,
    a.ordered_units::INTEGER,
    a.delivered_units::INTEGER,
    a.cancelled_units::INTEGER,
    a.other_units::INTEGER,
    a.delivered_gross_amount::NUMERIC(18,3),
    a.previous_ordered_units::INTEGER,
    a.ordered_units_change_pct::NUMERIC(18,3),
    a.delivered_gross_share_pct::NUMERIC(18,3),
    a.cancelled_units_share_pct::NUMERIC(18,3),
    CURRENT_TIMESTAMP
FROM calculated AS a
JOIN item_labels AS l ON l.scheme = a.scheme
    AND l.sku = a.sku
    AND l.currency_code IS NOT DISTINCT FROM a.currency_code
LEFT JOIN stg.products AS p ON p.product_id = l.product_id
CROSS JOIN tmp_assortment_period AS t;

-- 5. Фиксация результата и автоматическое удаление временной таблицы.
COMMIT;

SELECT *
FROM marts.assortment_performance ap;