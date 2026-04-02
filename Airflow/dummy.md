Good. Since the current run finished, do **not** use `datalike_column_lineage` for visible lineage.

Use this replacement model:

* keep `datalike_dataset`
* keep `datalike_process`
* keep `datalike_column`
* replace visible column-lineage logic with **`datalike_column_process` extends `Process`**

  * one entity per source column → destination column mapping
  * `inputs` = source column entity
  * `outputs` = destination column entity

That is what Atlas can traverse as lineage.

# What to do now

## Phase 1

Keep existing data.

## Phase 2

Run a **replacement backfill DAG** that creates:

* missing `datalike_column`
* new `datalike_column_process`

## Phase 3

Switch to a **single merged production DAG** that creates:

* table datasets
* table processes
* columns
* column processes

## Phase 4

Ignore or later delete old `datalike_column_lineage` entities if you do not need them.

---

# New Airflow variable

Create this one:

```text
gca_atlas_column_process_backfill_last_governance_id = 0
```

---

# Replacement backfill DAG

Save as:

```python
# dags/gca_atlas_column_process_backfill_dag.py
```

```python
import json
import logging
import os
import re
import subprocess
import tempfile
from datetime import datetime, timedelta

from airflow import DAG
from airflow.decorators import task
from airflow.exceptions import AirflowException
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook

DAG_ID = "gca_atlas_column_process_backfill"
POSTGRES_CONN_ID = "datalike_db"

ATLAS_URL_VAR = "gca_atlas_url"
ATLAS_KRB_PRINCIPAL_VAR = "gca_atlas_kerberos_principal"
ATLAS_KRB_KEYTAB_VAR = "gca_atlas_kerberos_keytab"
BACKFILL_LAST_GOV_ID_VAR = "gca_atlas_column_process_backfill_last_governance_id"

DB_FETCH_BATCH_SIZE = 3000
ATLAS_PUSH_CHUNK_SIZE = 200
CURL_TIMEOUT_SEC = 300
DATALIKE_NAMESPACE = "datalikegovernance"

ATLAS_TYPE_COLUMN = "datalike_column"
ATLAS_TYPE_COLUMN_PROCESS = "datalike_column_process"

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def _require_var(name: str) -> str:
    value = Variable.get(name, default_var=None)
    if value is None or str(value).strip() == "":
        raise AirflowException(f"Missing or empty Airflow Variable: {name}")
    return str(value).strip()


def _runtime_config() -> dict:
    atlas_url = _require_var(ATLAS_URL_VAR).rstrip("/")
    principal = _require_var(ATLAS_KRB_PRINCIPAL_VAR)
    keytab = _require_var(ATLAS_KRB_KEYTAB_VAR)
    last_raw = Variable.get(BACKFILL_LAST_GOV_ID_VAR, default_var="0")

    try:
        last_id = int(str(last_raw).strip())
    except Exception as exc:
        raise AirflowException(f"Invalid {BACKFILL_LAST_GOV_ID_VAR}: {last_raw}") from exc

    if not os.path.exists(keytab):
        raise AirflowException(f"Keytab not found: {keytab}")

    return {
        "atlas_url": atlas_url,
        "principal": principal,
        "keytab": keytab,
        "last_governance_id": last_id,
    }


def _run_cmd(cmd, check=True):
    logger.info("Running command: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    logger.info("stdout: %s", result.stdout.strip())
    if result.stderr.strip():
        logger.warning("stderr: %s", result.stderr.strip())
    if check and result.returncode != 0:
        raise AirflowException(
            f"Command failed ({result.returncode}): {' '.join(cmd)}\n"
            f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )
    return result


def _kinit(principal: str, keytab: str) -> None:
    _run_cmd(["kinit", "-kt", keytab, principal], check=True)
    _run_cmd(["klist"], check=True)


def _curl_atlas_json(atlas_url: str, endpoint: str, method: str = "GET", payload: dict | None = None) -> dict:
    url = f"{atlas_url}{endpoint}"
    cmd = [
        "curl", "-sS", "-k",
        "--negotiate", "-u", ":",
        "--max-time", str(CURL_TIMEOUT_SEC),
        "-X", method.upper(),
        url,
        "-w", "\n__HTTP_STATUS__:%{http_code}",
    ]

    temp_file = None
    try:
        if payload is not None:
            temp_file = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8")
            json.dump(payload, temp_file, ensure_ascii=False)
            temp_file.flush()
            temp_file.close()
            cmd.extend(["-H", "Content-Type: application/json", "--data", f"@{temp_file.name}"])

        result = _run_cmd(cmd, check=False)
        if "__HTTP_STATUS__:" not in result.stdout:
            raise AirflowException(f"Invalid Atlas response from {url}")

        body, status_str = result.stdout.rsplit("__HTTP_STATUS__:", 1)
        status_code = int(status_str.strip())
        body = body.strip()

        parsed = {}
        if body:
            try:
                parsed = json.loads(body)
            except Exception:
                parsed = {"raw_response": body}

        if status_code >= 400:
            raise AirflowException(
                f"Atlas API failed: {method} {url} HTTP {status_code}\nResponse: {json.dumps(parsed, ensure_ascii=False)}"
            )
        return parsed
    finally:
        if temp_file and os.path.exists(temp_file.name):
            os.unlink(temp_file.name)


def _safe_lower(v):
    return (v or "").strip().lower()


def _normalize_identifier(v):
    s = _safe_lower(v)
    s = re.sub(r"\buat\b", "", s)
    s = re.sub(r"[_\-\s]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def _normalize_connection_name(v):
    s = _normalize_identifier(v)
    s = re.sub(r"(^|_)(uat)($|_)", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s or "unknown_conn"


def _normalize_schema(v, fallback="unknown_schema"):
    s = _normalize_identifier(v)
    return s or fallback


def _normalize_table(v, fallback="unknown_table"):
    s = _normalize_identifier(v)
    return s or fallback


def _normalize_column(v, fallback="unknown_column"):
    s = _normalize_identifier(v)
    return s or fallback


def _is_excel_like(conn: str) -> bool:
    c = _safe_lower(conn)
    return "excel" in c or "sheet" in c or "xls" in c or "xlsx" in c


def _detect_layer(schema_name: str) -> str:
    s = _safe_lower(schema_name)
    if s.startswith("brz"):
        return "bronze"
    if s.startswith("slv"):
        return "silver"
    if s.startswith("gld"):
        return "gold"
    return "source"


def _build_table_qn(conn: str, schema_name: str, table_name: str) -> str:
    return f"{conn}.{schema_name}.{table_name}@{DATALIKE_NAMESPACE}"


def _build_column_qn(conn: str, schema_name: str, table_name: str, column_name: str) -> str:
    return f"{conn}.{schema_name}.{table_name}.{column_name}@{DATALIKE_NAMESPACE}"


def _build_column_process_qn(src_column_qn: str, dst_column_qn: str, governance_id: int) -> str:
    return f"{src_column_qn}|proc|{dst_column_qn}|{governance_id}@{DATALIKE_NAMESPACE}"


def _coalesce_source_side(row: dict, src_conn: str):
    src_schema = _normalize_schema(row.get("source_schema_name"), fallback="")
    src_table = _normalize_table(row.get("source_table_name"), fallback="")
    src_column = _normalize_column(row.get("source_column_name") or row.get("source_column_name_desc"), fallback="")

    dst_schema = _normalize_schema(row.get("destination_schema_name"), fallback="unknown_schema")
    dst_table = _normalize_table(row.get("destination_table_name"), fallback="unknown_table")
    dst_column = _normalize_column(row.get("destination_column_name") or row.get("destination_column_name_desc"), fallback="unknown_column")

    if not src_schema:
        src_schema = "sheet" if _is_excel_like(src_conn) else f"nosource_before_{dst_schema}"
    if not src_table:
        src_table = f"nosource_before_{dst_table}"
    if not src_column:
        src_column = f"nosource_before_{dst_column}"

    return src_schema, src_table, src_column


def _pg_hook():
    return PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)


def _fetch_governance_batch(last_governance_id: int, limit: int):
    sql = """
        SELECT
            governance_id,
            action_type,
            create_timestamp,
            source_column_name_desc,
            source_schema_name,
            source_table_name,
            destination_column_name,
            destination_column_name_desc,
            destination_schema_name,
            destination_table_name,
            job_id,
            source_column_name
        FROM public.data_like_governance
        WHERE governance_id > %s
          AND COALESCE(action_type, '') IN ('CREATE', 'create', '')
        ORDER BY governance_id
        LIMIT %s
    """
    rows = _pg_hook().get_records(sql, parameters=(last_governance_id, limit))
    cols = [
        "governance_id",
        "action_type",
        "create_timestamp",
        "source_column_name_desc",
        "source_schema_name",
        "source_table_name",
        "destination_column_name",
        "destination_column_name_desc",
        "destination_schema_name",
        "destination_table_name",
        "job_id",
        "source_column_name",
    ]
    return [dict(zip(cols, r)) for r in rows]


def _fetch_job_metadata(job_ids):
    if not job_ids:
        return {}

    sql = """
        SELECT
            job_id,
            job_cd,
            data_src_conn_cd,
            dest_conn_cd,
            sql_query
        FROM public.data_transfer_job
        WHERE job_id = ANY(%s)
    """
    records = _pg_hook().get_records(sql, parameters=(job_ids,))
    return {
        int(r[0]): {
            "job_id": int(r[0]),
            "job_cd": r[1],
            "data_src_conn_cd": r[2],
            "dest_conn_cd": r[3],
            "sql_query": r[4],
        }
        for r in records
    }


def _type_exists(atlas_url: str, type_name: str) -> bool:
    try:
        _curl_atlas_json(atlas_url, f"/api/atlas/v2/types/typedef/name/{type_name}", "GET")
        return True
    except Exception:
        return False


def _ensure_types(atlas_url: str):
    missing = []
    for t in [ATLAS_TYPE_COLUMN, ATLAS_TYPE_COLUMN_PROCESS]:
        if not _type_exists(atlas_url, t):
            missing.append(t)

    if not missing:
        return

    payload = {
        "entityDefs": [
            {
                "category": "ENTITY",
                "name": ATLAS_TYPE_COLUMN,
                "description": "DataLike governance column entity",
                "typeVersion": "1.0",
                "serviceType": "datalikegovernance",
                "superTypes": ["DataSet"],
                "attributeDefs": [
                    {"name": "table_qn", "typeName": "string", "isOptional": False, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "connection_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "schema_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "table_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "column_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "parent_dataset_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                ],
            },
            {
                "category": "ENTITY",
                "name": ATLAS_TYPE_COLUMN_PROCESS,
                "description": "Column level process for DataLike governance lineage",
                "typeVersion": "1.0",
                "serviceType": "datalikegovernance",
                "superTypes": ["Process"],
                "attributeDefs": [
                    {"name": "job_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "job_cd", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "governance_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "sql_query", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                    {"name": "layer_from", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer_to", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "source_column_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "destination_column_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "parent_table_process_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                ],
            },
        ]
    }

    _curl_atlas_json(atlas_url, "/api/atlas/v2/types/typedefs", "POST", payload)


def _build_column_entity(conn: str, schema_name: str, table_name: str, column_name: str):
    table_qn = _build_table_qn(conn, schema_name, table_name)
    qn = _build_column_qn(conn, schema_name, table_name, column_name)
    return {
        "typeName": ATLAS_TYPE_COLUMN,
        "attributes": {
            "qualifiedName": qn,
            "name": f"{conn}.{schema_name}.{table_name}.{column_name}",
            "description": f"column {column_name} in {conn}.{schema_name}.{table_name}",
            "table_qn": table_qn,
            "connection_name": conn,
            "schema_name": schema_name,
            "table_name": table_name,
            "column_name": column_name,
            "layer": _detect_layer(schema_name),
            "parent_dataset_qn": table_qn,
        },
    }


def _build_column_process_entity(
    src_column_qn: str,
    dst_column_qn: str,
    parent_table_process_qn: str,
    job_id: int,
    job_cd: str,
    governance_id: int,
    create_timestamp: str,
    sql_query: str,
    layer_from: str,
    layer_to: str,
):
    qn = _build_column_process_qn(src_column_qn, dst_column_qn, governance_id)
    return {
        "typeName": ATLAS_TYPE_COLUMN_PROCESS,
        "attributes": {
            "qualifiedName": qn,
            "name": f"{job_cd}:{src_column_qn}=>{dst_column_qn}",
            "description": f"column process governance_id={governance_id} create_timestamp={create_timestamp}",
            "job_id": str(job_id),
            "job_cd": job_cd or "",
            "governance_id": str(governance_id),
            "sql_query": sql_query or "",
            "layer_from": layer_from,
            "layer_to": layer_to,
            "source_column_qn": src_column_qn,
            "destination_column_qn": dst_column_qn,
            "parent_table_process_qn": parent_table_process_qn,
            "inputs": [{"typeName": ATLAS_TYPE_COLUMN, "uniqueAttributes": {"qualifiedName": src_column_qn}}],
            "outputs": [{"typeName": ATLAS_TYPE_COLUMN, "uniqueAttributes": {"qualifiedName": dst_column_qn}}],
        },
    }


def _chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _bulk_upsert(atlas_url: str, entities):
    if not entities:
        return {}
    return _curl_atlas_json(atlas_url, "/api/atlas/v2/entity/bulk", "POST", {"entities": entities})


def _process_backfill(atlas_url: str, start_last_id: int):
    _ensure_types(atlas_url)

    total_rows = 0
    total_columns = 0
    total_column_processes = 0
    current_last_id = start_last_id
    batch_no = 0

    while True:
        rows = _fetch_governance_batch(current_last_id, DB_FETCH_BATCH_SIZE)
        if not rows:
            break

        batch_no += 1
        total_rows += len(rows)

        job_ids = sorted({int(r["job_id"]) for r in rows if r.get("job_id") is not None})
        jobs = _fetch_job_metadata(job_ids)

        columns_map = {}
        column_processes = []

        for row in rows:
            governance_id = int(row["governance_id"])
            job_id = row.get("job_id")
            if job_id is None:
                continue

            job = jobs.get(int(job_id))
            if not job:
                continue

            src_conn = _normalize_connection_name(job.get("data_src_conn_cd"))
            dst_conn = _normalize_connection_name(job.get("dest_conn_cd"))
            job_cd = job.get("job_cd") or f"job_{job_id}"
            sql_query = job.get("sql_query") or ""

            src_schema, src_table, src_column = _coalesce_source_side(row, src_conn)
            dst_schema = _normalize_schema(row.get("destination_schema_name"), fallback="unknown_schema")
            dst_table = _normalize_table(row.get("destination_table_name"), fallback="unknown_table")
            dst_column = _normalize_column(row.get("destination_column_name") or row.get("destination_column_name_desc"), fallback="unknown_column")

            src_column_qn = _build_column_qn(src_conn, src_schema, src_table, src_column)
            dst_column_qn = _build_column_qn(dst_conn, dst_schema, dst_table, dst_column)

            columns_map[src_column_qn] = _build_column_entity(src_conn, src_schema, src_table, src_column)
            columns_map[dst_column_qn] = _build_column_entity(dst_conn, dst_schema, dst_table, dst_column)

            parent_table_process_qn = (
                f"{int(job_id)}|{src_conn}.{src_schema}.{src_table}|"
                f"{dst_conn}.{dst_schema}.{dst_table}@{DATALIKE_NAMESPACE}"
            )

            column_processes.append(
                _build_column_process_entity(
                    src_column_qn=src_column_qn,
                    dst_column_qn=dst_column_qn,
                    parent_table_process_qn=parent_table_process_qn,
                    job_id=int(job_id),
                    job_cd=job_cd,
                    governance_id=governance_id,
                    create_timestamp=str(row.get("create_timestamp") or ""),
                    sql_query=sql_query,
                    layer_from=_detect_layer(src_schema),
                    layer_to=_detect_layer(dst_schema),
                )
            )

        column_entities = list(columns_map.values())

        logger.info(
            "Backfill batch=%s rows=%s columns=%s column_processes=%s",
            batch_no, len(rows), len(column_entities), len(column_processes)
        )

        for chunk in _chunked(column_entities, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        for chunk in _chunked(column_processes, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        batch_max_id = max(int(r["governance_id"]) for r in rows)
        Variable.set(BACKFILL_LAST_GOV_ID_VAR, str(batch_max_id))
        current_last_id = batch_max_id

        total_columns += len(column_entities)
        total_column_processes += len(column_processes)

    return {
        "start_last_governance_id": start_last_id,
        "end_last_governance_id": current_last_id,
        "total_rows": total_rows,
        "total_columns": total_columns,
        "total_column_processes": total_column_processes,
        "total_batches": batch_no,
    }


default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id=DAG_ID,
    default_args=default_args,
    description="Backfill real column lineage using Process entities",
    start_date=datetime(2026, 1, 1),
    schedule_interval=None,
    catchup=False,
    max_active_runs=1,
    tags=["atlas", "governance", "column-process", "backfill"],
) as dag:

    @task
    def validate_runtime_config():
        return _runtime_config()

    @task
    def kinit_and_test(cfg):
        _kinit(cfg["principal"], cfg["keytab"])
        _curl_atlas_json(cfg["atlas_url"], "/api/atlas/v2/types/typedefs", "GET")
        return cfg

    @task
    def backfill(cfg):
        return _process_backfill(cfg["atlas_url"], cfg["last_governance_id"])

    @task
    def emit_summary(summary):
        logger.info("=== COLUMN PROCESS BACKFILL SUMMARY ===")
        logger.info("Start checkpoint : %s", summary["start_last_governance_id"])
        logger.info("End checkpoint   : %s", summary["end_last_governance_id"])
        logger.info("Total rows       : %s", summary["total_rows"])
        logger.info("Total columns    : %s", summary["total_columns"])
        logger.info("Column processes : %s", summary["total_column_processes"])
        logger.info("Batches          : %s", summary["total_batches"])

    cfg = validate_runtime_config()
    cfg2 = kinit_and_test(cfg)
    summary = backfill(cfg2)
    emit_summary(summary)
```

