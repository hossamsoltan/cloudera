Below is the **final professional design and DAG** for your case.

It does this:

* reads governance metadata from **PostgreSQL**
* treats every `job_cd` as a **real Spark job**
* reuses existing native Atlas **Hive entities**

  * `hive_db`
  * `hive_table`
  * `hive_column`
* reuses existing native Atlas **source entities** for mixed source systems
* creates native **`spark_application`** and **`spark_process`** lineage
* preserves your governance metadata on the process through a native Atlas **classification**
* uses `@data_like` for the new Spark application/process qualified names
* updates `gca_atlas_last_governance_id` incrementally

This is the cleanest way to stay **native** and still keep your business metadata.

---

# 1. What this DAG expects

Before running it, these things must already be true.

## Atlas side

Your target Hive objects already exist in Atlas natively, which your screenshots confirmed.

Examples from your cluster:

* Hive DB QN:

  * `slv_hasib@cm`
* Hive table QN:

  * `brz_itsm.changehistory@cm`
* Hive column QN:

  * `brz_itsm.changehistory.historyid@cm`

Your Spark native type exists too:

* `spark_process`

## Source side

For each non-Hive source connection, Atlas must already contain the native source entities you want to reference.

This DAG does **not** create fake source entities.
It **references existing native source assets** using mapping templates you configure once.

That is the professional behavior.

---

# 2. Airflow variables required

Create or keep these variables:

```text
gca_atlas_last_governance_id
gca_atlas_url
gca_atlas_kerberos_principal
gca_atlas_kerberos_keytab
```

For first full load:

```text
gca_atlas_last_governance_id = 0
```

---

# 3. PostgreSQL indexes

Run these once:

```sql
CREATE INDEX IF NOT EXISTS idx_dlg_governance_id
    ON public.data_like_governance (governance_id);

CREATE INDEX IF NOT EXISTS idx_dlg_job_id
    ON public.data_like_governance (job_id);

CREATE INDEX IF NOT EXISTS idx_dtj_job_id
    ON public.data_transfer_job (job_id);
```

---

# 4. Source mapping you must fill once

Because your sources are mixed, the DAG uses a config section to resolve the native Atlas qualified names for each source system.

You must fill the mapping for each connection code.

Examples:

* `mostaql`
* `etimad`
* `excel_data`
* `excel_sheet`
* any other source connection

If a source is already Hive, the DAG automatically uses native Hive QNs.

If a source is non-Hive, the DAG uses the mapping template you define.

---

# 5. What metadata is preserved

The DAG creates a native Atlas classification called:

```text
data_like_governance_meta
```

and applies it to every new Spark application and Spark process with these attributes:

* `job_cd`
* `job_id`
* `sql_query`
* `source_connection`
* `destination_connection`
* `governance_id`
* `create_timestamp`
* `layer_from`
* `layer_to`

This keeps your business/governance metadata without breaking native Atlas entities.

---

# 6. Final Airflow DAG

Save this file as:

```text
gca_atlas_native_spark_lineage_final.py
```

Put it in your Airflow DAGs folder.

