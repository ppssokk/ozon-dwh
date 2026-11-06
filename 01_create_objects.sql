-- 01_create_objects.sql | PostgreSQL 18
-- Создание структуры. Наполнение: 02_load_products.sql, 03_load_postings.sql, 04_load_assortment_performance.sql.
-- Слои: raw — исходные данные; meta — журнал; stg — подготовленные данные; marts — витрины.
-- Ограничения: pk_ — ключ; nn_ — NOT NULL; fk_ — связь; chk_ — CHECK; uq_ — уникальность.
-- Полное оглавление текущей версии:
-- 1. raw.products — исходные ответы API о товарах; повторные состояния сохраняются.
-- 2. meta.load_runs — журнал загрузок: время, статус, счётчики и ошибка.
-- 3. raw.postings — исходные ответы API об отправлениях FBO и FBS.
-- 4. stg.products — актуальный каталог; одна строка на товар.
-- 5. stg.product_sources — все SKU товара из массива sources.
-- 6. stg.postings — актуальные отправления; одна строка на схему и номер.
-- 7. stg.product_stocks — актуальные остатки из массива stocks.stocks.
-- 8. stg.posting_items — товарные позиции отправлений: количество и цена.
-- 9. marts.assortment_performance — результат ассортимента за период.
-- 10. marts.stock_overview — текущие остатки и количество заказанных единиц.
-- 11. marts.posting_control — контроль состояния и обработки отправлений.
-- Ниже отмечены группы полей, техническое происхождение данных и ограничения.

-- 1. RAW.PRODUCTS — исходные состояния товаров.
CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE raw.products (
    -- Технический номер исходной строки.
    raw_id BIGSERIAL
        CONSTRAINT nn_raw_products_raw_id NOT NULL,
    -- Идентификатор товара и полный исходный JSON.
    product_id BIGINT
        CONSTRAINT nn_raw_products_product_id NOT NULL,
    payload JSONB
        CONSTRAINT nn_raw_products_payload NOT NULL,
    -- Время получения и запуск загрузки.
    loaded_at TIMESTAMPTZ
        CONSTRAINT nn_raw_products_loaded_at NOT NULL,
    load_run_id UUID
        CONSTRAINT nn_raw_products_load_run_id NOT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_raw_products
        PRIMARY KEY (raw_id)
);

-- Описания ограничений raw.products.
COMMENT ON CONSTRAINT pk_raw_products ON raw.products
IS 'pk_ — PRIMARY KEY. Уникальный технический идентификатор строки raw.';

COMMENT ON CONSTRAINT nn_raw_products_raw_id ON raw.products
IS 'nn_ — NOT NULL. Технический идентификатор строки обязателен.';

COMMENT ON CONSTRAINT nn_raw_products_product_id ON raw.products
IS 'nn_ — NOT NULL. Идентификатор товара Ozon обязателен; повторы допускаются.';

COMMENT ON CONSTRAINT nn_raw_products_payload ON raw.products
IS 'nn_ — NOT NULL. Исходный JSON-объект товара обязателен.';

COMMENT ON CONSTRAINT nn_raw_products_loaded_at ON raw.products
IS 'nn_ — NOT NULL. Время получения данных обязательно.';

COMMENT ON CONSTRAINT nn_raw_products_load_run_id ON raw.products
IS 'nn_ — NOT NULL. Идентификатор запуска загрузки обязателен.';

-- Описания колонок raw.products.
COMMENT ON COLUMN raw.products.raw_id
IS 'Технический идентификатор строки. Генерируется PostgreSQL автоматически.';

COMMENT ON COLUMN raw.products.product_id
IS 'Идентификатор товара Ozon: поле id из ответа /v3/product/info/list. Повторы допускаются.';

COMMENT ON COLUMN raw.products.payload
IS 'Полный исходный JSON-объект одного товара, включая вложенные объекты и массивы.';

COMMENT ON COLUMN raw.products.loaded_at
IS 'Дата и время получения ответа API с данными товара.';

COMMENT ON COLUMN raw.products.load_run_id
IS 'Идентификатор запуска загрузки, в рамках которого получена запись. Ссылка на meta.load_runs.';

-- Описание таблицы raw.products.
COMMENT ON TABLE raw.products
IS 'Исходные данные товаров Ozon. Каждая загрузка добавляет новые строки; сохраняются повторные состояния товаров без очистки исходного JSON.';


-- 2. META.LOAD_RUNS — журнал запусков загрузки.
CREATE SCHEMA IF NOT EXISTS meta;

CREATE TABLE meta.load_runs (
    -- Идентификатор запуска и время его выполнения.
    load_run_id UUID
        CONSTRAINT nn_meta_load_runs_load_run_id NOT NULL,
    started_at TIMESTAMPTZ
        CONSTRAINT nn_meta_load_runs_started_at NOT NULL,
    finished_at TIMESTAMPTZ DEFAULT NULL,
    -- Результат загрузки: статус, счётчики и описание ошибки.
    status TEXT
        CONSTRAINT nn_meta_load_runs_status NOT NULL,
    received_count INT4
        CONSTRAINT nn_meta_load_runs_received_count NOT NULL,
    written_count INT4
        CONSTRAINT nn_meta_load_runs_written_count NOT NULL,
    error_message TEXT DEFAULT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_meta_load_runs
        PRIMARY KEY (load_run_id),
    CONSTRAINT chk_meta_load_runs_status
        CHECK (status IN ('running', 'success', 'failed')),
    CONSTRAINT chk_meta_load_runs_time_order
        CHECK (finished_at >= started_at)
);

-- Описания таблицы и колонок meta.load_runs.
COMMENT ON TABLE meta.load_runs
IS 'Журнал запусков загрузки: время выполнения, статус, количество полученных и записанных объектов, сведения об ошибке.';

COMMENT ON COLUMN meta.load_runs.load_run_id
IS 'Уникальный идентификатор запуска загрузки. Создаётся один раз и используется во всех записях этого запуска.';

COMMENT ON COLUMN meta.load_runs.started_at
IS 'Дата и время начала запуска загрузки.';

COMMENT ON COLUMN meta.load_runs.finished_at
IS 'Дата и время завершения запуска загрузки. NULL, пока запуск не завершён.';

