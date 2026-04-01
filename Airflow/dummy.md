Use this as the final approach.

Airflow Variables are the right place for runtime config such as your Atlas URL, principal, keytab, and checkpoint, and Atlas bulk entity APIs can create or update entities by unique attributes such as `qualifiedName`. Atlas also supports custom types/entities, which is what we need here because your sources include Hive, RDBMS, and Excel-like inputs, and you want job metadata stored on the lineage process itself. ([Apache Airflow][1])

One important note before the code: this solution gives you stable **process/table lineage** across `src > brz > slv > gld`, and it persists detailed **column mappings** on each process entity. In many Atlas setups, that is the safest REST-driven design. I am not promising that your Atlas UI will draw native column-to-column arrows exactly like Spark hook lineage, because that part can depend on your CDP/Atlas integration behavior.

## What this solution creates

It creates and uses these Atlas types automatically:

* `datalike_dataset` extending `DataSet`
* `datalike_process` extending `Process`

It uses:

* `qualifiedName` for uniqueness
* one dataset entity per logical table
* one process entity per `job_id + source_table + destination_table`
* aggregated column mappings stored in `column_mappings_json`
* `job_cd` as the visible process name
* `job_id`, `job_cd`, `sql_query`, `source_connection`, `destination_connection`, `layer_from`, `layer_to`, `batch_guid` as process attributes

## Single production DAG

Save this file as:

```python
# dags/gca_atlas_governance_lineage_dag.py
```