---

# Final merged production DAG

Save as:

```python
# dags/gca_atlas_governance_final_dag.py
```

```python
import json
import logging
import os
import re
import subprocess
import tempfile
import uuid
from datetime import datetime, timedelta

from airflow import DAG
from airflow.decorators import task
from airflow.exceptions import AirflowException
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook

DAG_ID = "gca_atlas_governance_final"
POSTGRES_CONN_ID = "datalike_db"

ATLAS_LAST_GOV_ID_VAR = "gca_atlas_last_governance_id"
ATLAS_URL_VAR = "gca_atlas_url"
ATLAS_KRB_PRINCIPAL_VAR = "gca_atlas_kerberos_principal"
ATLAS_KRB_KEYTAB_VAR = "gca_atlas_kerberos_keytab"

DB_FETCH_BATCH_SIZE = 3000
ATLAS_PUSH_CHUNK_SIZE = 200
CURL_TIMEOUT_SEC = 300
PROCESS_LOOP_MAX_BATCHES_PER_RUN = 1000
DATALIKE_NAMESPACE = "datalikegovernance"

ATLAS_TYPE_DATASET = "datalike_dataset"
ATLAS_TYPE_PROCESS = "datalike_process"
ATLAS_TYPE_COLUMN = "datalike_column"
ATLAS_TYPE_COLUMN_PROCESS = "datalike_column_process"

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def _require_var(name: str) -> str:
    value = Variable.get(name, default_var=None)
    if value is None or str(value).strip() == "":
        raise AirflowException(f"Missing or empty Airflow Variable: {name}")
    return str(value).strip()


def _runtime_config() -> dict:
    atlas_url = _require_var(ATLAS_URL_VAR).rstrip("/")
    principal = _require_var(ATLAS_KRB_PRINCIPAL_VAR)
    keytab = _require_var(ATLAS_KRB_KEYTAB_VAR)
    last_raw = Variable.get(ATLAS_LAST_GOV_ID_VAR, default_var="0")

    try:
        last_id = int(str(last_raw).strip())
    except Exception as exc:
        raise AirflowException(f"Invalid {ATLAS_LAST_GOV_ID_VAR}: {last_raw}") from exc

    if not os.path.exists(keytab):
        raise AirflowException(f"Keytab not found: {keytab}")

    return {
        "atlas_url": atlas_url,
        "principal": principal,
        "keytab": keytab,
        "last_governance_id": last_id,
    }


def _run_cmd(cmd, check=True):
    logger.info("Running command: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    logger.info("stdout: %s", result.stdout.strip())
    if result.stderr.strip():
        logger.warning("stderr: %s", result.stderr.strip())
    if check and result.returncode != 0:
        raise AirflowException(
            f"Command failed ({result.returncode}): {' '.join(cmd)}\n"
            f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )
    return result


def _kinit(principal: str, keytab: str) -> None:
    _run_cmd(["kinit", "-kt", keytab, principal], check=True)
    _run_cmd(["klist"], check=True)


def _curl_atlas_json(atlas_url: str, endpoint: str, method: str = "GET", payload: dict | None = None) -> dict:
    url = f"{atlas_url}{endpoint}"
    cmd = [
        "curl", "-sS", "-k",
        "--negotiate", "-u", ":",
        "--max-time", str(CURL_TIMEOUT_SEC),
        "-X", method.upper(),
        url,
        "-w", "\n__HTTP_STATUS__:%{http_code}",
    ]

    temp_file = None
    try:
        if payload is not None:
            temp_file = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8")
            json.dump(payload, temp_file, ensure_ascii=False)
            temp_file.flush()
            temp_file.close()
            cmd.extend(["-H", "Content-Type: application/json", "--data", f"@{temp_file.name}"])

        result = _run_cmd(cmd, check=False)
        if "__HTTP_STATUS__:" not in result.stdout:
            raise AirflowException(f"Invalid Atlas response from {url}")

        body, status_str = result.stdout.rsplit("__HTTP_STATUS__:", 1)
        status_code = int(status_str.strip())
        body = body.strip()

        parsed = {}
        if body:
            try:
                parsed = json.loads(body)
            except Exception:
                parsed = {"raw_response": body}

        if status_code >= 400:
            raise AirflowException(
                f"Atlas API failed: {method} {url} HTTP {status_code}\nResponse: {json.dumps(parsed, ensure_ascii=False)}"
            )
        return parsed
    finally:
        if temp_file and os.path.exists(temp_file.name):
            os.unlink(temp_file.name)


def _safe_lower(v):
    return (v or "").strip().lower()


def _normalize_identifier(v):
    s = _safe_lower(v)
    s = re.sub(r"\buat\b", "", s)
    s = re.sub(r"[_\-\s]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def _normalize_connection_name(v):
    s = _normalize_identifier(v)
    s = re.sub(r"(^|_)(uat)($|_)", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s or "unknown_conn"


def _normalize_schema(v, fallback="unknown_schema"):
    s = _normalize_identifier(v)
    return s or fallback


def _normalize_table(v, fallback="unknown_table"):
    s = _normalize_identifier(v)
    return s or fallback


def _normalize_column(v, fallback="unknown_column"):
    s = _normalize_identifier(v)
    return s or fallback


def _is_excel_like(conn: str) -> bool:
    c = _safe_lower(conn)
    return "excel" in c or "sheet" in c or "xls" in c or "xlsx" in c


def _detect_layer(schema_name: str) -> str:
    s = _safe_lower(schema_name)
    if s.startswith("brz"):
        return "bronze"
    if s.startswith("slv"):
        return "silver"
    if s.startswith("gld"):
        return "gold"
    return "source"


def _build_table_qn(conn: str, schema_name: str, table_name: str) -> str:
    return f"{conn}.{schema_name}.{table_name}@{DATALIKE_NAMESPACE}"


def _build_column_qn(conn: str, schema_name: str, table_name: str, column_name: str) -> str:
    return f"{conn}.{schema_name}.{table_name}.{column_name}@{DATALIKE_NAMESPACE}"


def _build_column_process_qn(src_column_qn: str, dst_column_qn: str, governance_id: int) -> str:
    return f"{src_column_qn}|proc|{dst_column_qn}|{governance_id}@{DATALIKE_NAMESPACE}"


def _coalesce_source_side(row: dict, src_conn: str):
    src_schema = _normalize_schema(row.get("source_schema_name"), fallback="")
    src_table = _normalize_table(row.get("source_table_name"), fallback="")
    src_column = _normalize_column(row.get("source_column_name") or row.get("source_column_name_desc"), fallback="")

    dst_schema = _normalize_schema(row.get("destination_schema_name"), fallback="unknown_schema")
    dst_table = _normalize_table(row.get("destination_table_name"), fallback="unknown_table")
    dst_column = _normalize_column(row.get("destination_column_name") or row.get("destination_column_name_desc"), fallback="unknown_column")

    if not src_schema:
        src_schema = "sheet" if _is_excel_like(src_conn) else f"nosource_before_{dst_schema}"
    if not src_table:
        src_table = f"nosource_before_{dst_table}"
    if not src_column:
        src_column = f"nosource_before_{dst_column}"

    return src_schema, src_table, src_column


def _pg_hook():
    return PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)


def _fetch_governance_batch(last_governance_id: int, limit: int):
    sql = """
        SELECT
            governance_id,
            action_type,
            create_timestamp,
            source_column_name_desc,
            source_schema_name,
            source_table_name,
            destination_column_name,
            destination_column_name_desc,
            destination_schema_name,
            destination_table_name,
            job_id,
            source_column_name
        FROM public.data_like_governance
        WHERE governance_id > %s
          AND COALESCE(action_type, '') IN ('CREATE', 'create', '')
        ORDER BY governance_id
        LIMIT %s
    """
    rows = _pg_hook().get_records(sql, parameters=(last_governance_id, limit))
    cols = [
        "governance_id",
        "action_type",
        "create_timestamp",
        "source_column_name_desc",
        "source_schema_name",
        "source_table_name",
        "destination_column_name",
        "destination_column_name_desc",
        "destination_schema_name",
        "destination_table_name",
        "job_id",
        "source_column_name",
    ]
    return [dict(zip(cols, r)) for r in rows]


def _fetch_job_metadata(job_ids):
    if not job_ids:
        return {}

    sql = """
        SELECT
            job_id,
            job_cd,
            data_src_conn_cd,
            dest_conn_cd,
            sql_query
        FROM public.data_transfer_job
        WHERE job_id = ANY(%s)
    """
    records = _pg_hook().get_records(sql, parameters=(job_ids,))
    return {
        int(r[0]): {
            "job_id": int(r[0]),
            "job_cd": r[1],
            "data_src_conn_cd": r[2],
            "dest_conn_cd": r[3],
            "sql_query": r[4],
        }
        for r in records
    }


def _type_exists(atlas_url: str, type_name: str) -> bool:
    try:
        _curl_atlas_json(atlas_url, f"/api/atlas/v2/types/typedef/name/{type_name}", "GET")
        return True
    except Exception:
        return False


def _ensure_all_types(atlas_url: str):
    missing = []
    for t in [ATLAS_TYPE_DATASET, ATLAS_TYPE_PROCESS, ATLAS_TYPE_COLUMN, ATLAS_TYPE_COLUMN_PROCESS]:
        if not _type_exists(atlas_url, t):
            missing.append(t)

    if not missing:
        return

    payload = {
        "entityDefs": [
            {
                "category": "ENTITY",
                "name": ATLAS_TYPE_DATASET,
                "description": "Generic dataset for DataLike governance lineage",
                "typeVersion": "1.0",
                "serviceType": "datalikegovernance",
                "superTypes": ["DataSet"],
                "attributeDefs": [
                    {"name": "connection_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "schema_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "table_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "platform", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "endpoint", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                    {"name": "columns_json", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                ],
            },
            {
                "category": "ENTITY",
                "name": ATLAS_TYPE_PROCESS,
                "description": "Generic process for DataLike governance lineage",
                "typeVersion": "1.0",
                "serviceType": "datalikegovernance",
                "superTypes": ["Process"],
                "attributeDefs": [
                    {"name": "job_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "job_cd", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "sql_query", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                    {"name": "source_connection", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "destination_connection", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer_from", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer_to", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "batch_guid", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "column_mappings_json", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                    {"name": "governance_min_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "governance_max_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                ],
            },
            {
                "category": "ENTITY",
                "name": ATLAS_TYPE_COLUMN,
                "description": "DataLike governance column entity",
                "typeVersion": "1.0",
                "serviceType": "datalikegovernance",
                "superTypes": ["DataSet"],
                "attributeDefs": [
                    {"name": "table_qn", "typeName": "string", "isOptional": False, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "connection_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "schema_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "table_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "column_name", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "parent_dataset_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                ],
            },
            {
                "category": "ENTITY",
                "name": ATLAS_TYPE_COLUMN_PROCESS,
                "description": "Column level process for DataLike governance lineage",
                "typeVersion": "1.0",
                "serviceType": "datalikegovernance",
                "superTypes": ["Process"],
                "attributeDefs": [
                    {"name": "job_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "job_cd", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "governance_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "sql_query", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                    {"name": "layer_from", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer_to", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "source_column_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "destination_column_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "parent_table_process_qn", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                ],
            },
        ]
    }

    _curl_atlas_json(atlas_url, "/api/atlas/v2/types/typedefs", "POST", payload)


def _json_compact(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def _dataset_platform_from_conn(conn: str, schema_name: str) -> str:
    c = _safe_lower(conn)
    if "hive" in c or schema_name.startswith(("brz", "slv", "gld")):
        return "hive"
    if _is_excel_like(c):
        return "excel"
    return "rdbms"


def _build_dataset_entity(conn: str, schema_name: str, table_name: str, columns: set):
    return {
        "typeName": ATLAS_TYPE_DATASET,
        "attributes": {
            "qualifiedName": _build_table_qn(conn, schema_name, table_name),
            "name": f"{conn}.{schema_name}.{table_name}",
            "description": f"{_dataset_platform_from_conn(conn, schema_name)} dataset {conn}.{schema_name}.{table_name}",
            "connection_name": conn,
            "schema_name": schema_name,
            "table_name": table_name,
            "layer": _detect_layer(schema_name),
            "platform": _dataset_platform_from_conn(conn, schema_name),
            "endpoint": f"{conn}.{schema_name}.{table_name}",
            "columns_json": _json_compact(sorted(columns)),
        },
    }


def _build_column_entity(conn: str, schema_name: str, table_name: str, column_name: str):
    table_qn = _build_table_qn(conn, schema_name, table_name)
    qn = _build_column_qn(conn, schema_name, table_name, column_name)
    return {
        "typeName": ATLAS_TYPE_COLUMN,
        "attributes": {
            "qualifiedName": qn,
            "name": f"{conn}.{schema_name}.{table_name}.{column_name}",
            "description": f"column {column_name} in {conn}.{schema_name}.{table_name}",
            "table_qn": table_qn,
            "connection_name": conn,
            "schema_name": schema_name,
            "table_name": table_name,
            "column_name": column_name,
            "layer": _detect_layer(schema_name),
            "parent_dataset_qn": table_qn,
        },
    }


def _build_table_process_entity(
    process_qn: str,
    process_name: str,
    src_dataset_qn: str,
    dst_dataset_qn: str,
    job_id: int,
    job_cd: str,
    sql_query: str,
    src_conn: str,
    dst_conn: str,
    layer_from: str,
    layer_to: str,
    batch_guid: str,
    governance_min_id: int,
    governance_max_id: int,
    column_mappings,
):
    return {
        "typeName": ATLAS_TYPE_PROCESS,
        "attributes": {
            "qualifiedName": process_qn,
            "name": process_name,
            "description": f"job_id={job_id} | job_cd={job_cd} | layer_from={layer_from} | layer_to={layer_to}",
            "job_id": str(job_id),
            "job_cd": job_cd or "",
            "sql_query": sql_query or "",
            "source_connection": src_conn,
            "destination_connection": dst_conn,
            "layer_from": layer_from,
            "layer_to": layer_to,
            "batch_guid": batch_guid,
            "governance_min_id": str(governance_min_id),
            "governance_max_id": str(governance_max_id),
            "column_mappings_json": _json_compact(column_mappings),
            "inputs": [{"typeName": ATLAS_TYPE_DATASET, "uniqueAttributes": {"qualifiedName": src_dataset_qn}}],
            "outputs": [{"typeName": ATLAS_TYPE_DATASET, "uniqueAttributes": {"qualifiedName": dst_dataset_qn}}],
        },
    }


def _build_column_process_entity(
    src_column_qn: str,
    dst_column_qn: str,
    parent_table_process_qn: str,
    job_id: int,
    job_cd: str,
    governance_id: int,
    create_timestamp: str,
    sql_query: str,
    layer_from: str,
    layer_to: str,
):
    return {
        "typeName": ATLAS_TYPE_COLUMN_PROCESS,
        "attributes": {
            "qualifiedName": _build_column_process_qn(src_column_qn, dst_column_qn, governance_id),
            "name": f"{job_cd}:{src_column_qn}=>{dst_column_qn}",
            "description": f"column process governance_id={governance_id} create_timestamp={create_timestamp}",
            "job_id": str(job_id),
            "job_cd": job_cd or "",
            "governance_id": str(governance_id),
            "sql_query": sql_query or "",
            "layer_from": layer_from,
            "layer_to": layer_to,
            "source_column_qn": src_column_qn,
            "destination_column_qn": dst_column_qn,
            "parent_table_process_qn": parent_table_process_qn,
            "inputs": [{"typeName": ATLAS_TYPE_COLUMN, "uniqueAttributes": {"qualifiedName": src_column_qn}}],
            "outputs": [{"typeName": ATLAS_TYPE_COLUMN, "uniqueAttributes": {"qualifiedName": dst_column_qn}}],
        },
    }


def _chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _bulk_upsert(atlas_url: str, entities):
    if not entities:
        return {}
    return _curl_atlas_json(atlas_url, "/api/atlas/v2/entity/bulk", "POST", {"entities": entities})


def _set_checkpoint(value: int):
    Variable.set(ATLAS_LAST_GOV_ID_VAR, str(int(value)))


def _process_batches(atlas_url: str, start_last_id: int):
    _ensure_all_types(atlas_url)

    total_rows = 0
    total_datasets = 0
    total_table_processes = 0
    total_columns = 0
    total_column_processes = 0
    total_batches = 0
    current_last_id = start_last_id

    for _ in range(PROCESS_LOOP_MAX_BATCHES_PER_RUN):
        rows = _fetch_governance_batch(current_last_id, DB_FETCH_BATCH_SIZE)
        if not rows:
            break

        total_batches += 1
        total_rows += len(rows)

        job_ids = sorted({int(r["job_id"]) for r in rows if r.get("job_id") is not None})
        jobs = _fetch_job_metadata(job_ids)

        datasets_map = {}
        columns_map = {}
        table_process_groups = {}
        column_processes = []

        for row in rows:
            governance_id = int(row["governance_id"])
            job_id = row.get("job_id")
            if job_id is None:
                continue

            job = jobs.get(int(job_id))
            if not job:
                continue

            src_conn = _normalize_connection_name(job.get("data_src_conn_cd"))
            dst_conn = _normalize_connection_name(job.get("dest_conn_cd"))
            job_cd = job.get("job_cd") or f"job_{job_id}"
            sql_query = job.get("sql_query") or ""

            src_schema, src_table, src_column = _coalesce_source_side(row, src_conn)
            dst_schema = _normalize_schema(row.get("destination_schema_name"), fallback="unknown_schema")
            dst_table = _normalize_table(row.get("destination_table_name"), fallback="unknown_table")
            dst_column = _normalize_column(row.get("destination_column_name") or row.get("destination_column_name_desc"), fallback="unknown_column")

            src_dataset_qn = _build_table_qn(src_conn, src_schema, src_table)
            dst_dataset_qn = _build_table_qn(dst_conn, dst_schema, dst_table)
            src_column_qn = _build_column_qn(src_conn, src_schema, src_table, src_column)
            dst_column_qn = _build_column_qn(dst_conn, dst_schema, dst_table, dst_column)

            datasets_map.setdefault((src_conn, src_schema, src_table), set()).add(src_column)
            datasets_map.setdefault((dst_conn, dst_schema, dst_table), set()).add(dst_column)

            columns_map[src_column_qn] = _build_column_entity(src_conn, src_schema, src_table, src_column)
            columns_map[dst_column_qn] = _build_column_entity(dst_conn, dst_schema, dst_table, dst_column)

            table_process_qn = (
                f"{int(job_id)}|{src_conn}.{src_schema}.{src_table}|"
                f"{dst_conn}.{dst_schema}.{dst_table}@{DATALIKE_NAMESPACE}"
            )

            if table_process_qn not in table_process_groups:
                table_process_groups[table_process_qn] = {
                    "process_qn": table_process_qn,
                    "process_name": job_cd,
                    "src_dataset_qn": src_dataset_qn,
                    "dst_dataset_qn": dst_dataset_qn,
                    "job_id": int(job_id),
                    "job_cd": job_cd,
                    "sql_query": sql_query,
                    "src_conn": src_conn,
                    "dst_conn": dst_conn,
                    "layer_from": _detect_layer(src_schema),
                    "layer_to": _detect_layer(dst_schema),
                    "governance_ids": [],
                    "column_mappings": [],
                }

            table_process_groups[table_process_qn]["governance_ids"].append(governance_id)
            table_process_groups[table_process_qn]["column_mappings"].append({
                "governance_id": governance_id,
                "source_column_qn": src_column_qn,
                "destination_column_qn": dst_column_qn,
                "source_column_name": src_column,
                "destination_column_name": dst_column,
                "create_timestamp": str(row.get("create_timestamp") or ""),
            })

            column_processes.append(
                _build_column_process_entity(
                    src_column_qn=src_column_qn,
                    dst_column_qn=dst_column_qn,
                    parent_table_process_qn=table_process_qn,
                    job_id=int(job_id),
                    job_cd=job_cd,
                    governance_id=governance_id,
                    create_timestamp=str(row.get("create_timestamp") or ""),
                    sql_query=sql_query,
                    layer_from=_detect_layer(src_schema),
                    layer_to=_detect_layer(dst_schema),
                )
            )

        dataset_entities = [
            _build_dataset_entity(conn, schema_name, table_name, cols)
            for (conn, schema_name, table_name), cols in datasets_map.items()
        ]

        table_process_entities = []
        batch_guid = str(uuid.uuid4())

        for grp in table_process_groups.values():
            table_process_entities.append(
                _build_table_process_entity(
                    process_qn=grp["process_qn"],
                    process_name=grp["process_name"],
                    src_dataset_qn=grp["src_dataset_qn"],
                    dst_dataset_qn=grp["dst_dataset_qn"],
                    job_id=grp["job_id"],
                    job_cd=grp["job_cd"],
                    sql_query=grp["sql_query"],
                    src_conn=grp["src_conn"],
                    dst_conn=grp["dst_conn"],
                    layer_from=grp["layer_from"],
                    layer_to=grp["layer_to"],
                    batch_guid=batch_guid,
                    governance_min_id=min(grp["governance_ids"]),
                    governance_max_id=max(grp["governance_ids"]),
                    column_mappings=grp["column_mappings"],
                )
            )

        column_entities = list(columns_map.values())

        for chunk in _chunked(dataset_entities, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        for chunk in _chunked(column_entities, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        for chunk in _chunked(table_process_entities, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        for chunk in _chunked(column_processes, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        batch_max_id = max(int(r["governance_id"]) for r in rows)
        _set_checkpoint(batch_max_id)
        current_last_id = batch_max_id

        total_datasets += len(dataset_entities)
        total_table_processes += len(table_process_entities)
        total_columns += len(column_entities)
        total_column_processes += len(column_processes)

    return {
        "start_last_governance_id": start_last_id,
        "end_last_governance_id": current_last_id,
        "total_rows": total_rows,
        "total_datasets": total_datasets,
        "total_table_processes": total_table_processes,
        "total_columns": total_columns,
        "total_column_processes": total_column_processes,
        "total_batches": total_batches,
    }


default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id=DAG_ID,
    default_args=default_args,
    description="Final merged DAG for DataLike governance table and column lineage",
    start_date=datetime(2026, 1, 1),
    schedule_interval=None,
    catchup=False,
    max_active_runs=1,
    tags=["atlas", "governance", "final", "lineage"],
) as dag:

    @task
    def validate_runtime_config():
        return _runtime_config()

    @task
    def kinit_and_test(cfg):
        _kinit(cfg["principal"], cfg["keytab"])
        _curl_atlas_json(cfg["atlas_url"], "/api/atlas/v2/types/typedefs", "GET")
        return cfg

    @task
    def process_governance(cfg):
        return _process_batches(cfg["atlas_url"], cfg["last_governance_id"])

    @task
    def emit_summary(summary):
        logger.info("=== FINAL GOVERNANCE SUMMARY ===")
        logger.info("Start checkpoint      : %s", summary["start_last_governance_id"])
        logger.info("End checkpoint        : %s", summary["end_last_governance_id"])
        logger.info("Total rows            : %s", summary["total_rows"])
        logger.info("Datasets              : %s", summary["total_datasets"])
        logger.info("Table processes       : %s", summary["total_table_processes"])
        logger.info("Columns               : %s", summary["total_columns"])
        logger.info("Column processes      : %s", summary["total_column_processes"])
        logger.info("Batches               : %s", summary["total_batches"])

    cfg = validate_runtime_config()
    cfg2 = kinit_and_test(cfg)
    summary = process_governance(cfg2)
    emit_summary(summary)
```

