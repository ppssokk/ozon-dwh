
"""Точка запуска загрузки данных Ozon."""

import argparse
import os
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from ozon_functions import (
    base_url,
    check_db_connection,
    get_product_list,
    get_product_details,
    load_products,
    get_fbo_postings,
    get_fbs_postings,
    load_postings,
)


def choose_period(mode, since=None, to=None, now=None):
    """Возвращает границы периода в UTC в формате для Ozon API."""
    now = now or datetime.now(timezone.utc)
    now = now.astimezone(timezone.utc).replace(microsecond=0)
    earliest = now - timedelta(days=365)

    if mode in ("regular", "year"):
        if since is not None or to is not None:
            raise ValueError("Даты можно передавать только для режима custom")
        start = now - timedelta(days=56 if mode == "regular" else 364)
        end = now
    elif mode == "custom":
        if not since or not to:
            raise ValueError("Для custom укажите начало и конец периода")
        try:
            start = datetime.fromisoformat(since)
            end = datetime.fromisoformat(to)
        except ValueError as exc:
            raise ValueError("Даты должны быть в формате ISO 8601 с часовым поясом") from exc
        if start.utcoffset() is None or end.utcoffset() is None:
            raise ValueError("Укажите часовой пояс для обеих дат, например +03:00 или Z")
        start = start.astimezone(timezone.utc)
        end = end.astimezone(timezone.utc)
        if start < earliest:
            raise ValueError("Начало периода не может быть раньше последних 365 дней")
        if end > now:
            raise ValueError("Конец периода не может быть в будущем")
        if start >= end:
            raise ValueError("Начало периода должно быть раньше конца")
        if end - start > timedelta(days=364):
            raise ValueError("Длина периода не может превышать 364 дня")
    else:
        raise ValueError("Режим должен быть regular, year или custom")

    return (start.isoformat().replace("+00:00", "Z"),
            end.isoformat().replace("+00:00", "Z"))


# Явно связываем каждого продавца с ключами API и подключением к его базе.
SELLERS = {
    "seller_1": {
        "connection_id": "ozon_dwh",
        "client_id_env": "OZON_CLIENT_ID",
        "api_key_env": "OZON_API_KEY",
    },
    "seller_2": {
        "connection_id": "ozon_dwh_seller2",
        "client_id_env": "OZON_CLIENT_ID_2",
        "api_key_env": "OZON_API_KEY_2",
    },
}


def get_seller_settings(seller):
    try:
        return SELLERS[seller]
    except KeyError as exc:
        raise ValueError("Неизвестный продавец") from exc


def get_headers(seller):
    settings = get_seller_settings(seller)
    client_id = os.environ.get(settings["client_id_env"], "").strip()
    api_key = os.environ.get(settings["api_key_env"], "").strip()
    if not client_id or not api_key:
        raise ValueError(f"Для {seller} не заданы Client-Id или API-ключ")
    return {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}


def get_db_config(seller):
    """Берём данные подключения из сохранённого соединения Airflow."""
    from airflow.providers.postgres.hooks.postgres import PostgresHook

    connection_id = get_seller_settings(seller)["connection_id"]
    connection = PostgresHook(postgres_conn_id=connection_id).get_connection(connection_id)
    return {
        "host": connection.host,
        "port": connection.port or 5432,
        "dbname": connection.schema,
        "user": connection.login,
        "password": connection.password,
        "connect_timeout": 10,
    }


def main(mode="regular", since=None, to=None, seller="seller_1"):
    # Получаем API и настройки базы для одного выбранного продавца.
    headers = get_headers(seller)
    db_config = get_db_config(seller)
    check_db_connection(db_config)
    since, to = choose_period(mode, since, to)

    product_list = get_product_list(base_url, headers)
    final_data, load_run_id = get_product_details(product_list, base_url, headers)
    load_products(final_data, load_run_id, db_config)

    postings_run_id = uuid4()
    fbo_data = get_fbo_postings(base_url, headers, since, to, postings_run_id)
    fbs_data = get_fbs_postings(base_url, headers, since, to, postings_run_id)
    written_count = load_postings(fbo_data, fbs_data, postings_run_id, db_config)
    print("Запуск отправлений:", postings_run_id)
    print("FBO:", len(fbo_data))
    print("FBS:", len(fbs_data))
    print("Записано отправлений:", written_count)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Загрузка данных Ozon")
    parser.add_argument("--seller", choices=("seller_1", "seller_2"), default="seller_1")
    parser.add_argument("--mode", choices=("regular", "year", "custom"), default="regular")
    parser.add_argument("--since", help="Начало периода ISO 8601 с часовым поясом")
    parser.add_argument("--to", help="Конец периода ISO 8601 с часовым поясом")
    args = parser.parse_args()
    main(mode=args.mode, since=args.since, to=args.to, seller=args.seller)