```python
import json
import logging
import os
import re
import subprocess
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta

from airflow import DAG
from airflow.decorators import task
from airflow.exceptions import AirflowException
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook

# ============================================================
# Configuration
# ============================================================

DAG_ID = "gca_atlas_native_spark_lineage_final"
POSTGRES_CONN_ID = "datalike_db"

ATLAS_LAST_GOV_ID_VAR = "gca_atlas_last_governance_id"
ATLAS_URL_VAR = "gca_atlas_url"
ATLAS_KRB_PRINCIPAL_VAR = "gca_atlas_kerberos_principal"
ATLAS_KRB_KEYTAB_VAR = "gca_atlas_kerberos_keytab"

DB_FETCH_BATCH_SIZE = 2000
ATLAS_PUSH_CHUNK_SIZE = 200
CURL_TIMEOUT_SEC = 300
PROCESS_LOOP_MAX_BATCHES_PER_RUN = 1000

CLUSTER_NAME = "cm"
GOV_CLASSIFICATION_NAME = "data_like_governance_meta"

# ============================================================
# Source-system native Atlas mapping
# Fill this section carefully for every non-Hive source system.
# ============================================================
#
# table_qn_template and column_qn_template must match the REAL
# native Atlas qualifiedName pattern already present in your Atlas.
#
# Examples below are placeholders. Replace them with your real ones.
#
SOURCE_SYSTEM_MAP = {
    # Example relational source
    "mostaql": {
        "table_type": "rdbms_table",
        "column_type": "rdbms_column",
        "table_qn_template": "{schema}.{table}@cm",              # CHANGE THIS if your Atlas uses a different QN
        "column_qn_template": "{schema}.{table}.{column}@cm",   # CHANGE THIS if your Atlas uses a different QN
    },
    "etimad": {
        "table_type": "rdbms_table",
        "column_type": "rdbms_column",
        "table_qn_template": "{schema}.{table}@cm",              # CHANGE THIS
        "column_qn_template": "{schema}.{table}.{column}@cm",   # CHANGE THIS
    },
    # Example Excel modeled through native existing entities in Atlas
    "excel_data": {
        "table_type": "rdbms_table",
        "column_type": "rdbms_column",
        "table_qn_template": "{schema}.{table}@cm",              # CHANGE THIS
        "column_qn_template": "{schema}.{table}.{column}@cm",   # CHANGE THIS
    },
    "excel_sheet": {
        "table_type": "rdbms_table",
        "column_type": "rdbms_column",
        "table_qn_template": "{schema}.{table}@cm",              # CHANGE THIS
        "column_qn_template": "{schema}.{table}.{column}@cm",   # CHANGE THIS
    },
    # If you have a Hive source connection, you do NOT need a mapping here.
}

# ============================================================
# Logging
# ============================================================

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ============================================================
# Helpers
# ============================================================

def _require_var(name: str) -> str:
    value = Variable.get(name, default_var=None)
    if value is None or str(value).strip() == "":
        raise AirflowException(f"Required Airflow Variable '{name}' is missing or empty")
    return str(value).strip()


def _runtime_config() -> dict:
    atlas_url = _require_var(ATLAS_URL_VAR).rstrip("/")
    principal = _require_var(ATLAS_KRB_PRINCIPAL_VAR)
    keytab = _require_var(ATLAS_KRB_KEYTAB_VAR)
    last_raw = Variable.get(ATLAS_LAST_GOV_ID_VAR, default_var="0")

    try:
        last_id = int(str(last_raw).strip())
    except Exception as exc:
        raise AirflowException(f"Invalid value for {ATLAS_LAST_GOV_ID_VAR}: {last_raw}") from exc

    if not os.path.exists(keytab):
        raise AirflowException(f"Kerberos keytab not found: {keytab}")

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
            raise AirflowException(f"Unable to parse Atlas HTTP response for {url}")

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


def _safe_lower(v: str | None) -> str:
    return (v or "").strip().lower()


def _normalize_identifier(v: str | None) -> str:
    s = _safe_lower(v)
    s = re.sub(r"\buat\b", "", s)
    s = re.sub(r"[_\-\s]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def _normalize_connection_name(v: str | None) -> str:
    s = _normalize_identifier(v)
    s = re.sub(r"(^|_)(uat)($|_)", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s or "unknown_conn"


def _normalize_schema(v: str | None, fallback: str = "unknown_schema") -> str:
    s = _normalize_identifier(v)
    return s or fallback


def _normalize_table(v: str | None, fallback: str = "unknown_table") -> str:
    s = _normalize_identifier(v)
    return s or fallback


def _normalize_column(v: str | None, fallback: str = "unknown_column") -> str:
    s = _normalize_identifier(v)
    return s or fallback


def _detect_layer(schema_name: str) -> str:
    s = _safe_lower(schema_name)
    if s.startswith("brz"):
        return "bronze"
    if s.startswith("slv"):
        return "silver"
    if s.startswith("gld"):
        return "gold"
    return "source"


def _is_hive_schema(schema_name: str) -> bool:
    s = _safe_lower(schema_name)
    return s.startswith("brz") or s.startswith("slv") or s.startswith("gld")


def _is_hive_connection(conn_name: str) -> bool:
    c = _safe_lower(conn_name)
    return "hive" in c or c == "spark" or c == "hms"


def _hive_db_qn(db_name: str) -> str:
    return f"{db_name}@{CLUSTER_NAME}"


def _hive_table_qn(db_name: str, table_name: str) -> str:
    return f"{db_name}.{table_name}@{CLUSTER_NAME}"


def _hive_column_qn(db_name: str, table_name: str, column_name: str) -> str:
    return f"{db_name}.{table_name}.{column_name}@{CLUSTER_NAME}"


def _spark_app_qn(job_cd: str, job_id: int) -> str:
    return f"spark_app.{_normalize_identifier(job_cd)}.{job_id}@data_like"


def _spark_process_table_qn(job_cd: str, job_id: int, src_table_qn: str, dst_table_qn: str) -> str:
    return (
        f"spark_process.table."
        f"{_normalize_identifier(job_cd)}.{job_id}."
        f"{_normalize_identifier(src_table_qn)}."
        f"{_normalize_identifier(dst_table_qn)}@data_like"
    )


def _spark_process_column_qn(job_cd: str, governance_id: int, src_col_qn: str, dst_col_qn: str) -> str:
    return (
        f"spark_process.column."
        f"{_normalize_identifier(job_cd)}.{governance_id}."
        f"{_normalize_identifier(src_col_qn)}."
        f"{_normalize_identifier(dst_col_qn)}@data_like"
    )


def _classification_payload(
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
    return [
        {
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
            },
        }
    ]


def _entity_ref(type_name: str, qualified_name: str) -> dict:
    return {
        "typeName": type_name,
        "uniqueAttributes": {
            "qualifiedName": qualified_name
        }
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
        logger.info("Classification %s already exists", GOV_CLASSIFICATION_NAME)
        return

    payload = {
        "classificationDefs": [
            {
                "category": "CLASSIFICATION",
                "name": GOV_CLASSIFICATION_NAME,
                "description": "Business metadata from Data Like governance tables",
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
    logger.info("Created classification %s", GOV_CLASSIFICATION_NAME)


def _entity_exists_by_qn(atlas_url: str, type_name: str, qualified_name: str) -> bool:
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

def _resolve_source_native_ref(
    atlas_url: str,
    src_conn: str,
    src_schema: str,
    src_table: str,
    src_column: str,
) -> tuple[dict, dict]:
    """
    Returns:
      source_table_ref, source_column_ref

    Professional rule:
      - If source is Hive-like, reuse native hive_* entities.
      - Else use SOURCE_SYSTEM_MAP to resolve native existing source entities.
      - Fail if mapping is missing or entity does not exist.
    """
    if _is_hive_schema(src_schema) or _is_hive_connection(src_conn):
        table_qn = _hive_table_qn(src_schema, src_table)
        column_qn = _hive_column_qn(src_schema, src_table, src_column)

        if not _entity_exists_by_qn(atlas_url, "hive_table", table_qn):
            raise AirflowException(f"Native source hive_table not found in Atlas: {table_qn}")
        if not _entity_exists_by_qn(atlas_url, "hive_column", column_qn):
            raise AirflowException(f"Native source hive_column not found in Atlas: {column_qn}")

        return (
            _entity_ref("hive_table", table_qn),
            _entity_ref("hive_column", column_qn),
        )

    source_cfg = SOURCE_SYSTEM_MAP.get(src_conn)
    if not source_cfg:
        raise AirflowException(
            f"No SOURCE_SYSTEM_MAP entry found for source connection '{src_conn}'. "
            f"Add its native Atlas mapping before running."
        )

    table_qn = source_cfg["table_qn_template"].format(
        conn=src_conn,
        schema=src_schema,
        table=src_table,
        column=src_column,
        cluster=CLUSTER_NAME,
    )
    column_qn = source_cfg["column_qn_template"].format(
        conn=src_conn,
        schema=src_schema,
        table=src_table,
        column=src_column,
        cluster=CLUSTER_NAME,
    )

    table_type = source_cfg["table_type"]
    column_type = source_cfg["column_type"]

    if not _entity_exists_by_qn(atlas_url, table_type, table_qn):
        raise AirflowException(
            f"Native source table not found in Atlas: type={table_type}, qualifiedName={table_qn}"
        )

    if not _entity_exists_by_qn(atlas_url, column_type, column_qn):
        raise AirflowException(
            f"Native source column not found in Atlas: type={column_type}, qualifiedName={column_qn}"
        )

    return (
        _entity_ref(table_type, table_qn),
        _entity_ref(column_type, column_qn),
    )


def _resolve_target_hive_ref(
    atlas_url: str,
    dst_schema: str,
    dst_table: str,
    dst_column: str,
) -> tuple[dict, dict]:
    table_qn = _hive_table_qn(dst_schema, dst_table)
    column_qn = _hive_column_qn(dst_schema, dst_table, dst_column)

    if not _entity_exists_by_qn(atlas_url, "hive_table", table_qn):
        raise AirflowException(f"Target hive_table not found in Atlas: {table_qn}")

    if not _entity_exists_by_qn(atlas_url, "hive_column", column_qn):
        raise AirflowException(f"Target hive_column not found in Atlas: {column_qn}")

    return (
        _entity_ref("hive_table", table_qn),
        _entity_ref("hive_column", column_qn),
    )


# ============================================================
# Atlas entity builders
# ============================================================

def _build_spark_application_entity(job_cd: str, job_id: int, sql_query: str, src_conn: str, dst_conn: str, layer_from: str, layer_to: str) -> dict:
    app_qn = _spark_app_qn(job_cd, job_id)
    return {
        "typeName": "spark_application",
        "attributes": {
            "qualifiedName": app_qn,
            "name": str(job_cd),
            "applicationId": str(job_cd),
        },
        "classifications": _classification_payload(
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


def _build_table_spark_process_entity(
    job_cd: str,
    job_id: int,
    sql_query: str,
    src_conn: str,
    dst_conn: str,
    src_table_ref: dict,
    dst_table_ref: dict,
    layer_from: str,
    layer_to: str,
    governance_min_id: int,
    governance_max_id: int,
) -> dict:
    src_table_qn = src_table_ref["uniqueAttributes"]["qualifiedName"]
    dst_table_qn = dst_table_ref["uniqueAttributes"]["qualifiedName"]
    app_qn = _spark_app_qn(job_cd, job_id)

    return {
        "typeName": "spark_process",
        "attributes": {
            "qualifiedName": _spark_process_table_qn(job_cd, job_id, src_table_qn, dst_table_qn),
            "name": str(job_cd),
            "description": str(sql_query or ""),
        },
        "relationshipAttributes": {
            "application": _entity_ref("spark_application", app_qn),
            "inputs": [src_table_ref],
            "outputs": [dst_table_ref],
        },
        "classifications": _classification_payload(
            job_cd=job_cd,
            job_id=job_id,
            sql_query=sql_query,
            src_conn=src_conn,
            dst_conn=dst_conn,
            governance_id=governance_min_id if governance_min_id == governance_max_id else governance_max_id,
            create_timestamp=None,
            layer_from=layer_from,
            layer_to=layer_to,
        ),
    }


def _build_column_spark_process_entity(
    job_cd: str,
    job_id: int,
    governance_id: int,
    create_timestamp: str,
    sql_query: str,
    src_conn: str,
    dst_conn: str,
    src_column_ref: dict,
    dst_column_ref: dict,
    layer_from: str,
    layer_to: str,
) -> dict:
    src_col_qn = src_column_ref["uniqueAttributes"]["qualifiedName"]
    dst_col_qn = dst_column_ref["uniqueAttributes"]["qualifiedName"]
    app_qn = _spark_app_qn(job_cd, job_id)

    return {
        "typeName": "spark_process",
        "attributes": {
            "qualifiedName": _spark_process_column_qn(job_cd, governance_id, src_col_qn, dst_col_qn),
            "name": f"{job_cd}:{governance_id}",
            "description": str(sql_query or ""),
        },
        "relationshipAttributes": {
            "application": _entity_ref("spark_application", app_qn),
            "inputs": [src_column_ref],
            "outputs": [dst_column_ref],
        },
        "classifications": _classification_payload(
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


def _chunked(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _bulk_upsert(atlas_url: str, entities: list[dict]) -> dict:
    if not entities:
        return {}
    return _curl_atlas_json(atlas_url, "/api/atlas/v2/entity/bulk", "POST", {"entities": entities})


def _set_checkpoint(value: int) -> None:
    Variable.set(ATLAS_LAST_GOV_ID_VAR, str(int(value)))


# ============================================================
# Main processing
# ============================================================

def _build_entities_for_batch(atlas_url: str, rows: list[dict], jobs: dict[int, dict]) -> tuple[list[dict], list[dict], list[dict]]:
    """
    Returns:
      spark_application_entities,
      table_spark_process_entities,
      column_spark_process_entities
    """
    spark_apps = {}
    table_process_groups = {}
    column_processes = []

    for row in rows:
        governance_id = int(row["governance_id"])
        job_id = row.get("job_id")
        if job_id is None:
            continue

        job = jobs.get(int(job_id))
        if not job:
            logger.warning("Skipping governance_id=%s because job_id=%s not found in data_transfer_job", governance_id, job_id)
            continue

        job_cd = str(job.get("job_cd") or f"job_{job_id}")
        sql_query = job.get("sql_query") or ""
        src_conn = _normalize_connection_name(job.get("data_src_conn_cd"))
        dst_conn = _normalize_connection_name(job.get("dest_conn_cd"))

        src_schema = _normalize_schema(row.get("source_schema_name"), fallback="unknown_schema")
        src_table = _normalize_table(row.get("source_table_name"), fallback="unknown_table")
        src_column = _normalize_column(row.get("source_column_name") or row.get("source_column_name_desc"), fallback="unknown_column")

        dst_schema = _normalize_schema(row.get("destination_schema_name"), fallback="unknown_schema")
        dst_table = _normalize_table(row.get("destination_table_name"), fallback="unknown_table")
        dst_column = _normalize_column(row.get("destination_column_name") or row.get("destination_column_name_desc"), fallback="unknown_column")

        if not _is_hive_schema(dst_schema):
            raise AirflowException(
                f"Destination schema '{dst_schema}' is not medallion Hive (brz/slv/gld). "
                f"Current native DAG expects Hive targets."
            )

        layer_from = _detect_layer(src_schema)
        layer_to = _detect_layer(dst_schema)

        # Reuse native existing source entities
        src_table_ref, src_column_ref = _resolve_source_native_ref(
            atlas_url=atlas_url,
            src_conn=src_conn,
            src_schema=src_schema,
            src_table=src_table,
            src_column=src_column,
        )

        # Reuse native existing target Hive entities
        dst_table_ref, dst_column_ref = _resolve_target_hive_ref(
            atlas_url=atlas_url,
            dst_schema=dst_schema,
            dst_table=dst_table,
            dst_column=dst_column,
        )

        app_qn = _spark_app_qn(job_cd, int(job_id))
        if app_qn not in spark_apps:
            spark_apps[app_qn] = _build_spark_application_entity(
                job_cd=job_cd,
                job_id=int(job_id),
                sql_query=sql_query,
                src_conn=src_conn,
                dst_conn=dst_conn,
                layer_from=layer_from,
                layer_to=layer_to,
            )

        table_key = (
            int(job_id),
            src_table_ref["typeName"],
            src_table_ref["uniqueAttributes"]["qualifiedName"],
            dst_table_ref["typeName"],
            dst_table_ref["uniqueAttributes"]["qualifiedName"],
        )

        if table_key not in table_process_groups:
            table_process_groups[table_key] = {
                "job_cd": job_cd,
                "job_id": int(job_id),
                "sql_query": sql_query,
                "src_conn": src_conn,
                "dst_conn": dst_conn,
                "src_table_ref": src_table_ref,
                "dst_table_ref": dst_table_ref,
                "layer_from": layer_from,
                "layer_to": layer_to,
                "governance_ids": [],
            }

        table_process_groups[table_key]["governance_ids"].append(governance_id)

        column_processes.append(
            _build_column_spark_process_entity(
                job_cd=job_cd,
                job_id=int(job_id),
                governance_id=governance_id,
                create_timestamp=str(row.get("create_timestamp") or ""),
                sql_query=sql_query,
                src_conn=src_conn,
                dst_conn=dst_conn,
                src_column_ref=src_column_ref,
                dst_column_ref=dst_column_ref,
                layer_from=layer_from,
                layer_to=layer_to,
            )
        )

    table_processes = []
    for grp in table_process_groups.values():
        table_processes.append(
            _build_table_spark_process_entity(
                job_cd=grp["job_cd"],
                job_id=grp["job_id"],
                sql_query=grp["sql_query"],
                src_conn=grp["src_conn"],
                dst_conn=grp["dst_conn"],
                src_table_ref=grp["src_table_ref"],
                dst_table_ref=grp["dst_table_ref"],
                layer_from=grp["layer_from"],
                layer_to=grp["layer_to"],
                governance_min_id=min(grp["governance_ids"]),
                governance_max_id=max(grp["governance_ids"]),
            )
        )

    return list(spark_apps.values()), table_processes, column_processes


def _process_batches(atlas_url: str, start_last_id: int) -> dict:
    _ensure_governance_classification(atlas_url)

    total_rows = 0
    total_spark_apps = 0
    total_table_processes = 0
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

        spark_apps, table_processes, column_processes = _build_entities_for_batch(atlas_url, rows, jobs)

        logger.info(
            "Batch rows=%s spark_apps=%s table_processes=%s column_processes=%s",
            len(rows), len(spark_apps), len(table_processes), len(column_processes)
        )

        # Create/update spark applications first
        for chunk in _chunked(spark_apps, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        # Table-level lineage
        for chunk in _chunked(table_processes, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        # Column-level lineage
        for chunk in _chunked(column_processes, ATLAS_PUSH_CHUNK_SIZE):
            _bulk_upsert(atlas_url, chunk)

        batch_max_id = max(int(r["governance_id"]) for r in rows)
        _set_checkpoint(batch_max_id)
        current_last_id = batch_max_id

        total_spark_apps += len(spark_apps)
        total_table_processes += len(table_processes)
        total_column_processes += len(column_processes)

    return {
        "start_last_governance_id": start_last_id,
        "end_last_governance_id": current_last_id,
        "total_rows": total_rows,
        "total_spark_apps": total_spark_apps,
        "total_table_processes": total_table_processes,
        "total_column_processes": total_column_processes,
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
    description="Native Atlas Spark lineage from PostgreSQL governance tables",
    start_date=datetime(2026, 1, 1),
    schedule_interval=None,   # Run manually first. Add cron later.
    catchup=False,
    max_active_runs=1,
    tags=["atlas", "spark", "lineage", "native", "governance"],
) as dag:

    @task
    def validate_runtime_config() -> dict:
        cfg = _runtime_config()
        logger.info("Runtime config validated. atlas_url=%s last_governance_id=%s", cfg["atlas_url"], cfg["last_governance_id"])
        return cfg

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
        logger.info("=== FINAL NATIVE SPARK LINEAGE SUMMARY ===")
        logger.info("Start checkpoint      : %s", summary["start_last_governance_id"])
        logger.info("End checkpoint        : %s", summary["end_last_governance_id"])
        logger.info("Total rows            : %s", summary["total_rows"])
        logger.info("Spark applications    : %s", summary["total_spark_apps"])
        logger.info("Table spark processes : %s", summary["total_table_processes"])
        logger.info("Column spark processes: %s", summary["total_column_processes"])
        logger.info("Batches               : %s", summary["total_batches"])

    cfg = validate_runtime_config()
    cfg2 = kinit_and_test(cfg)
    summary = process_governance(cfg2)
    emit_summary(summary)
```