```python
import json
import logging
import os
import re
import subprocess
import tempfile
import uuid
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

DAG_ID = "gca_atlas_governance_lineage"
POSTGRES_CONN_ID = "datalike_db"

ATLAS_LAST_GOV_ID_VAR = "gca_atlas_last_governance_id"
ATLAS_URL_VAR = "gca_atlas_url"
ATLAS_KRB_PRINCIPAL_VAR = "gca_atlas_kerberos_principal"
ATLAS_KRB_KEYTAB_VAR = "gca_atlas_kerberos_keytab"

# Tune these based on performance
DB_FETCH_BATCH_SIZE = 5000
ATLAS_PUSH_CHUNK_SIZE = 250
CURL_TIMEOUT_SEC = 300
PROCESS_LOOP_MAX_BATCHES_PER_RUN = 1000  # safety guard

DATALIKE_NAMESPACE = "datalikegovernance"

# Atlas custom types
ATLAS_TYPE_DATASET = "datalike_dataset"
ATLAS_TYPE_PROCESS = "datalike_process"

# ============================================================
# Logging
# ============================================================

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ============================================================
# Utility helpers
# ============================================================

def _require_var(name: str) -> str:
    value = Variable.get(name, default_var=None)
    if value is None or str(value).strip() == "":
        raise AirflowException(f"Required Airflow Variable '{name}' is missing or empty")
    return str(value).strip()


def _get_runtime_config() -> dict:
    atlas_url = _require_var(ATLAS_URL_VAR).rstrip("/")
    principal = _require_var(ATLAS_KRB_PRINCIPAL_VAR)
    keytab = _require_var(ATLAS_KRB_KEYTAB_VAR)

    last_id_raw = Variable.get(ATLAS_LAST_GOV_ID_VAR, default_var="0")
    try:
        last_governance_id = int(str(last_id_raw).strip())
    except Exception as exc:
        raise AirflowException(
            f"Invalid value in Airflow Variable '{ATLAS_LAST_GOV_ID_VAR}': {last_id_raw}"
        ) from exc

    if not os.path.exists(keytab):
        raise AirflowException(f"Kerberos keytab does not exist: {keytab}")

    return {
        "atlas_url": atlas_url,
        "principal": principal,
        "keytab": keytab,
        "last_governance_id": last_governance_id,
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
    logger.info("Command stdout: %s", result.stdout.strip())
    if result.stderr.strip():
        logger.warning("Command stderr: %s", result.stderr.strip())
    if check and result.returncode != 0:
        raise AirflowException(
            f"Command failed with return code {result.returncode}: {' '.join(cmd)}\n"
            f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )
    return result


def _kinit(principal: str, keytab: str) -> None:
    _run_cmd(["kinit", "-kt", keytab, principal], check=True)
    _run_cmd(["klist"], check=True)


def _curl_atlas_json(
    atlas_url: str,
    endpoint: str,
    method: str = "GET",
    payload: dict | None = None,
) -> dict:
    """
    Uses curl with:
      -k
      --negotiate -u :
    because the user explicitly requested this path.
    """
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
            temp_file = tempfile.NamedTemporaryFile(
                mode="w", suffix=".json", delete=False, encoding="utf-8"
            )
            json.dump(payload, temp_file, ensure_ascii=False)
            temp_file.flush()
            temp_file.close()

            cmd.extend(
                [
                    "-H",
                    "Content-Type: application/json",
                    "--data",
                    f"@{temp_file.name}",
                ]
            )

        result = _run_cmd(cmd, check=False)

        if "__HTTP_STATUS__:" not in result.stdout:
            raise AirflowException(f"Could not parse Atlas HTTP response for {url}")

        body, status_str = result.stdout.rsplit("__HTTP_STATUS__:", 1)
        status_code = int(status_str.strip())

        body = body.strip()
        if body:
            try:
                parsed = json.loads(body)
            except Exception:
                parsed = {"raw_response": body}
        else:
            parsed = {}

        if status_code >= 400:
            raise AirflowException(
                f"Atlas API call failed: {method} {url} HTTP {status_code}\nResponse: {json.dumps(parsed, ensure_ascii=False)}"
            )

        return parsed
    finally:
        if temp_file and os.path.exists(temp_file.name):
            os.unlink(temp_file.name)


def _safe_lower(value: str | None) -> str:
    return (value or "").strip().lower()


def _normalize_identifier(value: str | None) -> str:
    v = _safe_lower(value)
    v = re.sub(r"\buat\b", "", v)
    v = re.sub(r"[_\-\s]+", "_", v)
    v = re.sub(r"_+", "_", v)
    v = v.strip("_")
    return v


def _normalize_connection_name(value: str | None) -> str:
    """
    Examples:
      hive_uat -> hive
      mostaql_uat -> mostaql
      etimad-uat -> etimad
      excel_data -> excel_data
    """
    v = _normalize_identifier(value)
    v = re.sub(r"(^|_)(uat)($|_)", "_", v)
    v = re.sub(r"_+", "_", v).strip("_")
    return v or "unknown_conn"


def _normalize_schema_name(value: str | None, fallback: str = "unknown_schema") -> str:
    v = _normalize_identifier(value)
    return v or fallback


def _normalize_table_name(value: str | None, fallback: str = "unknown_table") -> str:
    v = _normalize_identifier(value)
    return v or fallback


def _normalize_column_name(value: str | None, fallback: str = "unknown_column") -> str:
    v = _normalize_identifier(value)
    return v or fallback


def _detect_layer(schema_name: str) -> str:
    s = _safe_lower(schema_name)
    if s.startswith("brz"):
        return "bronze"
    if s.startswith("slv"):
        return "silver"
    if s.startswith("gld"):
        return "gold"
    return "source"


def _is_excel_like(conn_name: str) -> bool:
    conn = _safe_lower(conn_name)
    return "excel" in conn or "sheet" in conn or "xls" in conn or "xlsx" in conn


def _build_table_qn(conn: str, schema_name: str, table_name: str) -> str:
    return f"{conn}.{schema_name}.{table_name}@{DATALIKE_NAMESPACE}"


def _build_column_qn(conn: str, schema_name: str, table_name: str, column_name: str) -> str:
    return f"{conn}.{schema_name}.{table_name}.{column_name}@{DATALIKE_NAMESPACE}"


def _coalesce_source_side(row: dict, src_conn: str) -> tuple[str, str, str]:
    """
    If source side is incomplete:
      - excel-like source: schema -> sheet
      - otherwise schema -> nosource_before_<dest_schema or unknown_schema>
      - table -> nosource_before_<dest_table or unknown_table>
      - column -> nosource_before_<dest_column or unknown_column>
    """
    src_schema = _normalize_schema_name(row.get("source_schema_name"), fallback="")
    src_table = _normalize_table_name(row.get("source_table_name"), fallback="")
    src_column = _normalize_column_name(
        row.get("source_column_name") or row.get("source_column_name_desc"),
        fallback="",
    )

    dst_schema = _normalize_schema_name(row.get("destination_schema_name"), fallback="unknown_schema")
    dst_table = _normalize_table_name(row.get("destination_table_name"), fallback="unknown_table")
    dst_column = _normalize_column_name(
        row.get("destination_column_name") or row.get("destination_column_name_desc"),
        fallback="unknown_column",
    )

    if not src_schema:
        src_schema = "sheet" if _is_excel_like(src_conn) else f"nosource_before_{dst_schema}"
    if not src_table:
        src_table = f"nosource_before_{dst_table}"
    if not src_column:
        src_column = f"nosource_before_{dst_column}"

    return src_schema, src_table, src_column


def _json_dumps_compact(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


# ============================================================
# PostgreSQL helpers
# ============================================================

def _get_postgres_hook() -> PostgresHook:
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
    hook = _get_postgres_hook()
    records = hook.get_records(sql, parameters=(last_governance_id, limit))
    desc = [
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
    rows = [dict(zip(desc, rec)) for rec in records]
    return rows


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
    hook = _get_postgres_hook()
    records = hook.get_records(sql, parameters=(job_ids,))
    result = {}
    for rec in records:
        result[int(rec[0])] = {
            "job_id": int(rec[0]),
            "job_cd": rec[1],
            "data_src_conn_cd": rec[2],
            "dest_conn_cd": rec[3],
            "sql_query": rec[4],
        }
    return result


# ============================================================
# Atlas type management
# ============================================================

def _atlas_type_exists(atlas_url: str, type_name: str) -> bool:
    try:
        _curl_atlas_json(atlas_url, f"/api/atlas/v2/types/typedef/name/{type_name}", "GET")
        return True
    except Exception:
        return False


def _ensure_atlas_types(atlas_url: str) -> None:
    missing = []
    for t in (ATLAS_TYPE_DATASET, ATLAS_TYPE_PROCESS):
        if not _atlas_type_exists(atlas_url, t):
            missing.append(t)

    if not missing:
        logger.info("Atlas custom types already exist")
        return

    typedef_payload = {
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
        ]
    }

    _curl_atlas_json(atlas_url, "/api/atlas/v2/types/typedefs", "POST", typedef_payload)
    logger.info("Created missing Atlas custom types: %s", missing)


# ============================================================
# Atlas payload builders
# ============================================================

def _dataset_platform_from_conn(conn: str, schema_name: str) -> str:
    c = _safe_lower(conn)
    if "hive" in c or schema_name.startswith(("brz", "slv", "gld")):
        return "hive"
    if _is_excel_like(c):
        return "excel"
    return "rdbms"


def _build_dataset_entity(
    conn: str,
    schema_name: str,
    table_name: str,
    columns: set[str],
) -> dict:
    layer = _detect_layer(schema_name)
    qn = _build_table_qn(conn, schema_name, table_name)
    display_name = f"{conn}.{schema_name}.{table_name}"
    platform = _dataset_platform_from_conn(conn, schema_name)
    endpoint = f"{conn}.{schema_name}.{table_name}"

    return {
        "typeName": ATLAS_TYPE_DATASET,
        "attributes": {
            "qualifiedName": qn,
            "name": display_name,
            "description": f"{platform} dataset {display_name}",
            "connection_name": conn,
            "schema_name": schema_name,
            "table_name": table_name,
            "layer": layer,
            "platform": platform,
            "endpoint": endpoint,
            "columns_json": _json_dumps_compact(sorted(columns)),
        },
    }


def _build_process_entity(
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
    column_mappings: list[dict],
) -> dict:
    desc_parts = [
        f"job_id={job_id}",
        f"job_cd={job_cd}",
        f"source_connection={src_conn}",
        f"destination_connection={dst_conn}",
        f"layer_from={layer_from}",
        f"layer_to={layer_to}",
    ]
    if sql_query:
        desc_parts.append(f"sql_query={sql_query}")

    return {
        "typeName": ATLAS_TYPE_PROCESS,
        "attributes": {
            "qualifiedName": process_qn,
            "name": process_name,
            "description": " | ".join(desc_parts),
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
            "column_mappings_json": _json_dumps_compact(column_mappings),
            "inputs": [
                {
                    "typeName": ATLAS_TYPE_DATASET,
                    "uniqueAttributes": {
                        "qualifiedName": src_dataset_qn,
                    },
                }
            ],
            "outputs": [
                {
                    "typeName": ATLAS_TYPE_DATASET,
                    "uniqueAttributes": {
                        "qualifiedName": dst_dataset_qn,
                    },
                }
            ],
        },
    }


def _chunked(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _atlas_bulk_upsert_entities(atlas_url: str, entities: list[dict]) -> dict:
    if not entities:
        return {"mutatedEntities": {}, "guidAssignments": {}}

    payload = {"entities": entities}
    return _curl_atlas_json(atlas_url, "/api/atlas/v2/entity/bulk", "POST", payload)


def _build_payload_from_rows(rows: list[dict], jobs_by_id: dict[int, dict]) -> tuple[list[dict], list[dict], dict]:
    """
    Returns:
      dataset_entities, process_entities, stats
    """
    datasets = {}
    dataset_columns_map = defaultdict(set)

    # Aggregate by logical process:
    #   job_id + source dataset + destination dataset
    process_groups = {}

    for row in rows:
        job_id = row.get("job_id")
        if job_id is None:
            logger.warning("Skipping governance_id=%s because job_id is null", row.get("governance_id"))
            continue

        job = jobs_by_id.get(int(job_id))
        if not job:
            logger.warning(
                "Skipping governance_id=%s because job_id=%s not found in data_transfer_job",
                row.get("governance_id"),
                job_id,
            )
            continue

        src_conn = _normalize_connection_name(job.get("data_src_conn_cd"))
        dst_conn = _normalize_connection_name(job.get("dest_conn_cd"))
        job_cd = _safe_lower(job.get("job_cd")) or f"job_{job_id}"
        sql_query = job.get("sql_query") or ""

        src_schema, src_table, src_column = _coalesce_source_side(row, src_conn)
        dst_schema = _normalize_schema_name(row.get("destination_schema_name"), fallback="unknown_schema")
        dst_table = _normalize_table_name(row.get("destination_table_name"), fallback="unknown_table")
        dst_column = _normalize_column_name(
            row.get("destination_column_name") or row.get("destination_column_name_desc"),
            fallback="unknown_column",
        )

        src_layer = _detect_layer(src_schema)
        dst_layer = _detect_layer(dst_schema)

        src_dataset_qn = _build_table_qn(src_conn, src_schema, src_table)
        dst_dataset_qn = _build_table_qn(dst_conn, dst_schema, dst_table)

        dataset_columns_map[(src_conn, src_schema, src_table)].add(src_column)
        dataset_columns_map[(dst_conn, dst_schema, dst_table)].add(dst_column)

        process_qn = (
            f"{job_id}|{src_conn}.{src_schema}.{src_table}|"
            f"{dst_conn}.{dst_schema}.{dst_table}@{DATALIKE_NAMESPACE}"
        )

        if process_qn not in process_groups:
            process_groups[process_qn] = {
                "process_qn": process_qn,
                "process_name": job_cd,  # visible process name
                "src_dataset_qn": src_dataset_qn,
                "dst_dataset_qn": dst_dataset_qn,
                "job_id": int(job_id),
                "job_cd": job.get("job_cd") or f"job_{job_id}",
                "sql_query": sql_query,
                "src_conn": src_conn,
                "dst_conn": dst_conn,
                "layer_from": src_layer,
                "layer_to": dst_layer,
                "governance_ids": [],
                "column_mappings": [],
            }

        process_groups[process_qn]["governance_ids"].append(int(row["governance_id"]))
        process_groups[process_qn]["column_mappings"].append(
            {
                "governance_id": int(row["governance_id"]),
                "source_column_qn": _build_column_qn(src_conn, src_schema, src_table, src_column),
                "destination_column_qn": _build_column_qn(dst_conn, dst_schema, dst_table, dst_column),
                "source_column_name": src_column,
                "destination_column_name": dst_column,
                "create_timestamp": str(row.get("create_timestamp") or ""),
            }
        )

    for (conn, schema_name, table_name), cols in dataset_columns_map.items():
        qn = _build_table_qn(conn, schema_name, table_name)
        datasets[qn] = _build_dataset_entity(conn, schema_name, table_name, cols)

    batch_guid = str(uuid.uuid4())
    process_entities = []

    for process_qn, grp in process_groups.items():
        governance_ids = grp["governance_ids"]
        column_mappings = grp["column_mappings"]

        process_entities.append(
            _build_process_entity(
                process_qn=process_qn,
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
                governance_min_id=min(governance_ids),
                governance_max_id=max(governance_ids),
                column_mappings=column_mappings,
            )
        )

    stats = {
        "dataset_count": len(datasets),
        "process_count": len(process_entities),
        "batch_guid": batch_guid,
    }

    return list(datasets.values()), process_entities, stats


# ============================================================
# Checkpoint helpers
# ============================================================

def _set_last_governance_id(value: int) -> None:
    Variable.set(ATLAS_LAST_GOV_ID_VAR, str(int(value)))


# ============================================================
# Main batch processor
# ============================================================

def _process_all_batches(atlas_url: str, start_last_governance_id: int) -> dict:
    total_rows = 0
    total_datasets = 0
    total_processes = 0
    total_batches = 0
    current_last_id = start_last_governance_id

    _ensure_atlas_types(atlas_url)

    for batch_num in range(1, PROCESS_LOOP_MAX_BATCHES_PER_RUN + 1):
        rows = _fetch_governance_batch(current_last_id, DB_FETCH_BATCH_SIZE)
        if not rows:
            logger.info("No more governance rows found after governance_id=%s", current_last_id)
            break

        total_batches += 1
        total_rows += len(rows)

        batch_min_id = min(int(r["governance_id"]) for r in rows)
        batch_max_id = max(int(r["governance_id"]) for r in rows)

        job_ids = sorted({int(r["job_id"]) for r in rows if r.get("job_id") is not None})
        jobs_by_id = _fetch_job_metadata(job_ids)

        dataset_entities, process_entities, stats = _build_payload_from_rows(rows, jobs_by_id)

        logger.info(
            "Batch %s governance_id range %s -> %s : rows=%s datasets=%s processes=%s",
            batch_num,
            batch_min_id,
            batch_max_id,
            len(rows),
            len(dataset_entities),
            len(process_entities),
        )

        # Push datasets first
        for chunk in _chunked(dataset_entities, ATLAS_PUSH_CHUNK_SIZE):
            _atlas_bulk_upsert_entities(atlas_url, chunk)

        # Push processes second
        for chunk in _chunked(process_entities, ATLAS_PUSH_CHUNK_SIZE):
            _atlas_bulk_upsert_entities(atlas_url, chunk)

        # Advance checkpoint only after successful push
        _set_last_governance_id(batch_max_id)
        current_last_id = batch_max_id

        total_datasets += stats["dataset_count"]
        total_processes += stats["process_count"]

    return {
        "start_last_governance_id": start_last_governance_id,
        "end_last_governance_id": current_last_id,
        "total_rows": total_rows,
        "total_datasets": total_datasets,
        "total_processes": total_processes,
        "total_batches": total_batches,
    }


# ============================================================
# Airflow DAG
# ============================================================

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id=DAG_ID,
    description="Push DataLike governance lineage from PostgreSQL into Atlas",
    default_args=default_args,
    start_date=datetime(2026, 1, 1),
    schedule_interval=None,   # change to cron later if needed
    catchup=False,
    max_active_runs=1,
    tags=["atlas", "governance", "lineage", "postgresql", "cdp"],
) as dag:

    @task
    def validate_runtime_config() -> dict:
        cfg = _get_runtime_config()
        logger.info(
            "Runtime config validated. atlas_url=%s principal=%s last_governance_id=%s",
            cfg["atlas_url"],
            cfg["principal"],
            cfg["last_governance_id"],
        )
        return cfg

    @task
    def kinit_atlas(cfg: dict) -> dict:
        _kinit(cfg["principal"], cfg["keytab"])
        # lightweight Atlas reachability check
        _curl_atlas_json(cfg["atlas_url"], "/api/atlas/v2/types/typedefs", "GET")
        logger.info("Kerberos and Atlas connectivity check succeeded")
        return cfg

    @task
    def process_governance(cfg: dict) -> dict:
        summary = _process_all_batches(
            atlas_url=cfg["atlas_url"],
            start_last_governance_id=cfg["last_governance_id"],
        )
        logger.info("Processing summary: %s", json.dumps(summary, ensure_ascii=False))
        return summary

    @task
    def emit_summary(summary: dict) -> None:
        logger.info("=== FINAL SUMMARY ===")
        logger.info("Start checkpoint : %s", summary["start_last_governance_id"])
        logger.info("End checkpoint   : %s", summary["end_last_governance_id"])
        logger.info("Total rows       : %s", summary["total_rows"])
        logger.info("Total datasets   : %s", summary["total_datasets"])
        logger.info("Total processes  : %s", summary["total_processes"])
        logger.info("Total batches    : %s", summary["total_batches"])

    cfg = validate_runtime_config()
    cfg_ok = kinit_atlas(cfg)
    summary = process_governance(cfg_ok)
    emit_summary(summary)
```

