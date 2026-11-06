"""Функции извлечения и загрузки данных Ozon."""

import requests as rq
from datetime import datetime, timezone
from uuid import uuid4
import psycopg
from psycopg.types.json import Jsonb




base_url = "https://api-seller.ozon.ru"



def get_product_list(base_url, headers):
    endpoint = '/v3/product/list'
    url = base_url + endpoint

    product_list = []
    counter = 0
    last_id = ""

    while True:
        payload = {
            "filter": {"visibility": "ALL"},
            "last_id": last_id,
            "limit": 1000,
        }

        response = rq.post(
            url,
            headers=headers,
            json=payload,
            timeout=30
        )
        response.raise_for_status()
        data = response.json()
        total_items = data["result"]["total_items"]

        items = data["result"]["items"]

        if not items:
            break

        for item in items:
            product_list.append({
                "offer_id": item["offer_id"],
                "product_id": item["product_id"],
                "sku": item["sku"]
            })

        last_id = data["result"]["last_id"]
        counter += len(items)

        if counter >= total_items:
            break

    print("Получено товаров:", len(product_list))

    print("Ожидали:", total_items)
    print("Получили:", counter)
    return product_list


def get_product_details(product_list, base_url, headers):
    endpoint = "/v3/product/info/list"
    url = base_url + endpoint

    product_ids = [str(item["product_id"]) for item in product_list]

    batch_size = 1000
    final_data = []
    load_run_id = uuid4()

    for start in range(0, len(product_ids), batch_size):
        batch = product_ids[start:start + batch_size]

        payload = {
            "product_id": batch
        }

        response = rq.post(
            url,
            headers=headers,
            json=payload,
            timeout=30
        )
        response.raise_for_status()

        data = response.json()
        loaded_at = datetime.now(timezone.utc)

        final_data.extend([
            {
                "product_id": item["id"],
                "payload": item,
                "loaded_at": loaded_at,
                "load_run_id": load_run_id
            }
            for item in data["items"]
        ])
    return final_data, load_run_id


def check_db_connection(db_config):
    with psycopg.connect(**db_config) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_database(), current_user;")
            print(cur.fetchone())


def load_products(final_data, load_run_id, db_config):
    if any(row["load_run_id"] != load_run_id for row in final_data):
        raise ValueError("В final_data найдены записи другого запуска")

    with psycopg.connect(**db_config, autocommit=True) as conn:

        conn.execute(
            """
        INSERT INTO meta.load_runs (
            load_run_id,
            started_at,
            status,
            received_count,
            written_count
        )
        VALUES (%s, %s, %s, %s, %s);
        """,
            (
                load_run_id,
                datetime.now(timezone.utc),
                "running",
                len(final_data),
                0
            )
        )

        try:
            with conn.transaction():
                with conn.cursor() as cur:
                    with cur.copy(
                        """
                    COPY raw.products (
                        product_id,
                        payload,
                        loaded_at,
                        load_run_id
                    )
                    FROM STDIN
                    """
                    ) as copy:
                        for row in final_data:
                            copy.write_row((
                                row["product_id"],
                                Jsonb(row["payload"]),
                                row["loaded_at"],
                                row["load_run_id"]
                            ))

                    cur.execute(
                        """
                    UPDATE meta.load_runs
                    SET finished_at = %s,
                        status = %s,
                        written_count = %s
                    WHERE load_run_id = %s;
                    """,
                        (
                            datetime.now(timezone.utc),
                            "success",
                            len(final_data),
                            load_run_id
                        )
                    )

        except Exception as error:
            try:
                conn.execute(
                    """
                UPDATE meta.load_runs
                SET finished_at = %s,
                    status = %s,
                    written_count = %s,
                    error_message = %s
                WHERE load_run_id = %s;
                """,
                    (
                        datetime.now(timezone.utc),
                        "failed",
                        0,
                        str(error),
                        load_run_id
                    )
                )
            except Exception as log_error:
                print("Не удалось записать ошибку в журнал:", log_error)
            raise

    print("Запуск:", load_run_id)
    print("Записано товаров:", len(final_data))