COMMENT ON COLUMN meta.load_runs.status
IS 'Статус запуска: running — выполняется, success — успешно завершён, failed — завершён с ошибкой.';

COMMENT ON COLUMN meta.load_runs.received_count
IS 'Количество объектов, полученных из API в рамках запуска.';

COMMENT ON COLUMN meta.load_runs.written_count
IS 'Количество объектов, успешно записанных и зафиксированных в базе в рамках запуска.';

COMMENT ON COLUMN meta.load_runs.error_message
IS 'Описание ошибки загрузки. NULL, если ошибка не зафиксирована. Не должно содержать ключи API и пароли.';

-- Описания ограничений meta.load_runs.
COMMENT ON CONSTRAINT pk_meta_load_runs ON meta.load_runs
IS 'pk_ — PRIMARY KEY. Уникальность идентификатора запуска загрузки.';

COMMENT ON CONSTRAINT nn_meta_load_runs_load_run_id ON meta.load_runs
IS 'nn_ — NOT NULL. Идентификатор запуска обязателен.';

COMMENT ON CONSTRAINT nn_meta_load_runs_started_at ON meta.load_runs
IS 'nn_ — NOT NULL. Время начала запуска обязательно.';

COMMENT ON CONSTRAINT nn_meta_load_runs_status ON meta.load_runs
IS 'nn_ — NOT NULL. Статус запуска обязателен.';

COMMENT ON CONSTRAINT nn_meta_load_runs_received_count ON meta.load_runs
IS 'nn_ — NOT NULL. Количество полученных объектов обязательно; до получения данных указывается 0.';

COMMENT ON CONSTRAINT nn_meta_load_runs_written_count ON meta.load_runs
IS 'nn_ — NOT NULL. Количество записанных объектов обязательно; до записи данных указывается 0.';

COMMENT ON CONSTRAINT chk_meta_load_runs_status ON meta.load_runs
IS 'chk_ — CHECK. Допускает только статусы running, success и failed.';

COMMENT ON CONSTRAINT chk_meta_load_runs_time_order ON meta.load_runs
IS 'chk_ — CHECK. Время завершения не может быть раньше времени начала; NULL допускается.';


-- 3. RAW.POSTINGS — исходные отправления FBO и FBS.
CREATE TABLE raw.postings (
    -- Технический номер исходной строки.
    raw_id BIGSERIAL
        CONSTRAINT nn_raw_postings_raw_id NOT NULL,
    -- Отправление и полный исходный JSON.
    scheme TEXT
        CONSTRAINT nn_raw_postings_scheme NOT NULL,
    posting_number TEXT
        CONSTRAINT nn_raw_postings_posting_number NOT NULL,
    payload JSONB
        CONSTRAINT nn_raw_postings_payload NOT NULL,
    -- Время получения и запуск загрузки.
    loaded_at TIMESTAMPTZ
        CONSTRAINT nn_raw_postings_loaded_at NOT NULL,
    load_run_id UUID
        CONSTRAINT nn_raw_postings_load_run_id NOT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_raw_postings
        PRIMARY KEY (raw_id),
    CONSTRAINT chk_raw_postings_scheme
        CHECK (scheme IN ('FBO', 'FBS')),
    CONSTRAINT fk_raw_postings_load_run_id
        FOREIGN KEY (load_run_id)
        REFERENCES meta.load_runs (load_run_id)
);

-- Описания таблицы и колонок raw.postings.
COMMENT ON TABLE raw.postings
IS 'Исходные данные отправлений Ozon по схемам FBO и FBS. Каждая загрузка добавляет новые строки с полным JSON; повторные состояния сохраняются.';

COMMENT ON COLUMN raw.postings.raw_id
IS 'Технический идентификатор строки. Генерируется PostgreSQL автоматически.';

COMMENT ON COLUMN raw.postings.scheme
IS 'Схема отгрузки: FBO — со склада Ozon, FBS — со склада продавца с доставкой Ozon.';

COMMENT ON COLUMN raw.postings.posting_number
IS 'Номер отправления Ozon. Повторы допускаются для сохранения состояний из разных загрузок.';

COMMENT ON COLUMN raw.postings.payload
IS 'Полный исходный JSON-объект отправления, включая вложенный список товарных позиций.';

COMMENT ON COLUMN raw.postings.loaded_at
IS 'Дата и время получения ответа API с данными отправления.';

COMMENT ON COLUMN raw.postings.load_run_id
IS 'Идентификатор запуска, в рамках которого получена запись. Ссылка на meta.load_runs.';

-- Описания ограничений raw.postings.
COMMENT ON CONSTRAINT pk_raw_postings ON raw.postings
IS 'pk_ — PRIMARY KEY. Уникальный технический идентификатор строки.';

COMMENT ON CONSTRAINT nn_raw_postings_raw_id ON raw.postings
IS 'nn_ — NOT NULL. Технический идентификатор строки обязателен.';

COMMENT ON CONSTRAINT nn_raw_postings_scheme ON raw.postings
IS 'nn_ — NOT NULL. Схема отгрузки обязательна.';

COMMENT ON CONSTRAINT nn_raw_postings_posting_number ON raw.postings
IS 'nn_ — NOT NULL. Номер отправления обязателен.';

COMMENT ON CONSTRAINT nn_raw_postings_payload ON raw.postings
IS 'nn_ — NOT NULL. Исходный JSON-объект отправления обязателен.';

COMMENT ON CONSTRAINT nn_raw_postings_loaded_at ON raw.postings
IS 'nn_ — NOT NULL. Время получения данных обязательно.';

COMMENT ON CONSTRAINT nn_raw_postings_load_run_id ON raw.postings
IS 'nn_ — NOT NULL. Идентификатор запуска загрузки обязателен.';

COMMENT ON CONSTRAINT chk_raw_postings_scheme ON raw.postings
IS 'chk_ — CHECK. Допускает только схемы FBO и FBS.';

COMMENT ON CONSTRAINT fk_raw_postings_load_run_id ON raw.postings
IS 'fk_ — FOREIGN KEY. Запуск загрузки должен существовать в meta.load_runs.';

-- Схема stg: подготовленное актуальное состояние товаров и отправлений.
CREATE SCHEMA IF NOT EXISTS stg;