## What to create in Atlas

You do **not** need to pre-create entities manually.

This DAG does it automatically.

What it creates the first time:

* Atlas type: `datalike_dataset`
* Atlas type: `datalike_process`

What it creates during each run:

* dataset entities for tables
* process entities for table transitions

Atlas bulk create/update matches entities using unique attributes like `qualifiedName`, so reruns update existing objects instead of blindly creating duplicates when the same qualified names are used. ([atlas.apache.org][2])

## How the qualified names will look

Table level:

```text
conn.schema.table@datalikegovernance
```

Column level mapping entries stored inside process attributes:

```text
conn.schema.table.column@datalikegovernance
```

Examples:

```text
hive.brz_employees.profemployeesrasdprofileshistory@datalikegovernance
mostaql.dbo.mlp_category@datalikegovernance
excel_data.sheet.nosource_before_profemployeesrasdprofileshistory@datalikegovernance
```

## What gets stored on the process

Each process stores:

* `job_id`
* `job_cd`
* `sql_query`
* `source_connection`
* `destination_connection`
* `layer_from`
* `layer_to`
* `batch_guid`
* `governance_min_id`
* `governance_max_id`
* `column_mappings_json`

The visible process `name` is:

```text
job_cd
```

## Required steps on Airflow

Do these exactly.

