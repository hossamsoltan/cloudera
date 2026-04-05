Yes. The clean native model for your case is:

* **one `spark_application` per job**
* **one `spark_process` per governance row / transformation**
* **one `spark_column_lineage` per governance row** for column-to-column lineage
* **reuse native `hive_db` / `hive_table` / `hive_column`** for targets
* **treat all non-Hive sources as `rdbms_table` / `rdbms_column`**
* **auto-create missing source-side RDBMS entities**
* **fallback source schema/table from source connection**
* **unknown target layer gets `temp_` prefix**
* preserve your business metadata using a native Atlas **classification**

That matches Cloudera’s native Spark lineage model: Atlas uses a `spark_application` for the job, one or more `spark_process` entities for executions in that job, and native lineage is built from input/output relationships. Cloudera also documents native `spark_column_lineage` entities with input columns, output column, and a relationship to the producing `spark_process`. ([Cloudera Docs][1])

## What you need to do

Create these Airflow Variables:

```text
gca_atlas_last_governance_id = 0
gca_atlas_url = https://<your-knox-or-atlas-url>
gca_atlas_kerberos_principal = <your-principal>
gca_atlas_kerberos_keytab = <full-keytab-path>
gca_atlas_source_connection_map = {"HIVE_UAT":"hive","csv_lookup_files":"file","default":"rdbms"}
```

Run these indexes once:

```sql
CREATE INDEX IF NOT EXISTS idx_dlg_governance_id
    ON public.data_like_governance (governance_id);

CREATE INDEX IF NOT EXISTS idx_dlg_job_id
    ON public.data_like_governance (job_id);

CREATE INDEX IF NOT EXISTS idx_dtj_job_id
    ON public.data_transfer_job (job_id);
```

Put the DAG below in your Airflow DAGs folder as:

```text
gca_atlas_native_spark_lineage_final.py
```

Run it manually first. After validation, add a schedule.

---

## Final DAG

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

# ============================================================
# Config
# ============================================================

DAG_ID = "gca_atlas_native_spark_lineage_final"
POSTGRES_CONN_ID = "datalike_db"

ATLAS_LAST_GOV_ID_VAR = "gca_atlas_last_governance_id"
ATLAS_URL_VAR = "gca_atlas_url"
ATLAS_KRB_PRINCIPAL_VAR = "gca_atlas_kerberos_principal"
ATLAS_KRB_KEYTAB_VAR = "gca_atlas_kerberos_keytab"
ATLAS_SOURCE_CONN_MAP_VAR = "gca_atlas_source_connection_map"

DB_FETCH_BATCH_SIZE = 2000
ATLAS_PUSH_CHUNK_SIZE = 200
CURL_TIMEOUT_SEC = 300
PROCESS_LOOP_MAX_BATCHES_PER_RUN = 1000

CLUSTER_NAME = "cm"
GOV_CLASSIFICATION_NAME = "data_like_governance_meta"
MEDALLION_PREFIXES = ("stg", "brz", "slv", "gld")

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ============================================================
# Runtime / shell helpers
# ============================================================

def _require_var(name: str) -> str:
    value = Variable.get(name, default_var=None)
    if value is None or str(value).strip() == "":
        raise AirflowException(f"Missing Airflow Variable: {name}")
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