---

# What you need to do from your side

## 1. Pause old DAGs

Pause:

* old table-only DAG
* old column backfill DAG
* old merged DAG if deployed

## 2. Create new variable

```text
gca_atlas_column_process_backfill_last_governance_id = 0
```

## 3. Deploy replacement backfill DAG

Deploy:

```text
gca_atlas_column_process_backfill_dag.py
```

## 4. Run replacement backfill DAG

Let it finish completely.

## 5. Validate in Atlas

Check:

* `datalike_column`
* `datalike_column_process`

Open one `datalike_column` entity and go to **Lineage**.

## 6. Deploy final merged DAG

Deploy:

```text
gca_atlas_governance_final_dag.py
```

## 7. Run final merged DAG once manually

Confirm new incremental rows create:

* datasets
* table processes
* columns
* column processes

## 8. Remove old DAG files

After confirmation, delete:

* old table-only DAG
* old `datalike_column_lineage` backfill DAG
* old merged DAG version if any

Keep only:

* `gca_atlas_column_process_backfill_dag.py` temporarily until validated
* `gca_atlas_governance_final_dag.py`

After everything is confirmed, remove the backfill DAG too.

---

# Important note

This is the closest practical custom Atlas model for visible column lineage.

If Atlas UI still does not render column lineage even with `datalike_column_process`, then the limitation is in Atlas UI support for custom types, not in your governance data. In that case, the data model is still correct, but the UI may only fully render native lineage produced by built-in integrations.