### 1. Put the DAG file in the DAGs folder

```bash
cp gca_atlas_governance_lineage_dag.py $AIRFLOW_HOME/dags/
```

### 2. Make sure these packages are available in the Airflow runtime

At minimum:

```bash
pip install apache-airflow-providers-postgres psycopg2-binary
```

You are using system `curl` and `kinit`, so this code does **not** require Python Kerberos libraries.

### 3. Make sure the Airflow worker/scheduler OS has these tools

```bash
which curl
which kinit
which klist
```

### 4. Make sure the keytab file exists and is readable by the Airflow runtime user

Example:

```bash
ls -l /path/to/atlas.keytab
```

### 5. Create the Airflow Variables

Create these in Airflow UI or CLI:

```text
gca_atlas_last_governance_id = 0
gca_atlas_url = https://your-atlas-or-knox-fqdn:port
gca_atlas_kerberos_principal = your_principal@REALM
gca_atlas_kerberos_keytab = /full/path/to/your.keytab
```

Airflow Variables are meant for global runtime configuration like this. ([Apache Airflow][1])

### 6. Verify PostgreSQL connection exists in Airflow

Connection ID must be exactly:

```text
datalike_db
```

### 7. Restart or refresh Airflow

Depending on your deployment:

```bash
airflow dags list | grep gca_atlas_governance_lineage
```