---

# 7. What you must edit before first run

Only this section:

```python
SOURCE_SYSTEM_MAP = {
    ...
}
```

For each non-Hive source connection, put the **real native Atlas type** and **real native Atlas QN pattern** already present in your Atlas.

Do not guess.

For example, if `mostaql` tables already exist in Atlas as `rdbms_table` with QN like:

```text
dbo.customer@cm
```

then keep:

```python
"mostaql": {
    "table_type": "rdbms_table",
    "column_type": "rdbms_column",
    "table_qn_template": "{schema}.{table}@cm",
    "column_qn_template": "{schema}.{table}.{column}@cm",
}
```

If the real QN pattern is different, change it to the real one.

---

# 8. Deployment steps

## Step 1

Pause old DAGs.

## Step 2

Put the new DAG file in Airflow DAGs folder.

## Step 3

Set:

```text
gca_atlas_last_governance_id = 0
```

for a full reload.

## Step 4

Run this DAG manually first.

## Step 5

Check logs for any source mapping failure.
If a source system is not mapped correctly, the DAG will stop with a clear error.

## Step 6

Validate in Atlas:

* Spark application created
* spark_process created
* Hive target lineage visible
* column-level lineage visible
* classification `data_like_governance_meta` visible on the spark entities

## Step 7

After successful validation, add a schedule.
For example:

```python
schedule_interval="*/15 * * * *"
```

---

# 9. What this final design gives you

You asked for native and professional. This design gives you:

* native **Hive DB / table / column**
* native **spark_application**
* native **spark_process**
* real **table-level Spark lineage**
* real **column-level Spark lineage**
* governance/business metadata preserved through **classification**
* no fake datalike entities
* no duplicate Hive assets
* PostgreSQL used only as the governance metadata source

---

# 10. Important operational note

This DAG **reuses existing native source assets**.

So for every non-Hive source connection, Atlas must already have those source entities onboarded natively, and your `SOURCE_SYSTEM_MAP` must match their actual QN pattern.

That is the correct enterprise behavior.

If you want, the next message can be a **source mapping worksheet** where I help you build the exact `SOURCE_SYSTEM_MAP` entries for each of your source connections one by one.