-- 4. stg.products — актуальный каталог; одна строка на товар.
CREATE TABLE stg.products (
    -- Идентификаторы, название и классификация товара.
    product_id BIGINT CONSTRAINT nn_stg_products_product_id NOT NULL,
    offer_id TEXT,
    sku BIGINT,
    name TEXT,
    description_category_id BIGINT,
    type_id BIGINT,
    -- Текущая цена каталога и её валюта.
    price NUMERIC,
    currency_code TEXT,
    -- Архивация, статус и дата обновления товара в Ozon.
    is_archived BOOLEAN,
    is_autoarchived BOOLEAN,
    product_status TEXT,
    product_updated_at TIMESTAMPTZ,
    -- Происхождение данных: исходная строка, время и выгрузка.
    source_raw_id BIGINT CONSTRAINT nn_stg_products_source_raw_id NOT NULL,
    source_loaded_at TIMESTAMPTZ CONSTRAINT nn_stg_products_source_loaded_at NOT NULL,
    load_run_id UUID CONSTRAINT nn_stg_products_load_run_id NOT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_stg_products PRIMARY KEY (product_id),
    CONSTRAINT fk_stg_products_source_raw_id FOREIGN KEY (source_raw_id) REFERENCES raw.products (raw_id),
    CONSTRAINT fk_stg_products_load_run_id FOREIGN KEY (load_run_id) REFERENCES meta.load_runs (load_run_id)
);

-- Описание таблицы stg.products.
COMMENT ON TABLE stg.products
IS 'Актуальное подготовленное состояние каталога Ozon. Одна строка на товар. История исходных ответов хранится в raw.products.';

-- Описания колонок stg.products.
COMMENT ON COLUMN stg.products.product_id
IS 'Идентификатор товара Ozon. Источник: payload.id.';

COMMENT ON COLUMN stg.products.offer_id
IS 'Артикул продавца. Источник: payload.offer_id.';

COMMENT ON COLUMN stg.products.sku
IS 'Основной SKU из payload.sku. Дополнительные SKU хранятся в stg.product_sources.';

COMMENT ON COLUMN stg.products.name
IS 'Название товара. Источник: payload.name.';

COMMENT ON COLUMN stg.products.description_category_id
IS 'Идентификатор категории товара. Источник: payload.description_category_id.';

COMMENT ON COLUMN stg.products.type_id
IS 'Идентификатор типа товара. Источник: payload.type_id.';

COMMENT ON COLUMN stg.products.price
IS 'Текущая предельная цена товара без акций по определению API. Источник: payload.price. Для расчёта сумм покупок используется цена позиции отправления.';

COMMENT ON COLUMN stg.products.currency_code
IS 'Валюта цены каталога. Источник: payload.currency_code.';

COMMENT ON COLUMN stg.products.is_archived
IS 'Признак ручной архивации товара. Источник: payload.is_archived.';

COMMENT ON COLUMN stg.products.is_autoarchived
IS 'Признак автоматической архивации товара. Источник: payload.is_autoarchived.';

COMMENT ON COLUMN stg.products.product_status
IS 'Текущий статус товара. Источник: payload.statuses.status.';

COMMENT ON COLUMN stg.products.product_updated_at
IS 'Дата и время обновления товара в Ozon. Источник: payload.updated_at.';

COMMENT ON COLUMN stg.products.source_raw_id
IS 'Идентификатор выбранной исходной строки raw.products.raw_id.';

COMMENT ON COLUMN stg.products.source_loaded_at
IS 'Время получения исходных данных. Источник: raw.products.loaded_at.';

COMMENT ON COLUMN stg.products.load_run_id
IS 'Идентификатор выгрузки, принесшей исходные данные. Источник: raw.products.load_run_id.';

-- Описания ограничений stg.products.
COMMENT ON CONSTRAINT pk_stg_products ON stg.products
IS 'pk_ — первичный ключ. В таблице хранится одно актуальное состояние каждого товара.';

COMMENT ON CONSTRAINT fk_stg_products_source_raw_id ON stg.products
IS 'fk_ — внешний ключ. Исходная строка должна существовать в raw.products.';

COMMENT ON CONSTRAINT fk_stg_products_load_run_id ON stg.products
IS 'fk_ — внешний ключ. Запуск загрузки должен существовать в meta.load_runs.';

-- 5. stg.product_sources — все SKU товара из массива sources.
CREATE TABLE stg.product_sources (
    -- Товар и позиция элемента в массиве sources.
    product_id BIGINT CONSTRAINT nn_stg_product_sources_product_id NOT NULL,
    source_position INTEGER CONSTRAINT nn_stg_product_sources_source_position NOT NULL,
    -- SKU и его источник в Ozon.
    sku BIGINT,
    source TEXT,
    -- Происхождение данных: исходная строка, время и выгрузка.
    source_raw_id BIGINT CONSTRAINT nn_stg_product_sources_source_raw_id NOT NULL,
    source_loaded_at TIMESTAMPTZ CONSTRAINT nn_stg_product_sources_source_loaded_at NOT NULL,
    load_run_id UUID CONSTRAINT nn_stg_product_sources_load_run_id NOT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_stg_product_sources PRIMARY KEY (product_id, source_position),
    CONSTRAINT fk_stg_product_sources_product_id FOREIGN KEY (product_id) REFERENCES stg.products (product_id),
    CONSTRAINT fk_stg_product_sources_source_raw_id FOREIGN KEY (source_raw_id) REFERENCES raw.products (raw_id),
    CONSTRAINT fk_stg_product_sources_load_run_id FOREIGN KEY (load_run_id) REFERENCES meta.load_runs (load_run_id)
);

-- Описание таблицы stg.product_sources.
COMMENT ON TABLE stg.product_sources
IS 'Актуальные соответствия товаров и их SKU из payload.sources. Одна строка на элемент массива sources одного товара.';

-- Описания колонок stg.product_sources.
COMMENT ON COLUMN stg.product_sources.product_id
IS 'Идентификатор товара Ozon, которому принадлежит элемент sources.';

COMMENT ON COLUMN stg.product_sources.source_position
IS 'Порядковый номер элемента в массиве payload.sources, начиная с 1. Может изменяться между выгрузками.';