### 8. Trigger the DAG manually first

Run one manual test before scheduling it.

## Recommended PostgreSQL indexes

Create these if they do not already exist:

```sql
CREATE INDEX IF NOT EXISTS idx_dlg_governance_id
    ON public.data_like_governance (governance_id);

CREATE INDEX IF NOT EXISTS idx_dlg_job_id
    ON public.data_like_governance (job_id);

CREATE INDEX IF NOT EXISTS idx_dtj_job_id
    ON public.data_transfer_job (job_id);
```

## How the lineage grouping works

One process is created per logical transition:

```text
job_id + source_connection.schema.table + destination_connection.schema.table
```

So if 100 rows map 100 columns from one source table to one destination table under the same job, Atlas gets:

* 2 datasets
* 1 process
* the 100 column mappings stored on that process

That keeps Atlas much cleaner and faster than creating one process per column.

## Your layer logic is applied like this

* schema starts with `brz` → `bronze`
* schema starts with `slv` → `silver`
* schema starts with `gld` → `gold`
* anything else → `source`

That lets your lineage naturally show:

```text
source -> bronze -> silver -> gold
```

when your governance rows contain those transitions.

## How null source is handled

If source metadata is missing:

* source connection comes from `data_src_conn_cd`
* if it looks Excel-like, schema becomes `sheet`
* missing source table becomes `nosource_before_<destination_table>`
* missing source column becomes `nosource_before_<destination_column>`

