Good. Now we do the **first live Atlas push**, but only for a **tiny safe batch of 5 rows**.

Atlas supports bulk entity create/update through `/v2/entity/bulk`, and Airflow 3 recommends using `Variable` from `airflow.sdk`. ([atlas.apache.org][1])

## Step 11 — Push 5 test rows from Airflow to Atlas

### 1) Create these Airflow Variables

Add these in **Admin → Variables**:

* `gca_atlas_url` = your direct Atlas URL, for example `http://atlas-host:21000`
* `gca_atlas_kerberos_principal` = your Kerberos principal
* `gca_atlas_keytab_path` = full path to the keytab the Airflow worker can read

This keeps the DAG cleaner and lets you change endpoints without editing code. Airflow Variables are meant for global runtime configuration like this. ([Apache Airflow][2])

---

### 2) Replace your DAG with this version

This version:

* does `kinit -kt`
* reads only 5 rows
* builds `gca_dataset`, `gca_column`, `gca_process`
* pushes them to Atlas in 3 separate bulk calls:

  * datasets first
  * columns second
  * processes third
* does **not** update the watermark yet

```python
from datetime import datetime
import json
import subprocess
import tempfile

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.sdk import Variable


DAG_NAME = "gca_governance_to_atlas"
POSTGRES_CONN_ID = "datalike_db"
BATCH_SIZE = 5
QN_NAMESPACE = "@datalikegovernance"


def safe_str(value):
    if value is None:
        return None
    value = str(value).strip()
    return value if value else None


def normalize_conn_code(value):
    value = safe_str(value)
    if not value:
        return "unknown"

    value = value.lower()
    if value.endswith("_uat"):
        value = value[:-4]

    value = value.strip().replace(" ", "_")
    return value if value else "unknown"


def normalize_name(value, fallback=None):
    value = safe_str(value)
    if not value:
        return fallback
    value = value.lower().strip().replace(" ", "_")
    return value


def classify_type(conn_code, schema_name, table_name):
    conn = normalize_conn_code(conn_code)
    schema_name = safe_str(schema_name)
    table_name = safe_str(table_name)

    if not schema_name and not table_name:
        return "excel"
    if "hive" in conn:
        return "hive"
    return "rdbms"


def build_dataset_qn(conn_norm, obj_type, schema_norm, table_norm):
    if obj_type == "excel":
        return f"excel.{conn_norm}.default.logical_table{QN_NAMESPACE}"
    return f"{conn_norm}.{schema_norm}.{table_norm}{QN_NAMESPACE}"


def build_column_qn(conn_norm, obj_type, schema_norm, table_norm, column_norm):
    if obj_type == "excel":
        return f"excel.{conn_norm}.default.logical_table.{column_norm}{QN_NAMESPACE}"
    return f"{conn_norm}.{schema_norm}.{table_norm}.{column_norm}{QN_NAMESPACE}"


def build_process_qn(
    job_id,
    src_conn_norm,
    src_schema_norm,
    src_table_norm,
    src_column_norm,
    dst_conn_norm,
    dst_schema_norm,
    dst_table_norm,
    dst_column_norm,
):
    return (
        f"process.{job_id}."
        f"{src_conn_norm}.{src_schema_norm}.{src_table_norm}.{src_column_norm}."
        f"{dst_conn_norm}.{dst_schema_norm}.{dst_table_norm}.{dst_column_norm}"
        f"{QN_NAMESPACE}"
    )


def build_dataset_display_name(obj_type, conn_norm, schema_norm, table_norm):
    if obj_type == "excel":
        return f"{conn_norm}.logical_table"
    return f"{schema_norm}.{table_norm}"


def build_column_display_name(obj_type, table_norm, column_norm):
    if obj_type == "excel":
        return f"logical_table.{column_norm}"
    return f"{table_norm}.{column_norm}"


def build_process_display_name(job_cd, job_id):
    return job_cd if job_cd else f"job_{job_id}"


def normalize_record(row):
    (
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
        source_column_name,
        job_cd,
        data_src_conn_cd,
        dest_conn_cd,
        sql_query,
    ) = row

    src_conn_norm = normalize_conn_code(data_src_conn_cd)
    dst_conn_norm = normalize_conn_code(dest_conn_cd)

    src_type = classify_type(data_src_conn_cd, source_schema_name, source_table_name)
    dst_type = classify_type(dest_conn_cd, destination_schema_name, destination_table_name)

    src_schema_norm = normalize_name(source_schema_name, fallback="default")
    src_table_norm = normalize_name(source_table_name, fallback="logical_table")
    src_column_norm = normalize_name(source_column_name, fallback="unknown_column")

    dst_schema_norm = normalize_name(destination_schema_name, fallback="default")
    dst_table_norm = normalize_name(destination_table_name, fallback="logical_table")
    dst_column_norm = normalize_name(destination_column_name, fallback="unknown_column")

    return {
        "governance_id": governance_id,
        "action_type": safe_str(action_type),
        "create_timestamp": str(create_timestamp) if create_timestamp else None,
        "job_id": job_id,
        "job_cd": safe_str(job_cd),
        "sql_query": safe_str(sql_query),
        "source_column_name_desc": safe_str(source_column_name_desc),
        "destination_column_name_desc": safe_str(destination_column_name_desc),
        "src_conn_norm": src_conn_norm,
        "dst_conn_norm": dst_conn_norm,
        "src_type": src_type,
        "dst_type": dst_type,
        "src_schema_norm": src_schema_norm,
        "src_table_norm": src_table_norm,
        "src_column_norm": src_column_norm,
        "dst_schema_norm": dst_schema_norm,
        "dst_table_norm": dst_table_norm,
        "dst_column_norm": dst_column_norm,
    }


def enrich_with_qualified_names(rec):
    rec["src_dataset_qn"] = build_dataset_qn(
        rec["src_conn_norm"], rec["src_type"], rec["src_schema_norm"], rec["src_table_norm"]
    )
    rec["src_column_qn"] = build_column_qn(
        rec["src_conn_norm"], rec["src_type"], rec["src_schema_norm"], rec["src_table_norm"], rec["src_column_norm"]
    )
    rec["dst_dataset_qn"] = build_dataset_qn(
        rec["dst_conn_norm"], rec["dst_type"], rec["dst_schema_norm"], rec["dst_table_norm"]
    )
    rec["dst_column_qn"] = build_column_qn(
        rec["dst_conn_norm"], rec["dst_type"], rec["dst_schema_norm"], rec["dst_table_norm"], rec["dst_column_norm"]
    )
    rec["process_qn"] = build_process_qn(
        rec["job_id"],
        rec["src_conn_norm"], rec["src_schema_norm"], rec["src_table_norm"], rec["src_column_norm"],
        rec["dst_conn_norm"], rec["dst_schema_norm"], rec["dst_table_norm"], rec["dst_column_norm"],
    )

    rec["src_dataset_name"] = build_dataset_display_name(
        rec["src_type"], rec["src_conn_norm"], rec["src_schema_norm"], rec["src_table_norm"]
    )
    rec["dst_dataset_name"] = build_dataset_display_name(
        rec["dst_type"], rec["dst_conn_norm"], rec["dst_schema_norm"], rec["dst_table_norm"]
    )
    rec["src_column_name"] = build_column_display_name(
        rec["src_type"], rec["src_table_norm"], rec["src_column_norm"]
    )
    rec["dst_column_name"] = build_column_display_name(
        rec["dst_type"], rec["dst_table_norm"], rec["dst_column_norm"]
    )
    rec["process_name"] = build_process_display_name(rec["job_cd"], rec["job_id"])
    return rec


def build_gca_dataset_entity(qn, name, conn_code, conn_type, schema_name, table_name):
    return {
        "typeName": "gca_dataset",
        "attributes": {
            "qualifiedName": qn,
            "name": name,
            "connection_code": conn_code,
            "connection_type": conn_type,
            "schema_name": schema_name,
            "table_name": table_name,
            "logical_path": qn.replace(QN_NAMESPACE, ""),
            "governance_source": "datalikegovernance",
        },
    }


def build_gca_column_entity(
    qn, name, column_desc, conn_code, conn_type,
    schema_name, table_name, job_id, job_cd, governance_id, dataset_qn
):
    return {
        "typeName": "gca_column",
        "attributes": {
            "qualifiedName": qn,
            "name": name,
            "column_name_desc": column_desc,
            "connection_code": conn_code,
            "connection_type": conn_type,
            "schema_name": schema_name,
            "table_name": table_name,
            "job_id": job_id,
            "job_cd": job_cd,
            "governance_id": governance_id,
            "governance_source": "datalikegovernance",
        },
        "relationshipAttributes": {
            "owner_dataset": {
                "typeName": "gca_dataset",
                "uniqueAttributes": {"qualifiedName": dataset_qn},
            }
        },
    }


def build_process_entity(rec):
    return {
        "typeName": "gca_process",
        "attributes": {
            "qualifiedName": rec["process_qn"],
            "name": rec["process_name"],
            "description": rec["sql_query"],
            "job_id": rec["job_id"],
            "job_cd": rec["job_cd"],
            "governance_id": rec["governance_id"],
            "action_type": rec["action_type"],
            "create_timestamp": rec["create_timestamp"],
            "source_connection_code": rec["src_conn_norm"],
            "destination_connection_code": rec["dst_conn_norm"],
            "mapping_level": "column",
            "sql_query": rec["sql_query"],
            "governance_source": "datalikegovernance",
        },
        "relationshipAttributes": {
            "inputs": [
                {
                    "typeName": "gca_column",
                    "uniqueAttributes": {"qualifiedName": rec["src_column_qn"]},
                }
            ],
            "outputs": [
                {
                    "typeName": "gca_column",
                    "uniqueAttributes": {"qualifiedName": rec["dst_column_qn"]},
                }
            ],
        },
    }


def atlas_bulk_push(atlas_url, entities):
    payload = {"entities": entities}

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=True) as f:
        json.dump(payload, f, ensure_ascii=False)
        f.flush()

        cmd = [
            "curl",
            "--negotiate",
            "-u", ":",
            "-H", "Content-Type: application/json",
            "-X", "POST",
            "--data", f"@{f.name}",
            f"{atlas_url}/api/atlas/v2/entity/bulk",
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)

    print("curl return code:", result.returncode)
    print("curl stdout:", result.stdout[:4000])
    print("curl stderr:", result.stderr[:4000])

    if result.returncode != 0:
        raise RuntimeError(f"Atlas bulk push failed: {result.stderr}")


def kinit_with_keytab(principal, keytab_path):
    cmd = ["kinit", "-kt", keytab_path, principal]
    result = subprocess.run(cmd, capture_output=True, text=True)

    print("kinit return code:", result.returncode)
    print("kinit stdout:", result.stdout[:1000])
    print("kinit stderr:", result.stderr[:1000])

    if result.returncode != 0:
        raise RuntimeError(f"kinit failed: {result.stderr}")


def push_test_batch_to_atlas():
    atlas_url = Variable.get("gca_atlas_url")
    kerberos_principal = Variable.get("gca_atlas_kerberos_principal")
    keytab_path = Variable.get("gca_atlas_keytab_path")
    last_id = int(Variable.get("gca_atlas_last_governance_id", default="0"))

    print(f"Atlas URL: {atlas_url}")
    print(f"Last processed governance_id: {last_id}")
    print(f"Test batch size: {BATCH_SIZE}")

    kinit_with_keytab(kerberos_principal, keytab_path)

    pg = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    sql = """
    SELECT
        g.governance_id,
        g.action_type,
        g.create_timestamp,
        g.source_column_name_desc,
        g.source_schema_name,
        g.source_table_name,
        g.destination_column_name,
        g.destination_column_name_desc,
        g.destination_schema_name,
        g.destination_table_name,
        g.job_id,
        g.source_column_name,
        j.job_cd,
        j.data_src_conn_cd,
        j.dest_conn_cd,
        j.sql_query
    FROM public.data_like_governance g
    LEFT JOIN public.data_transfer_job j
        ON g.job_id = j.job_id
    WHERE g.governance_id > %s
    ORDER BY g.governance_id
    LIMIT %s
    """

    records = pg.get_records(sql, parameters=(last_id, BATCH_SIZE))
    if not records:
        print("No rows to push.")
        return

    normalized_records = [normalize_record(row) for row in records]
    enriched_records = [enrich_with_qualified_names(rec) for rec in normalized_records]

    dataset_entities = {}
    column_entities = {}
    process_entities = {}

    for rec in enriched_records:
        dataset_entities[rec["src_dataset_qn"]] = build_gca_dataset_entity(
            rec["src_dataset_qn"], rec["src_dataset_name"], rec["src_conn_norm"],
            rec["src_type"], rec["src_schema_norm"], rec["src_table_norm"]
        )
        dataset_entities[rec["dst_dataset_qn"]] = build_gca_dataset_entity(
            rec["dst_dataset_qn"], rec["dst_dataset_name"], rec["dst_conn_norm"],
            rec["dst_type"], rec["dst_schema_norm"], rec["dst_table_norm"]
        )

        column_entities[rec["src_column_qn"]] = build_gca_column_entity(
            rec["src_column_qn"], rec["src_column_name"], rec["source_column_name_desc"],
            rec["src_conn_norm"], rec["src_type"], rec["src_schema_norm"], rec["src_table_norm"],
            rec["job_id"], rec["job_cd"], rec["governance_id"], rec["src_dataset_qn"]
        )
        column_entities[rec["dst_column_qn"]] = build_gca_column_entity(
            rec["dst_column_qn"], rec["dst_column_name"], rec["destination_column_name_desc"],
            rec["dst_conn_norm"], rec["dst_type"], rec["dst_schema_norm"], rec["dst_table_norm"],
            rec["job_id"], rec["job_cd"], rec["governance_id"], rec["dst_dataset_qn"]
        )

        process_entities[rec["process_qn"]] = build_process_entity(rec)

    print(f"Datasets to push: {len(dataset_entities)}")
    print(f"Columns to push: {len(column_entities)}")
    print(f"Processes to push: {len(process_entities)}")

    atlas_bulk_push(atlas_url, list(dataset_entities.values()))
    atlas_bulk_push(atlas_url, list(column_entities.values()))
    atlas_bulk_push(atlas_url, list(process_entities.values()))

    max_governance_id = max(r["governance_id"] for r in enriched_records)
    print(f"Test push finished successfully. Max governance_id in test batch: {max_governance_id}")


with DAG(
    dag_id=DAG_NAME,
    start_date=datetime(2024, 1, 1),
    schedule=None,
    catchup=False,
    tags=["GCA", "ATLAS", "GOVERNANCE"],
) as dag:

    push_test_batch = PythonOperator(
        task_id="push_test_batch_to_atlas",
        python_callable=push_test_batch_to_atlas,
    )

    push_test_batch
```