COMMENT ON COLUMN stg.product_sources.sku
IS 'SKU товара из payload.sources[].sku. Уникальность в таблице не предполагается.';

COMMENT ON COLUMN stg.product_sources.source
IS 'Источник SKU из payload.sources[].source. Например, sds или fbo.';

COMMENT ON COLUMN stg.product_sources.source_raw_id
IS 'Идентификатор исходной строки raw.products.raw_id, из которой извлечён элемент sources.';

COMMENT ON COLUMN stg.product_sources.source_loaded_at
IS 'Время получения исходных данных. Источник: raw.products.loaded_at.';

COMMENT ON COLUMN stg.product_sources.load_run_id
IS 'Идентификатор выгрузки исходных данных. Источник: raw.products.load_run_id.';

-- Описания ограничений stg.product_sources.
COMMENT ON CONSTRAINT pk_stg_product_sources ON stg.product_sources
IS 'pk_ — первичный ключ. Определяет элемент массива sources внутри актуального состояния товара.';

COMMENT ON CONSTRAINT fk_stg_product_sources_product_id ON stg.product_sources
IS 'fk_ — внешний ключ. Товар должен существовать в stg.products.';

COMMENT ON CONSTRAINT fk_stg_product_sources_source_raw_id ON stg.product_sources
IS 'fk_ — внешний ключ. Исходная строка должна существовать в raw.products.';

COMMENT ON CONSTRAINT fk_stg_product_sources_load_run_id ON stg.product_sources
IS 'fk_ — внешний ключ. Запуск загрузки должен существовать в meta.load_runs.';

-- 6. stg.postings — актуальные отправления; одна строка на схему и номер.
CREATE TABLE stg.postings (
    -- Идентификаторы отправления и заказа.
    scheme TEXT CONSTRAINT nn_stg_postings_scheme NOT NULL,
    posting_number TEXT CONSTRAINT nn_stg_postings_posting_number NOT NULL,
    order_id BIGINT,
    order_number TEXT,
    -- Основной и уточняющий статусы Ozon.
    status TEXT,
    substatus TEXT,
    -- Даты обработки и доставки; shipment_date — срок отгрузки.
    created_at TIMESTAMPTZ,
    processing_started_at TIMESTAMPTZ,
    delivering_at TIMESTAMPTZ,
    shipment_date TIMESTAMPTZ,
    -- Происхождение данных: исходная строка, время и выгрузка.
    source_raw_id BIGINT CONSTRAINT nn_stg_postings_source_raw_id NOT NULL,
    source_loaded_at TIMESTAMPTZ CONSTRAINT nn_stg_postings_source_loaded_at NOT NULL,
    load_run_id UUID CONSTRAINT nn_stg_postings_load_run_id NOT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_stg_postings PRIMARY KEY (scheme, posting_number),
    CONSTRAINT chk_stg_postings_scheme CHECK (scheme IN ('FBO', 'FBS')),
    CONSTRAINT fk_stg_postings_source_raw_id FOREIGN KEY (source_raw_id) REFERENCES raw.postings (raw_id),
    CONSTRAINT fk_stg_postings_load_run_id FOREIGN KEY (load_run_id) REFERENCES meta.load_runs (load_run_id)
);

-- Описание таблицы stg.postings.
COMMENT ON TABLE stg.postings
IS 'Актуальные подготовленные сведения об отправлениях Ozon. Одна строка на сочетание схемы работы и номера отправления.';

-- Описания колонок stg.postings.
COMMENT ON COLUMN stg.postings.scheme
IS 'Схема работы: FBO или FBS. Источник: raw.postings.scheme.';

COMMENT ON COLUMN stg.postings.posting_number
IS 'Номер отправления. Источник: raw.postings.posting_number.';

COMMENT ON COLUMN stg.postings.order_id
IS 'Идентификатор заказа, к которому относится отправление. Источник: payload.order_id. Один заказ может содержать несколько отправлений.';

COMMENT ON COLUMN stg.postings.order_number
IS 'Номер заказа. Источник: payload.order_number.';

COMMENT ON COLUMN stg.postings.status
IS 'Основной статус отправления в исходном обозначении Ozon. Источник: payload.status.';

COMMENT ON COLUMN stg.postings.substatus
IS 'Уточняющий статус отправления в исходном обозначении Ozon. Источник: payload.substatus.';

COMMENT ON COLUMN stg.postings.created_at
IS 'Дата и время создания отправления, если поле доступно в ответе API. Источник: payload.created_at.';

COMMENT ON COLUMN stg.postings.processing_started_at
IS 'Дата и время начала обработки отправления. Источник: payload.in_process_at.';

COMMENT ON COLUMN stg.postings.delivering_at
IS 'Дата и время передачи отправления в доставку, если поле доступно. Источник: payload.delivering_date. Не является временем вручения покупателю.';

COMMENT ON COLUMN stg.postings.shipment_date
IS 'Рекомендованный срок отгрузки FBS. Источник: payload.shipment_date. Не является подтверждением фактической отгрузки.';

COMMENT ON COLUMN stg.postings.source_raw_id
IS 'Идентификатор выбранной исходной строки raw.postings.raw_id.';

COMMENT ON COLUMN stg.postings.source_loaded_at
IS 'Время получения исходных данных. Источник: raw.postings.loaded_at.';

COMMENT ON COLUMN stg.postings.load_run_id
IS 'Идентификатор выгрузки исходных данных. Источник: raw.postings.load_run_id.';

-- Описания ограничений stg.postings.
COMMENT ON CONSTRAINT pk_stg_postings ON stg.postings
IS 'pk_ — первичный ключ. В таблице хранится одно актуальное состояние отправления в рамках схемы работы.';

COMMENT ON CONSTRAINT chk_stg_postings_scheme ON stg.postings
IS 'chk_ — проверка допустимых значений схемы работы: FBO или FBS.';

COMMENT ON CONSTRAINT fk_stg_postings_source_raw_id ON stg.postings
IS 'fk_ — внешний ключ. Исходная строка должна существовать в raw.postings.';

COMMENT ON CONSTRAINT fk_stg_postings_load_run_id ON stg.postings
IS 'fk_ — внешний ключ. Запуск загрузки должен существовать в meta.load_runs.';