This prevents lineage breaks.

## Suggested first-run approach

For the first load of ~300,000 rows:

* keep `gca_atlas_last_governance_id = 0`
* run manually
* watch Airflow logs
* confirm new Atlas types were created
* confirm datasets and processes appear
* then set a schedule

## Suggested production schedule after first success

After initial load, set for example:

```python
schedule_interval="*/15 * * * *"
```

or hourly, depending on how often `data_like_governance` changes.

## Fast validation checks

After first successful run:

### Atlas type check

```bash
curl -k --negotiate -u : \
  "${ATLAS_URL}/api/atlas/v2/types/typedef/name/datalike_dataset"
```

```bash
curl -k --negotiate -u : \
  "${ATLAS_URL}/api/atlas/v2/types/typedef/name/datalike_process"
```

### Search dataset

```bash
curl -k --negotiate -u : \
  "${ATLAS_URL}/api/atlas/v2/search/basic?typeName=datalike_dataset"
```

### Search process

```bash
curl -k --negotiate -u : \
  "${ATLAS_URL}/api/atlas/v2/search/basic?typeName=datalike_process"
```

### Check one process entity

Confirm you can see:

* `job_id`
* `job_cd`
* `sql_query`
* `column_mappings_json`

## Practical recommendation

Before running on all 300,000 rows, temporarily reduce:

```python
DB_FETCH_BATCH_SIZE = 500
ATLAS_PUSH_CHUNK_SIZE = 100
```

Run once, validate Atlas objects and lineage, then raise them again.

If you want, next I can give you a second message with:

* a cleanup script to delete only `datalike_dataset` and `datalike_process` entities created by this DAG
* a version of the DAG with scheduling enabled and extra retries/backoff tuned for production

[1]: https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/variables.html?utm_source=chatgpt.com "Variables — Airflow 3.1.8 Documentation"
[2]: https://atlas.apache.org/api/v2/resource_EntityREST.html?utm_source=chatgpt.com "Atlas REST API: EntityREST"