---

### 3) Run the DAG once

Trigger it manually.

### Expected success shape

You should see logs like:

* `kinit return code: 0`
* `Datasets to push: ...`
* `Columns to push: ...`
* `Processes to push: ...`
* `curl return code: 0`
* Atlas JSON response in stdout
* `Test push finished successfully...`

Atlas’s REST API documents both type-definition endpoints and the bulk entity endpoint we are using here. ([atlas.apache.org][1])

### Important

This step still does **not** update `gca_atlas_last_governance_id`.
We first confirm Atlas write works cleanly.

---

### 4) If it fails

Send me the exact error from:

* `kinit stderr`
* or `curl stdout/stderr`

Most likely failures will be:

* keytab permission problem
* wrong principal
* Atlas rejecting relationship attributes
* Atlas type mismatch

---

### 5) After it succeeds

Check Atlas UI and search for one of:

* `gca_dataset`
* `gca_column`
* `gca_process`
* or one exact `qualifiedName`

Then tell me:

* `Step 11 done - push succeeded`
* or paste the error

After that, I’ll give you the production step to:
**update the watermark only after successful push and switch from test batch to real batch processing**.

[1]: https://atlas.apache.org/api/v2/index.html?utm_source=chatgpt.com "Atlas REST API"
[2]: https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/variables.html?utm_source=chatgpt.com "Variables — Airflow 3.1.8 Documentation"