-- 7. stg.product_stocks — актуальные остатки из массива stocks.stocks.
CREATE TABLE stg.product_stocks (
    -- Товар и позиция элемента в массиве stocks.stocks.
    product_id BIGINT CONSTRAINT nn_stg_product_stocks_product_id NOT NULL,
    stock_position INTEGER CONSTRAINT nn_stg_product_stocks_stock_position NOT NULL,
    -- SKU, источник и исходные значения остатков.
    sku BIGINT,
    source TEXT,
    present INTEGER,
    reserved INTEGER,
    -- Происхождение данных: исходная строка, время и выгрузка.
    source_raw_id BIGINT CONSTRAINT nn_stg_product_stocks_source_raw_id NOT NULL,
    source_loaded_at TIMESTAMPTZ CONSTRAINT nn_stg_product_stocks_source_loaded_at NOT NULL,
    load_run_id UUID CONSTRAINT nn_stg_product_stocks_load_run_id NOT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_stg_product_stocks PRIMARY KEY (product_id, stock_position),
    CONSTRAINT fk_stg_product_stocks_product_id FOREIGN KEY (product_id) REFERENCES stg.products (product_id),
    CONSTRAINT fk_stg_product_stocks_source_raw_id FOREIGN KEY (source_raw_id) REFERENCES raw.products (raw_id),
    CONSTRAINT fk_stg_product_stocks_load_run_id FOREIGN KEY (load_run_id) REFERENCES meta.load_runs (load_run_id)
);

-- Описание таблицы stg.product_stocks.
COMMENT ON TABLE stg.product_stocks
IS 'Актуальные остатки товаров Ozon. Одна строка на элемент массива payload.stocks.stocks одного товара.';

-- Описания колонок stg.product_stocks.
COMMENT ON COLUMN stg.product_stocks.product_id
IS 'Идентификатор товара Ozon, которому принадлежит запись об остатке.';

COMMENT ON COLUMN stg.product_stocks.stock_position
IS 'Порядковый номер элемента в массиве payload.stocks.stocks, начиная с 1. Может изменяться между выгрузками.';

COMMENT ON COLUMN stg.product_stocks.sku
IS 'SKU, к которому относится остаток. Источник: payload.stocks.stocks[].sku.';

COMMENT ON COLUMN stg.product_stocks.source
IS 'Источник остатка. Например, fbo или fbs. Источник: payload.stocks.stocks[].source.';

COMMENT ON COLUMN stg.product_stocks.present
IS 'Исходное значение present из payload.stocks.stocks[].present. Отсутствующее значение не заменяется нулём.';

COMMENT ON COLUMN stg.product_stocks.reserved
IS 'Исходное значение reserved из payload.stocks.stocks[].reserved. Отсутствующее значение не заменяется нулём.';

COMMENT ON COLUMN stg.product_stocks.source_raw_id
IS 'Идентификатор исходной строки raw.products.raw_id, из которой извлечён остаток.';

COMMENT ON COLUMN stg.product_stocks.source_loaded_at
IS 'Время получения исходных данных. Источник: raw.products.loaded_at.';

COMMENT ON COLUMN stg.product_stocks.load_run_id
IS 'Идентификатор выгрузки исходных данных. Источник: raw.products.load_run_id.';

-- Описания ограничений stg.product_stocks.
COMMENT ON CONSTRAINT pk_stg_product_stocks ON stg.product_stocks
IS 'pk_ — первичный ключ. Определяет элемент массива остатков внутри актуального состояния товара.';

COMMENT ON CONSTRAINT fk_stg_product_stocks_product_id ON stg.product_stocks
IS 'fk_ — внешний ключ. Товар должен существовать в stg.products.';

COMMENT ON CONSTRAINT fk_stg_product_stocks_source_raw_id ON stg.product_stocks
IS 'fk_ — внешний ключ. Исходная строка должна существовать в raw.products.';

COMMENT ON CONSTRAINT fk_stg_product_stocks_load_run_id ON stg.product_stocks
IS 'fk_ — внешний ключ. Запуск загрузки должен существовать в meta.load_runs.';

-- 8. stg.posting_items — товарные позиции отправлений: количество и цена.
CREATE TABLE stg.posting_items (
    -- Отправление и номер его товарной позиции.
    scheme TEXT CONSTRAINT nn_stg_posting_items_scheme NOT NULL,
    posting_number TEXT CONSTRAINT nn_stg_posting_items_posting_number NOT NULL,
    position_no INTEGER CONSTRAINT nn_stg_posting_items_position_no NOT NULL,
    -- Идентификаторы товара и название из отправления.
    sku BIGINT,
    offer_id TEXT,
    product_id BIGINT,
    product_name TEXT,
    -- Количество, цена единицы и валюта из отправления.
    quantity INTEGER,
    unit_price NUMERIC,
    currency_code TEXT,
    -- Происхождение данных: исходная строка, время и выгрузка.
    source_raw_id BIGINT CONSTRAINT nn_stg_posting_items_source_raw_id NOT NULL,
    source_loaded_at TIMESTAMPTZ CONSTRAINT nn_stg_posting_items_source_loaded_at NOT NULL,
    load_run_id UUID CONSTRAINT nn_stg_posting_items_load_run_id NOT NULL,
    -- Первичный ключ и ограничения.
    CONSTRAINT pk_stg_posting_items PRIMARY KEY (scheme, posting_number, position_no),
    CONSTRAINT fk_stg_posting_items_posting FOREIGN KEY (scheme, posting_number) REFERENCES stg.postings (scheme, posting_number),
    CONSTRAINT fk_stg_posting_items_product_id FOREIGN KEY (product_id) REFERENCES stg.products (product_id),
    CONSTRAINT fk_stg_posting_items_source_raw_id FOREIGN KEY (source_raw_id) REFERENCES raw.postings (raw_id),
    CONSTRAINT fk_stg_posting_items_load_run_id FOREIGN KEY (load_run_id) REFERENCES meta.load_runs (load_run_id)
);

-- Описание таблицы stg.posting_items.
COMMENT ON TABLE stg.posting_items
IS 'Актуальный состав отправлений Ozon. Одна строка на элемент массива payload.products выбранного состояния отправления.';

-- Описания колонок stg.posting_items.
COMMENT ON COLUMN stg.posting_items.scheme
IS 'Схема работы: FBO или FBS. Источник: raw.postings.scheme.';

