-- 06_load_posting_control.sql | PostgreSQL 18
-- Состояние отправлений, состав и длительности обработки.
-- Выполнять после 03_load_postings.sql.
-- При ошибке выполнить ROLLBACK.

-- 1. Начало транзакции и настройка времени.
BEGIN;

SET LOCAL TIME ZONE 'Europe/Moscow';

-- Не допускаем одновременный пересчёт витрины двумя загрузчиками.
LOCK TABLE marts.posting_control IN SHARE ROW EXCLUSIVE MODE;

-- 2. Удаляем предыдущее состояние витрины.
-- При ошибке дальнейшего наполнения удаление тоже откатится.
DELETE FROM marts.posting_control;

-- 3. Собираем состав отправлений и определяем завершённость.
WITH item_totals AS (
    -- Одна строка на отправление.
    SELECT
        scheme,
        posting_number,
        COUNT(*)::INTEGER AS positions_count,
        SUM(quantity)::INTEGER AS total_units
    FROM stg.posting_items
    GROUP BY scheme, posting_number
), posting_states AS (
    -- При отсутствии статуса завершённость остаётся неизвестной.
    SELECT
        p.*,
        CASE
            WHEN p.status IS NULL THEN NULL
            ELSE p.status NOT IN (
                'delivered',
                'cancelled',
                'cancelled_from_split_pending'
            )
        END AS is_unfinished
    FROM stg.postings AS p
)
INSERT INTO marts.posting_control (
    scheme,
    posting_number,
    order_id,
    order_number,
    status,
    substatus,
    processing_started_at,
    shipment_date,
    delivering_at,
    positions_count,
    total_units,
    is_unfinished,
    unfinished_age_hours,
    handoff_duration_hours,
    is_waiting_past_shipment_date,
    source_loaded_at,
    refreshed_at
)
SELECT
    p.scheme,
    p.posting_number,
    p.order_id,
    p.order_number,
    p.status,
    p.substatus,
    p.processing_started_at,
    p.shipment_date,
    p.delivering_at,
    i.positions_count,
    i.total_units,
    p.is_unfinished,
    -- EXTRACT(EPOCH FROM интервал) возвращает длительность в секундах.
    -- Делим на 3600, чтобы получить часы.
    CASE
        WHEN p.is_unfinished THEN
            (
                EXTRACT(EPOCH FROM (NOW() - p.processing_started_at))
                / 3600
            )::NUMERIC(18,3)
        ELSE NULL
    END AS unfinished_age_hours,
    -- Передача в доставку рассчитывается только для FBS.
    -- При отсутствии одной из дат результат автоматически будет NULL.
    CASE
        WHEN p.scheme = 'FBS' THEN
            (
                EXTRACT(EPOCH FROM (p.delivering_at - p.processing_started_at))
                / 3600
            )::NUMERIC(18,3)
        ELSE NULL
    END AS handoff_duration_hours,
    -- Признак ожидания после рекомендуемой даты отгрузки.
    -- BOOLEAN сохраняет NULL, если данных недостаточно для определения.
    CASE
        WHEN p.scheme = 'FBS' THEN
            p.is_unfinished
            AND p.delivering_at IS NULL
            AND p.shipment_date < NOW()
        ELSE NULL
    END AS is_waiting_past_shipment_date,
    p.source_loaded_at,
    NOW()
FROM posting_states AS p
LEFT JOIN item_totals AS i
    ON i.scheme = p.scheme
   AND i.posting_number = p.posting_number;

-- 4. Фиксация нового состояния витрины.
COMMIT;
