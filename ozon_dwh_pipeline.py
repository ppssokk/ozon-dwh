"""Ручной запуск загрузки Ozon и обновления хранилища."""
from datetime import datetime, timezone
from pathlib import Path
import sys

from airflow.sdk import Param, dag, get_current_context, task


@dag(
    dag_id="ozon_dwh_pipeline",
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    schedule=None,
    catchup=False,
    max_active_runs=1,
    params={
        "seller": Param("seller_1", enum=["seller_1", "seller_2"], description="Выберите продавца"),
        "initialize": Param(False, type="boolean", description="Создать структуру при первом запуске и загрузить 364 дня"),
        "mode": Param("regular", enum=["regular", "year", "custom"]),
        "since": Param(None, type=["null", "string"]),
        "to": Param(None, type=["null", "string"]),
    },
    tags=["ozon", "dwh"],
)
def ozon_dwh_pipeline():
    @task
    def prepare_schema():
        # Инициализацию включаем явно при первом запуске.
        params = get_current_context()["params"]
        sys.path.insert(0, "/opt/airflow/project")
        from main import get_headers, get_seller_settings
        get_headers(params["seller"])
        connection_id = get_seller_settings(params["seller"])["connection_id"]
        if not params["initialize"]:
            print("Инициализация не запрошена")
            return
        if params["mode"] == "custom" or params["since"] is not None or params["to"] is not None:
            raise ValueError("Для первой загрузки не задавайте свои даты: будет загружено 364 дня")
        from airflow.providers.postgres.hooks.postgres import PostgresHook

        tables = (
            "raw.products", "raw.postings", "meta.load_runs",
            "stg.products", "stg.product_sources", "stg.product_stocks",
            "stg.postings", "stg.posting_items",
            "marts.assortment_performance", "marts.stock_overview", "marts.posting_control",
        )
        hook = PostgresHook(postgres_conn_id=connection_id)
        connection = hook.get_conn()
        try:
            with connection.cursor() as cursor:
                present = []
                for table in tables:
                    cursor.execute("SELECT to_regclass(%s)", (table,))
                    if cursor.fetchone()[0] is not None:
                        present.append(table)
                if len(present) == len(tables):
                    print("Все таблицы уже существуют; создание пропущено")
                elif present:
                    raise RuntimeError("В базе найдена только часть таблиц проекта; сначала проверь структуру")
                else:
                    sql = Path("/opt/airflow/sql/01_create_objects.sql").read_text(encoding="utf-8")
                    cursor.execute(sql)
                    print("Схемы и таблицы созданы")
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    @task
    def load_raw():
        # Подключаем файлы проекта только во время выполнения задачи.
        sys.path.insert(0, "/opt/airflow/project")
        from main import main

        params = get_current_context()["params"]
        # Первая загрузка охватывает 364 дня.
        mode = "year" if params["initialize"] else params["mode"]
        main(mode=mode, since=params["since"], to=params["to"], seller=params["seller"])

    @task
    def execute_sql(filename):
        # Каждый SQL-файл содержит собственные BEGIN и COMMIT.
        from airflow.providers.postgres.hooks.postgres import PostgresHook

        sql = (Path("/opt/airflow/sql") / filename).read_text(encoding="utf-8")
        sys.path.insert(0, "/opt/airflow/project")
        from main import get_seller_settings
        params = get_current_context()["params"]
        connection_id = get_seller_settings(params["seller"])["connection_id"]
        hook = PostgresHook(postgres_conn_id=connection_id)
        connection = hook.get_conn()
        try:
            connection.autocommit = True
            with connection.cursor() as cursor:
                cursor.execute(sql)
        finally:
            connection.close()
        print(f"Выполнен SQL-файл: {filename}")

    schema = prepare_schema()
    raw = load_raw()
    products = execute_sql.override(task_id="load_stg_products")("02_load_products.sql")
    postings = execute_sql.override(task_id="load_stg_postings")("03_load_postings.sql")
    assortment = execute_sql.override(task_id="load_assortment_performance")("04_load_assortment_performance.sql")
    stock = execute_sql.override(task_id="load_stock_overview")("05_load_stock_overview.sql")
    posting_control = execute_sql.override(task_id="load_posting_control")("06_load_posting_control.sql")

    schema >> raw >> products >> postings >> assortment >> stock
    postings >> posting_control


ozon_dwh_pipeline()