COMMENT ON COLUMN stg.posting_items.posting_number
IS 'Номер отправления, которому принадлежит позиция. Источник: raw.postings.posting_number.';

COMMENT ON COLUMN stg.posting_items.position_no
IS 'Порядковый номер элемента в массиве payload.products, начиная с 1. Может изменяться между выгрузками.';

COMMENT ON COLUMN stg.posting_items.sku
IS 'SKU позиции отправления. Источник: payload.products[].sku.';

COMMENT ON COLUMN stg.posting_items.offer_id
IS 'Артикул продавца, сохранённый в отправлении. Источник: payload.products[].offer_id.';

COMMENT ON COLUMN stg.posting_items.product_id
IS 'Идентификатор товара каталога, найденный по SKU через stg.product_sources. NULL, если однозначное соответствие не установлено.';

COMMENT ON COLUMN stg.posting_items.product_name
IS 'Название товара, сохранённое в отправлении. Источник: payload.products[].name.';

COMMENT ON COLUMN stg.posting_items.quantity
IS 'Количество единиц товара в позиции отправления. Источник: payload.products[].quantity.';

COMMENT ON COLUMN stg.posting_items.unit_price
IS 'Цена единицы товара из позиции отправления. Не заменяется текущей ценой каталога.';

COMMENT ON COLUMN stg.posting_items.currency_code
IS 'Валюта цены позиции отправления. При отсутствии в исходных данных не подставляется автоматически.';

COMMENT ON COLUMN stg.posting_items.source_raw_id
IS 'Идентификатор исходной строки raw.postings.raw_id, из которой извлечена позиция.';

COMMENT ON COLUMN stg.posting_items.source_loaded_at
IS 'Время получения исходных данных. Источник: raw.postings.loaded_at.';

COMMENT ON COLUMN stg.posting_items.load_run_id
IS 'Идентификатор выгрузки исходных данных. Источник: raw.postings.load_run_id.';

-- Описания ограничений stg.posting_items.
COMMENT ON CONSTRAINT pk_stg_posting_items ON stg.posting_items
IS 'pk_ — первичный ключ. Определяет позицию внутри актуального состава отправления.';

COMMENT ON CONSTRAINT fk_stg_posting_items_posting ON stg.posting_items
IS 'fk_ — внешний ключ. Отправление должно существовать в stg.postings.';

COMMENT ON CONSTRAINT fk_stg_posting_items_product_id ON stg.posting_items
IS 'fk_ — внешний ключ. Найденный товар должен существовать в stg.products. NULL допускается.';

COMMENT ON CONSTRAINT fk_stg_posting_items_source_raw_id ON stg.posting_items
IS 'fk_ — внешний ключ. Исходная строка должна существовать в raw.postings.';

COMMENT ON CONSTRAINT fk_stg_posting_items_load_run_id ON stg.posting_items
IS 'fk_ — внешний ключ. Запуск загрузки должен существовать в meta.load_runs.';


-- Схема marts: готовые показатели для аналитических отчётов.
CREATE SCHEMA IF NOT EXISTS marts;

-- 9. marts.assortment_performance — результат ассортимента за период.
CREATE TABLE marts.assortment_performance (
    -- Период и детализация показателей.
    period_start DATE CONSTRAINT nn_marts_assortment_performance_period_start NOT NULL,
    period_end DATE CONSTRAINT nn_marts_assortment_performance_period_end NOT NULL,
    scheme TEXT CONSTRAINT nn_marts_assortment_performance_scheme NOT NULL,
    sku BIGINT CONSTRAINT nn_marts_assortment_performance_sku NOT NULL,
    currency_code TEXT,
    -- Сведения о товаре.
    product_id BIGINT,
    offer_id TEXT,
    product_name TEXT,
    -- Результат отправлений, начавших обработку в выбранный период.
    postings_count INTEGER,
    ordered_units INTEGER,
    delivered_units INTEGER,
    cancelled_units INTEGER,
    other_units INTEGER,
    delivered_gross_amount NUMERIC(18,3),
    -- Сравнение периодов и относительные показатели.
    previous_ordered_units INTEGER,
    ordered_units_change_pct NUMERIC(18,3),
    delivered_gross_share_pct NUMERIC(18,3),
    cancelled_units_share_pct NUMERIC(18,3),
    -- Время пересчёта витрины.
    refreshed_at TIMESTAMPTZ CONSTRAINT nn_marts_assortment_performance_refreshed_at NOT NULL,
    -- Уникальность строки и связь с каталогом.
    CONSTRAINT uq_marts_assortment_performance_grain UNIQUE NULLS NOT DISTINCT (period_start, period_end, scheme, sku, currency_code),
    CONSTRAINT fk_marts_assortment_performance_product_id FOREIGN KEY (product_id) REFERENCES stg.products (product_id)
);

-- Описание таблицы marts.assortment_performance.
COMMENT ON TABLE marts.assortment_performance
IS 'Результативность ассортимента за выбранный период. Одна строка на период, схему работы, SKU и валюту. Период определяется по началу обработки отправления в Europe/Moscow, результат — по текущему статусу.';

-- Описания колонок marts.assortment_performance.
COMMENT ON COLUMN marts.assortment_performance.period_start
IS 'Первый день анализируемого периода включительно.';

COMMENT ON COLUMN marts.assortment_performance.period_end
IS 'Последний день анализируемого периода включительно.';

COMMENT ON COLUMN marts.assortment_performance.scheme
IS 'Схема работы отправлений: FBO или FBS.';

COMMENT ON COLUMN marts.assortment_performance.sku
IS 'SKU, по которому рассчитаны показатели. Сохраняется даже при отсутствии соответствия каталогу.';

COMMENT ON COLUMN marts.assortment_performance.currency_code
IS 'Валюта денежных показателей. Разные валюты рассчитываются отдельно. NULL означает, что валюта неизвестна.';

COMMENT ON COLUMN marts.assortment_performance.product_id
IS 'Идентификатор сопоставленного товара из stg.products. NULL, если соответствие не установлено.';

COMMENT ON COLUMN marts.assortment_performance.offer_id
IS 'Артикул продавца для отображения в отчёте.';