def get_fbo_postings(base_url, headers, since, to, load_run_id):
    url = base_url + "/v3/posting/fbo/list"
    final_data = []
    cursor = ""
    seen_cursors = {cursor}

    while True:
        payload = {
            "cursor": cursor,
            "filter": {"since": since, "to": to},
            "limit": 100,
            "with": {"analytics_data": True, "financial_data": True},
        }
        response = rq.post(url, headers=headers, json=payload, timeout=30)
        response.raise_for_status()
        data = response.json()

        postings = data["postings"]
        has_next = data["has_next"]
        if not isinstance(postings, list) or not isinstance(has_next, bool):
            raise ValueError("Неожиданная структура ответа FBO: postings/has_next")

        loaded_at = datetime.now(timezone.utc)
        final_data.extend([
            {
                "scheme": "FBO",
                "posting_number": posting["posting_number"],
                "payload": posting,
                "loaded_at": loaded_at,
                "load_run_id": load_run_id,
            }
            for posting in postings
        ])

        if not has_next:
            break

        next_cursor = data["cursor"]
        if not isinstance(next_cursor, str) or not next_cursor or next_cursor in seen_cursors:
            raise ValueError("Ошибка пагинации FBO: курсор пустой или повторяется")
        seen_cursors.add(next_cursor)
        cursor = next_cursor

    return final_data


def get_fbs_postings(base_url, headers, since, to, load_run_id):
    url = base_url + "/v4/posting/fbs/list"
    final_data = []
    cursor = ""
    seen_cursors = {cursor}

    while True:
        payload = {
            "cursor": cursor,
            "filter": {"since": since, "to": to},
            "limit": 100,
            "with": {"analytics_data": True, "financial_data": True},
        }
        response = rq.post(url, headers=headers, json=payload, timeout=30)
        response.raise_for_status()
        data = response.json()

        postings = data["postings"]
        has_next = data["has_next"]
        if not isinstance(postings, list) or not isinstance(has_next, bool):
            raise ValueError("Неожиданная структура ответа FBS: postings/has_next")

        loaded_at = datetime.now(timezone.utc)
        final_data.extend([
            {
                "scheme": "FBS",
                "posting_number": posting["posting_number"],
                "payload": posting,
                "loaded_at": loaded_at,
                "load_run_id": load_run_id,
            }
            for posting in postings
        ])

        if not has_next:
            break

        next_cursor = data["cursor"]
        if not isinstance(next_cursor, str) or not next_cursor or next_cursor in seen_cursors:
            raise ValueError("Ошибка пагинации FBS: курсор пустой или повторяется")
        seen_cursors.add(next_cursor)
        cursor = next_cursor

    return final_data


def load_postings(fbo_data, fbs_data, load_run_id, db_config):
    for rows, scheme in ((fbo_data, "FBO"), (fbs_data, "FBS")):
        for row in rows:
            if row["load_run_id"] != load_run_id or row["scheme"] != scheme:
                raise ValueError("Массив отправлений относится к другой схеме или запуску")

    received_count = len(fbo_data) + len(fbs_data)

    with psycopg.connect(**db_config, autocommit=True) as conn:
        conn.execute(
            """
            INSERT INTO meta.load_runs (
                load_run_id, started_at, status, received_count, written_count
            )
            VALUES (%s, %s, %s, %s, %s);
            """,
            (load_run_id, datetime.now(timezone.utc), "running", received_count, 0),
        )

        try:
            with conn.transaction():
                with conn.cursor() as cur:
                    with cur.copy(
                        """
                        COPY raw.postings (
                            scheme, posting_number, payload, loaded_at, load_run_id
                        )
                        FROM STDIN
                        """
                    ) as copy:
                        for rows in (fbo_data, fbs_data):
                            for row in rows:
                                copy.write_row((
                                    row["scheme"],
                                    row["posting_number"],
                                    Jsonb(row["payload"]),
                                    row["loaded_at"],
                                    row["load_run_id"],
                                ))

                    cur.execute(
                        """
                        UPDATE meta.load_runs
                        SET finished_at = %s,
                            status = %s,
                            written_count = %s
                        WHERE load_run_id = %s;
                        """,
                        (datetime.now(timezone.utc), "success", received_count, load_run_id),
                    )

        except Exception as error:
            try:
                conn.execute(
                    """
                    UPDATE meta.load_runs
                    SET finished_at = %s,
                        status = %s,
                        written_count = %s,
                        error_message = %s
                    WHERE load_run_id = %s;
                    """,
                    (datetime.now(timezone.utc), "failed", 0, str(error), load_run_id),
                )
            except Exception as log_error:
                print("Не удалось записать ошибку в журнал:", log_error)
            raise

    return received_count