def _run_cmd(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    logger.info("Running command: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.stdout.strip():
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
        "curl",
        "-sS",
        "-k",
        "--negotiate",
        "-u",
        ":",
        "--max-time",
        str(CURL_TIMEOUT_SEC),
        "-X",
        method.upper(),
        url,
        "-w",
        "\n__HTTP_STATUS__:%{http_code}",
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

# ============================================================
# String helpers
# ============================================================

def _safe_lower(v: str | None) -> str:
    return (v or "").strip().lower()


def _normalize_identifier(v: str | None) -> str:
    s = _safe_lower(v)
    s = re.sub(r"\buat\b", "", s)
    s = re.sub(r"[_\-\s]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def _normalize_conn(v: str | None) -> str:
    return _normalize_identifier(v) or "unknown_conn"


def _normalize_schema(v: str | None, fallback: str = "unknown_schema") -> str:
    return _normalize_identifier(v) or fallback


def _normalize_table(v: str | None, fallback: str = "unknown_table") -> str:
    return _normalize_identifier(v) or fallback


def _normalize_column(v: str | None, fallback: str = "unknown_column") -> str:
    return _normalize_identifier(v) or fallback


def _detect_layer(schema_name: str) -> str:
    s = _safe_lower(schema_name)
    if s.startswith("stg"):
        return "staging"
    if s.startswith("brz"):
        return "bronze"
    if s.startswith("slv"):
        return "silver"
    if s.startswith("gld"):
        return "gold"
    if s.startswith("temp_"):
        return "temporary"
    return "source"


def _normalize_dest_schema(dst_schema: str | None) -> str:
    s = _normalize_schema(dst_schema, fallback="temp_unknown")
    if not s.startswith(MEDALLION_PREFIXES) and not s.startswith("temp_"):
        s = f"temp_{s}"
    return s


def _get_source_system(conn_name: str) -> str:
    raw = Variable.get(ATLAS_SOURCE_CONN_MAP_VAR, default_var='{"default":"rdbms"}')
    try:
        mapping = json.loads(raw)
    except Exception:
        mapping = {"default": "rdbms"}

    original = (conn_name or "").strip()
    normalized = _normalize_conn(conn_name)

    if original in mapping:
        return str(mapping[original]).strip().lower()
    if normalized in mapping:
        return str(mapping[normalized]).strip().lower()

    return str(mapping.get("default", "rdbms")).strip().lower()


def _source_defaults_from_conn(src_conn: str, src_schema: str | None, src_table: str | None, src_column: str | None) -> tuple[str, str, str]:
    """
    If source schema/table are missing, derive them from source connection.
    This is the simple behavior you requested for excel-like sources.
    """
    conn_base = _normalize_conn(src_conn)
    schema = _normalize_schema(src_schema, fallback=conn_base)
    table = _normalize_table(src_table, fallback=conn_base)
    column = _normalize_column(src_column, fallback="nosource_column")
    return schema, table, column

# ============================================================
# Native qualified names
# ============================================================

def _hive_db_qn(db_name: str) -> str:
    return f"{db_name}@{CLUSTER_NAME}"


def _hive_table_qn(db_name: str, table_name: str) -> str:
    return f"{db_name}.{table_name}@{CLUSTER_NAME}"


def _hive_column_qn(db_name: str, table_name: str, column_name: str) -> str:
    return f"{db_name}.{table_name}.{column_name}@{CLUSTER_NAME}"


def _rdbms_table_qn(conn_name: str, schema_name: str, table_name: str) -> str:
    return f"{conn_name}.{schema_name}.{table_name}@data_like"


def _rdbms_column_qn(conn_name: str, schema_name: str, table_name: str, column_name: str) -> str:
    return f"{conn_name}.{schema_name}.{table_name}.{column_name}@data_like"


def _spark_app_qn(job_cd: str, job_id: int) -> str:
    return f"spark_app.{_normalize_identifier(job_cd)}.{job_id}@data_like"


def _spark_proc_qn(job_cd: str, governance_id: int) -> str:
    return f"spark_proc.{_normalize_identifier(job_cd)}.{governance_id}@data_like"


def _spark_col_lineage_qn(job_cd: str, governance_id: int) -> str:
    return f"spark_col_lineage.{_normalize_identifier(job_cd)}.{governance_id}@data_like"


def _entity_ref(type_name: str, qualified_name: str) -> dict:
    return {
        "typeName": type_name,
        "uniqueAttributes": {"qualifiedName": qualified_name}
    }

# ============================================================
# Atlas bootstrap
# ============================================================

def _type_exists(atlas_url: str, type_name: str) -> bool:
    try:
        _curl_atlas_json(atlas_url, f"/api/atlas/v2/types/typedef/name/{type_name}", "GET")
        return True
    except Exception:
        return False


def _ensure_governance_classification(atlas_url: str) -> None:
    if _type_exists(atlas_url, GOV_CLASSIFICATION_NAME):
        return

    payload = {
        "classificationDefs": [
            {
                "category": "CLASSIFICATION",
                "name": GOV_CLASSIFICATION_NAME,
                "description": "Business metadata from governance tables",
                "typeVersion": "1.0",
                "attributeDefs": [
                    {"name": "job_cd", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "job_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "sql_query", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                    {"name": "source_connection", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "destination_connection", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "governance_id", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "create_timestamp", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": False},
                    {"name": "layer_from", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                    {"name": "layer_to", "typeName": "string", "isOptional": True, "cardinality": "SINGLE", "isUnique": False, "isIndexable": True},
                ],
            }
        ]
    }
    _curl_atlas_json(atlas_url, "/api/atlas/v2/types/typedefs", "POST", payload)


def _entity_exists(atlas_url: str, type_name: str, qualified_name: str) -> bool:
    endpoint = f"/api/atlas/v2/entity/uniqueAttribute/type/{type_name}?attr:qualifiedName={qualified_name}"
    try:
        _curl_atlas_json(atlas_url, endpoint, "GET")
        return True
    except Exception:
        return False

# ============================================================
# PostgreSQL
# ============================================================

def _pg_hook() -> PostgresHook:
    return PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)


def _fetch_governance_batch(last_governance_id: int, limit: int) -> list[dict]:
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


def _fetch_job_metadata(job_ids: list[int]) -> dict[int, dict]:
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

# ============================================================
# Source / target resolution
# ============================================================

def _bulk_upsert(atlas_url: str, entities: list[dict]) -> None:
    if not entities:
        return
    _curl_atlas_json(atlas_url, "/api/atlas/v2/entity/bulk", "POST", {"entities": entities})


def _create_rdbms_source_if_missing(
    atlas_url: str,
    table_qn: str,
    column_qn: str,
    table_name: str,
    column_name: str,
) -> None:
    entities = []

    if not _entity_exists(atlas_url, "rdbms_table", table_qn):
        entities.append({
            "typeName": "rdbms_table",
            "attributes": {
                "qualifiedName": table_qn,
                "name": table_name,
                "owner": "data_like"
            }
        })

    if not _entity_exists(atlas_url, "rdbms_column", column_qn):
        entities.append({
            "typeName": "rdbms_column",
            "attributes": {
                "qualifiedName": column_qn,
                "name": column_name,
                "owner": "data_like"
            }
        })

    if entities:
        _bulk_upsert(atlas_url, entities)


def _resolve_source_ref(
    atlas_url: str,
    src_conn: str,
    src_schema: str | None,
    src_table: str | None,
    src_column: str | None,
) -> tuple[dict | None, dict | None]:
    """
    Simple behavior:
    - hive source -> reuse native hive entities
    - anything else -> create/reuse rdbms source entities
    - if schema/table missing -> derive from source connection
    """
    system_type = _get_source_system(src_conn)
    src_schema, src_table, src_column = _source_defaults_from_conn(src_conn, src_schema, src_table, src_column)

    if system_type == "hive":
        table_qn = _hive_table_qn(src_schema, src_table)
        column_qn = _hive_column_qn(src_schema, src_table, src_column)

        if not _entity_exists(atlas_url, "hive_table", table_qn):
            return None, None
        if not _entity_exists(atlas_url, "hive_column", column_qn):
            return None, None

        return _entity_ref("hive_table", table_qn), _entity_ref("hive_column", column_qn)

    table_qn = _rdbms_table_qn(src_conn, src_schema, src_table)
    column_qn = _rdbms_column_qn(src_conn, src_schema, src_table, src_column)

    _create_rdbms_source_if_missing(
        atlas_url=atlas_url,
        table_qn=table_qn,
        column_qn=column_qn,
        table_name=src_table,
        column_name=src_column,
    )

    return _entity_ref("rdbms_table", table_qn), _entity_ref("rdbms_column", column_qn)


def _resolve_target_hive_ref(
    atlas_url: str,
    dst_schema: str,
    dst_table: str,
    dst_column: str,
) -> tuple[dict | None, dict | None]:
    dst_schema = _normalize_dest_schema(dst_schema)
    dst_table = _normalize_table(dst_table)
    dst_column = _normalize_column(dst_column)

    db_qn = _hive_db_qn(dst_schema)
    table_qn = _hive_table_qn(dst_schema, dst_table)
    column_qn = _hive_column_qn(dst_schema, dst_table, dst_column)

    if not _entity_exists(atlas_url, "hive_db", db_qn):
        return None, None
    if not _entity_exists(atlas_url, "hive_table", table_qn):
        return None, None
    if not _entity_exists(atlas_url, "hive_column", column_qn):
        return None, None

    return _entity_ref("hive_table", table_qn), _entity_ref("hive_column", column_qn)

# ============================================================
# Entity builders
# ============================================================

def _gov_classification(
    job_cd: str,
    job_id: int,
    sql_query: str,
    src_conn: str,
    dst_conn: str,
    governance_id: int | None,
    create_timestamp: str | None,
    layer_from: str,
    layer_to: str,
) -> list[dict]:
    return [{
        "typeName": GOV_CLASSIFICATION_NAME,
        "attributes": {
            "job_cd": str(job_cd or ""),
            "job_id": str(job_id),
            "sql_query": str(sql_query or ""),
            "source_connection": str(src_conn or ""),
            "destination_connection": str(dst_conn or ""),
            "governance_id": "" if governance_id is None else str(governance_id),
            "create_timestamp": str(create_timestamp or ""),
            "layer_from": str(layer_from or ""),
            "layer_to": str(layer_to or ""),
        }
    }]


def _build_spark_application(job_cd: str, job_id: int, sql_query: str, src_conn: str, dst_conn: str, layer_from: str, layer_to: str) -> dict:
    return {
        "typeName": "spark_application",
        "attributes": {
            "qualifiedName": _spark_app_qn(job_cd, job_id),
            "name": str(job_cd),
            "applicationId": str(job_cd),
        },
        "classifications": _gov_classification(
            job_cd=job_cd,
            job_id=job_id,
            sql_query=sql_query,
            src_conn=src_conn,
            dst_conn=dst_conn,
            governance_id=None,
            create_timestamp=None,
            layer_from=layer_from,
            layer_to=layer_to,
        ),
    }


def _build_spark_process(
    job_cd: str,
    job_id: int,
    governance_id: int,
    sql_query: str,
    src_conn: str,
    dst_conn: str,
    src_table_ref: dict,
    dst_table_ref: dict,
    layer_from: str,
    layer_to: str,
) -> dict:
    return {
        "typeName": "spark_process",
        "attributes": {
            "qualifiedName": _spark_proc_qn(job_cd, governance_id),
            "name": f"{job_cd}:{governance_id}",
            "description": str(sql_query or ""),
        },
        "relationshipAttributes": {
            "application": _entity_ref("spark_application", _spark_app_qn(job_cd, job_id)),
            "inputs": [src_table_ref],
            "outputs": [dst_table_ref],
        },
        "classifications": _gov_classification(
            job_cd=job_cd,
            job_id=job_id,
            sql_query=sql_query,
            src_conn=src_conn,
            dst_conn=dst_conn,
            governance_id=governance_id,
            create_timestamp=None,
            layer_from=layer_from,
            layer_to=layer_to,
        ),
    }


def _build_spark_column_lineage(
    job_cd: str,
    job_id: int,
    governance_id: int,
    create_timestamp: str,
    sql_query: str,
    src_conn: str,
    dst_conn: str,
    src_column_ref: dict,
    dst_column_ref: dict,
    process_qn: str,
    layer_from: str,
    layer_to: str,
) -> dict:
    """
    Native Atlas type per Cloudera docs:
      typeName = spark_column_lineage
      relationships: process, inputs, outputs

    If your cluster uses a different relationship key than 'process',
    change only that key here.
    """
    return {
        "typeName": "spark_column_lineage",
        "attributes": {
            "qualifiedName": _spark_col_lineage_qn(job_cd, governance_id),
            "name": _spark_col_lineage_qn(job_cd, governance_id),
        },
        "relationshipAttributes": {
            "process": _entity_ref("spark_process", process_qn),
            "inputs": [src_column_ref],
            "outputs": [dst_column_ref],
        },
        "classifications": _gov_classification(
            job_cd=job_cd,
            job_id=job_id,
            sql_query=sql_query,
            src_conn=src_conn,
            dst_conn=dst_conn,
            governance_id=governance_id,
            create_timestamp=create_timestamp,
            layer_from=layer_from,
            layer_to=layer_to,
        ),
    }

# ============================================================
# Main processing
# ============================================================

def _chunked(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _set_checkpoint(value: int) -> None:
    Variable.set(ATLAS_LAST_GOV_ID_VAR, str(int(value)))


def _process_batches(atlas_url: str, start_last_id: int) -> dict:
    _ensure_governance_classification(atlas_url)

    total_rows = 0
    total_apps = 0
    total_processes = 0
    total_column_lineage = 0
    total_skipped = 0
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

        apps = {}
        processes = []
        column_lineages = []

        for row in rows:
            try:
                governance_id = int(row["governance_id"])
                job_id = row.get("job_id")
                if job_id is None:
                    total_skipped += 1
                    continue

                job = jobs.get(int(job_id))
                if not job:
                    total_skipped += 1
                    continue

                job_cd = str(job.get("job_cd") or f"job_{job_id}")
                sql_query = job.get("sql_query") or ""
                src_conn = _normalize_conn(job.get("data_src_conn_cd"))
                dst_conn = _normalize_conn(job.get("dest_conn_cd"))

                src_schema = row.get("source_schema_name")
                src_table = row.get("source_table_name")
                src_column = row.get("source_column_name") or row.get("source_column_name_desc")

                dst_schema = row.get("destination_schema_name")
                dst_table = row.get("destination_table_name")
                dst_column = row.get("destination_column_name") or row.get("destination_column_name_desc")

                src_table_ref, src_column_ref = _resolve_source_ref(
                    atlas_url=atlas_url,
                    src_conn=src_conn,
                    src_schema=src_schema,
                    src_table=src_table,
                    src_column=src_column,
                )

                dst_table_ref, dst_column_ref = _resolve_target_hive_ref(
                    atlas_url=atlas_url,
                    dst_schema=dst_schema,
                    dst_table=dst_table,
                    dst_column=dst_column,
                )

                if not src_table_ref or not src_column_ref or not dst_table_ref or not dst_column_ref:
                    total_skipped += 1
                    logger.warning("Skipped governance_id=%s because source/target entity could not be resolved", governance_id)
                    continue

                layer_from = _detect_layer(_source_defaults_from_conn(src_conn, src_schema, src_table, src_column)[0])
                layer_to = _detect_layer(_normalize_dest_schema(dst_schema))

                app_qn = _spark_app_qn(job_cd, int(job_id))
                if app_qn not in apps:
                    apps[app_qn] = _build_spark_application(
                        job_cd=job_cd,
                        job_id=int(job_id),
                        sql_query=sql_query,
                        src_conn=src_conn,
                        dst_conn=dst_conn,
                        layer_from=layer_from,
                        layer_to=layer_to,
                    )

                proc_qn = _spark_proc_qn(job_cd, governance_id)

                processes.append(
                    _build_spark_process(
                        job_cd=job_cd,
                        job_id=int(job_id),
                        governance_id=governance_id,
                        sql_query=sql_query,
                        src_conn=src_conn,
                        dst_conn=dst_conn,
                        src_table_ref=src_table_ref,
                        dst_table_ref=dst_table_ref,
                        layer_from=layer_from,
                        layer_to=layer_to,
                    )
                )

                column_lineages.append(
                    _build_spark_column_lineage(
                        job_cd=job_cd,
                        job_id=int(job_id),
                        governance_id=governance_id,
                        create_timestamp=str(row.get("create_timestamp") or ""),
                        sql_query=sql_query,
                        src_conn=src_conn,
                        dst_conn=dst_conn,
                        src_column_ref=src_column_ref,
                        dst_column_ref=dst_column_ref,
                        process_qn=proc_qn,
                        layer_from=layer_from,
                        layer_to=layer_to,
                    )
                )

            except Exception as exc:
                total_skipped += 1
                logger.warning(
                    "Skipped governance row: governance_id=%s error=%s",
                    row.get("governance_id"),
                    str(exc),
                )
                continue

        apps_list = list(apps.values())

        for chunk in _chunked(apps_list, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        for chunk in _chunked(processes, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        for chunk in _chunked(column_lineages, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        batch_max_id = max(int(r["governance_id"]) for r in rows)
        _set_checkpoint(batch_max_id)
        current_last_id = batch_max_id

        total_apps += len(apps_list)
        total_processes += len(processes)
        total_column_lineage += len(column_lineages)

    return {
        "start_last_governance_id": start_last_id,
        "end_last_governance_id": current_last_id,
        "total_rows": total_rows,
        "total_apps": total_apps,
        "total_processes": total_processes,
        "total_column_lineage": total_column_lineage,
        "total_skipped": total_skipped,
        "total_batches": total_batches,
    }

# ============================================================
# DAG
# ============================================================

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id=DAG_ID,
    default_args=default_args,
    description="Simple native Atlas Spark lineage from PostgreSQL governance",
    start_date=datetime(2026, 1, 1),
    schedule_interval=None,  # run manually first
    catchup=False,
    max_active_runs=1,
    tags=["atlas", "spark", "native", "simple", "governance"],
) as dag:

    @task
    def validate_runtime_config() -> dict:
        return _runtime_config()

    @task
    def kinit_and_test(cfg: dict) -> dict:
        _kinit(cfg["principal"], cfg["keytab"])
        _curl_atlas_json(cfg["atlas_url"], "/api/atlas/v2/types/typedefs", "GET")
        return cfg

    @task
    def process_governance(cfg: dict) -> dict:
        return _process_batches(cfg["atlas_url"], cfg["last_governance_id"])

    @task
    def emit_summary(summary: dict) -> None:
        logger.info("=== SUMMARY ===")
        logger.info("Start checkpoint  : %s", summary["start_last_governance_id"])
        logger.info("End checkpoint    : %s", summary["end_last_governance_id"])
        logger.info("Total rows        : %s", summary["total_rows"])
        logger.info("Spark applications: %s", summary["total_apps"])
        logger.info("Spark processes   : %s", summary["total_processes"])
        logger.info("Column lineage    : %s", summary["total_column_lineage"])
        logger.info("Skipped rows      : %s", summary["total_skipped"])
        logger.info("Batches           : %s", summary["total_batches"])

    cfg = validate_runtime_config()
    cfg2 = kinit_and_test(cfg)
    summary = process_governance(cfg2)
    emit_summary(summary)
```

---

## Why this is the right native design

Cloudera documents that Atlas models a Spark job as a **`spark_application`** and the executed units as **`spark_process`** entities connected by **inputs**, **outputs**, and **application** relationships. It also documents a native **`spark_column_lineage`** entity with input columns, output column, and relationship to the producing process. Atlas lineage graphs are built from those relationships. ([Cloudera Docs][1])

---

## Notes

The only place you may need one tiny adjustment is this line inside `_build_spark_column_lineage`:

```python
"process": _entity_ref("spark_process", process_qn),
```

If your cluster uses a different relationship attribute name for `spark_column_lineage`, change only `"process"` to the exact name shown by one existing `spark_column_lineage` entity in your Atlas.

---

## Steps to run

1. Put the file in Airflow DAGs folder.
2. Set:

   ```text
   gca_atlas_last_governance_id = 0
   ```
3. Run manually.
4. Validate:

   * one `spark_application` per job
   * many `spark_process` under that job
   * target Hive tables and columns are connected
   * column lineage appears from source to target
5. Then add a schedule, for example:

   ```python
   schedule_interval="*/15 * * * *"
   ```

If you want, I can give you one very short **Postgres query set** to test 5 sample rows before you run the full load.

[1]: https://docs.cloudera.com/runtime/7.3.1/atlas-reference/topics/atlas-spark-lineage.html?utm_source=chatgpt.com "Spark lineage | Cloudera on Cloud"