COMMENT ON COLUMN marts.assortment_performance.product_name
IS 'Название товара для отображения в отчёте.';

COMMENT ON COLUMN marts.assortment_performance.postings_count
IS 'Количество различных отправлений с данным SKU в выбранном периоде и валюте.';

COMMENT ON COLUMN marts.assortment_performance.ordered_units
IS 'Суммарное количество единиц товара в позициях отправлений выбранного периода независимо от текущего статуса.';

COMMENT ON COLUMN marts.assortment_performance.delivered_units
IS 'Количество единиц товара в отправлениях, отнесённых к доставленным.';

COMMENT ON COLUMN marts.assortment_performance.cancelled_units
IS 'Количество единиц товара в отправлениях, отнесённых к отменённым.';

COMMENT ON COLUMN marts.assortment_performance.other_units
IS 'Количество единиц товара в остальных состояниях, включая незавершённые отправления.';

COMMENT ON COLUMN marts.assortment_performance.delivered_gross_amount
IS 'Сумма quantity * unit_price по доставленным позициям. Без вычета расходов и возвратов. Округляется до трёх знаков после запятой.';

COMMENT ON COLUMN marts.assortment_performance.previous_ordered_units
IS 'Количество единиц товара за предыдущий непосредственно примыкающий период той же длины, схемы, SKU и валюты.';

COMMENT ON COLUMN marts.assortment_performance.ordered_units_change_pct
IS 'Изменение ordered_units относительно previous_ordered_units в процентах. NULL при нулевой или неизвестной базе сравнения. Три знака после запятой.';

COMMENT ON COLUMN marts.assortment_performance.delivered_gross_share_pct
IS 'Доля SKU в общей стоимости доставленных позиций за тот же период, схему и валюту, в процентах. NULL, если знаменатель нулевой или неизвестен. Три знака после запятой.';

COMMENT ON COLUMN marts.assortment_performance.cancelled_units_share_pct
IS 'cancelled_units / (delivered_units + cancelled_units) * 100. NULL при нулевом или неизвестном знаменателе. Не является официальным показателем выкупа Ozon. Три знака после запятой.';

COMMENT ON COLUMN marts.assortment_performance.refreshed_at
IS 'Дата и время последнего пересчёта строки витрины.';

-- Описания ограничений marts.assortment_performance.
COMMENT ON CONSTRAINT uq_marts_assortment_performance_grain ON marts.assortment_performance
IS 'uq_ — уникальность сочетания периода, схемы, SKU и валюты. NULL в currency_code считается одинаковым значением для определения дубликатов.';

COMMENT ON CONSTRAINT fk_marts_assortment_performance_product_id ON marts.assortment_performance
IS 'fk_ — внешний ключ. Сопоставленный товар должен существовать в stg.products. NULL допускается.';


-- 10. marts.stock_overview — текущие остатки и количество заказанных единиц.
CREATE TABLE marts.stock_overview (
    -- Товар, SKU и схема работы.
    product_id BIGINT CONSTRAINT nn_marts_stock_overview_product_id NOT NULL,
    sku BIGINT CONSTRAINT nn_marts_stock_overview_sku NOT NULL,
    scheme TEXT CONSTRAINT nn_marts_stock_overview_scheme NOT NULL,
    -- Сведения о карточке товара.
    offer_id TEXT,
    product_name TEXT,
    product_status TEXT,
    -- Исходные значения остатков из Ozon.
    present INTEGER,
    reserved INTEGER,
    -- Заказанные единицы за последние 28 полных дней.
    ordered_units_28d INTEGER,
    avg_daily_ordered_units NUMERIC(18,3),
    period_start DATE CONSTRAINT nn_marts_stock_overview_period_start NOT NULL,
    period_end DATE CONSTRAINT nn_marts_stock_overview_period_end NOT NULL,
    -- Время загрузки остатков и пересчёта витрины.
    stock_loaded_at TIMESTAMPTZ CONSTRAINT nn_marts_stock_overview_stock_loaded_at NOT NULL,
    refreshed_at TIMESTAMPTZ CONSTRAINT nn_marts_stock_overview_refreshed_at NOT NULL,
    -- Уникальность строки и связь с каталогом.
    CONSTRAINT uq_marts_stock_overview_grain UNIQUE (product_id, sku, scheme),
    CONSTRAINT fk_marts_stock_overview_product_id FOREIGN KEY (product_id) REFERENCES stg.products (product_id)
);

-- Описание таблицы marts.stock_overview.
COMMENT ON TABLE marts.stock_overview
IS 'Текущие остатки и количество заказанных единиц за последние 28 полных дней. Одна строка на товар, SKU и схему работы. История состояний остатков не накапливается.';

-- Описания колонок marts.stock_overview.
COMMENT ON COLUMN marts.stock_overview.product_id
IS 'Идентификатор товара из stg.products.';

COMMENT ON COLUMN marts.stock_overview.sku
IS 'SKU из записи об остатках товара.';

COMMENT ON COLUMN marts.stock_overview.scheme
IS 'Схема работы: FBO или FBS. Определяется по источнику записи об остатках.';

COMMENT ON COLUMN marts.stock_overview.offer_id
IS 'Артикул продавца из текущего каталога.';

COMMENT ON COLUMN marts.stock_overview.product_name
IS 'Название товара из текущего каталога.';

COMMENT ON COLUMN marts.stock_overview.product_status
IS 'Текущий статус карточки товара из stg.products.product_status.';

COMMENT ON COLUMN marts.stock_overview.present
IS 'Значение present из данных Ozon об остатках. Резерв дополнительно не вычитается. NULL означает неизвестное значение.';

COMMENT ON COLUMN marts.stock_overview.reserved
IS 'Количество единиц в резерве по данным Ozon. NULL означает неизвестное значение.';

COMMENT ON COLUMN marts.stock_overview.ordered_units_28d
IS 'Количество заказанных единиц за указанный период по SKU и схеме работы. Суммируется по валютам из marts.assortment_performance независимо от текущего статуса отправления.';

COMMENT ON COLUMN marts.stock_overview.avg_daily_ordered_units
IS 'Среднее количество заказанных единиц за календарный день: ordered_units_28d / 28. Учитываются дни без заказов. Три знака после запятой.';

COMMENT ON COLUMN marts.stock_overview.period_start
IS 'Первый день периода заказов включительно, по московскому времени.';

COMMENT ON COLUMN marts.stock_overview.period_end
IS 'Последний день периода заказов включительно, по московскому времени.';

COMMENT ON COLUMN marts.stock_overview.stock_loaded_at
IS 'Дата и время загрузки исходной записи об остатках. Не является временем последнего изменения остатков в Ozon.';

COMMENT ON COLUMN marts.stock_overview.refreshed_at
IS 'Дата и время последнего пересчёта строки витрины.';

-- Описания ограничений marts.stock_overview.
COMMENT ON CONSTRAINT uq_marts_stock_overview_grain ON marts.stock_overview
IS 'uq_ — уникальность сочетания товара, SKU и схемы работы в текущем состоянии витрины.';

COMMENT ON CONSTRAINT fk_marts_stock_overview_product_id ON marts.stock_overview
IS 'fk_ — внешний ключ. Товар должен существовать в stg.products.';


-- 11. marts.posting_control — контроль состояния и обработки отправлений.
CREATE TABLE marts.posting_control (
    -- Отправление и связанный заказ.
    scheme TEXT CONSTRAINT nn_marts_posting_control_scheme NOT NULL,
    posting_number TEXT CONSTRAINT nn_marts_posting_control_posting_number NOT NULL,
    order_id BIGINT,
    order_number TEXT,
    -- Последнее загруженное состояние отправления.
    status TEXT,
    substatus TEXT,
    -- Даты обработки и отгрузки.
    processing_started_at TIMESTAMPTZ,
    shipment_date TIMESTAMPTZ,
    delivering_at TIMESTAMPTZ,
    -- Состав отправления.
    positions_count INTEGER,
    total_units INTEGER,
    -- Расчётные признаки и длительности.
    is_unfinished BOOLEAN,
    unfinished_age_hours NUMERIC(18,3),
    handoff_duration_hours NUMERIC(18,3),
    is_waiting_past_shipment_date BOOLEAN,
    -- Время загрузки исходного состояния и пересчёта витрины.
    source_loaded_at TIMESTAMPTZ CONSTRAINT nn_marts_posting_control_source_loaded_at NOT NULL,
    refreshed_at TIMESTAMPTZ CONSTRAINT nn_marts_posting_control_refreshed_at NOT NULL,
    -- Первичный ключ и связь с подготовленным отправлением.
    CONSTRAINT pk_marts_posting_control PRIMARY KEY (scheme, posting_number),
    CONSTRAINT fk_marts_posting_control_posting FOREIGN KEY (scheme, posting_number) REFERENCES stg.postings (scheme, posting_number)
);

-- Описание таблицы marts.posting_control.
COMMENT ON TABLE marts.posting_control
IS 'Контроль последнего загруженного состояния отправлений FBO и FBS. Одна строка на схему работы и номер отправления. История состояний не накапливается.';

-- Описания колонок marts.posting_control.
COMMENT ON COLUMN marts.posting_control.scheme
IS 'Схема работы отправления: FBO или FBS.';

COMMENT ON COLUMN marts.posting_control.posting_number
IS 'Номер отправления, полученный из Ozon API.';

COMMENT ON COLUMN marts.posting_control.order_id
IS 'Идентификатор заказа, к которому относится отправление.';

COMMENT ON COLUMN marts.posting_control.order_number
IS 'Номер заказа, к которому относится отправление.';

COMMENT ON COLUMN marts.posting_control.status
IS 'Последний загруженный статус отправления из stg.postings.';

COMMENT ON COLUMN marts.posting_control.substatus
IS 'Уточняющий статус отправления из stg.postings.';

COMMENT ON COLUMN marts.posting_control.processing_started_at
IS 'Дата и время начала обработки отправления.';

COMMENT ON COLUMN marts.posting_control.shipment_date
IS 'Рекомендуемая дата и время отгрузки FBS. Не является фактической датой передачи в доставку.';

COMMENT ON COLUMN marts.posting_control.delivering_at
IS 'Дата и время передачи FBS в доставку. Не является датой вручения покупателю.';

COMMENT ON COLUMN marts.posting_control.positions_count
IS 'Количество товарных позиций отправления из stg.posting_items. Не является количеством различных SKU.';

COMMENT ON COLUMN marts.posting_control.total_units
IS 'Суммарное количество единиц товара во всех позициях отправления.';

COMMENT ON COLUMN marts.posting_control.is_unfinished
IS 'FALSE для статусов delivered, cancelled и cancelled_from_split_pending; TRUE для остальных известных статусов. NULL, если статус отсутствует.';

COMMENT ON COLUMN marts.posting_control.unfinished_age_hours
IS 'Часы от начала обработки незавершённого отправления до пересчёта витрины. Не является временем нахождения в текущем статусе. NULL для завершённых отправлений, неизвестного статуса или отсутствующей даты начала обработки.';

COMMENT ON COLUMN marts.posting_control.handoff_duration_hours
IS 'Часы от начала обработки FBS до передачи в доставку. NULL для FBO или при отсутствии необходимых дат.';

COMMENT ON COLUMN marts.posting_control.is_waiting_past_shipment_date
IS 'TRUE, если незавершённое FBS ещё не передано в доставку и рекомендуемая дата отгрузки прошла. FALSE, если условие не выполнено. NULL для FBO или при недостатке данных для определения признака. Не является официальным показателем нарушения SLA Ozon.';

COMMENT ON COLUMN marts.posting_control.source_loaded_at
IS 'Дата и время загрузки исходного состояния отправления. Не является временем последнего изменения статуса в Ozon.';

COMMENT ON COLUMN marts.posting_control.refreshed_at
IS 'Дата и время последнего пересчёта строки витрины.';

-- Описания ограничений marts.posting_control.
COMMENT ON CONSTRAINT pk_marts_posting_control ON marts.posting_control
IS 'pk_ — первичный ключ. Одна строка на сочетание схемы работы и номера отправления.';

COMMENT ON CONSTRAINT fk_marts_posting_control_posting ON marts.posting_control
IS 'fk_ — внешний ключ. Отправление должно существовать в stg.postings.';


SELECT *
FROM stg.products p
LIMIT 5;

