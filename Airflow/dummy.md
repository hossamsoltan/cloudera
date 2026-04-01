Looks good.

From your log:

* batch fetched successfully
* `process_name` is being derived
* source classification is `rdbms`
* destination classification is `hive`
* max batch governance id is moving correctly

So we can continue.

## Step 6 — Build Atlas entity payloads in Python

Now we will build the actual JSON payload structures for Atlas, but still **without sending them yet**.

### Goal of this step

For each batch, create Python dictionaries for:

* `gca_dataset`
* `gca_column`
* `Process`

Then print:

* entity counts
* one sample dataset payload
* one sample column payload
* one sample process payload

This step is important because it validates the Atlas model before calling the Atlas API.

---

## Atlas payload strategy

For each governance row, we will create or reuse:

### Source side

* one `gca_dataset`
* one `gca_column`

### Destination side

* one `gca_dataset`
* one `gca_column`

### Transformation

* one `Process`

Since many rows may repeat the same dataset/column, we will deduplicate by `qualifiedName`.

---

## Replace your DAG code with this version

```python
from datetime import datetime
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook


DAG_NAME = "gca_governance_to_atlas"
POSTGRES_CONN_ID = "datalike_db"
BATCH_SIZE = 1000
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

    value = value.lower().strip()
    value = value.replace(" ", "_")
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
    dst_column_norm
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
        sql_query
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

        "src_conn_raw": safe_str(data_src_conn_cd),
        "dst_conn_raw": safe_str(dest_conn_cd),
        "src_conn_norm": src_conn_norm,
        "dst_conn_norm": dst_conn_norm,

        "src_type": src_type,
        "dst_type": dst_type,

        "src_schema_raw": safe_str(source_schema_name),
        "src_table_raw": safe_str(source_table_name),
        "src_column_raw": safe_str(source_column_name),

        "dst_schema_raw": safe_str(destination_schema_name),
        "dst_table_raw": safe_str(destination_table_name),
        "dst_column_raw": safe_str(destination_column_name),

        "src_schema_norm": src_schema_norm,
        "src_table_norm": src_table_norm,
        "src_column_norm": src_column_norm,

        "dst_schema_norm": dst_schema_norm,
        "dst_table_norm": dst_table_norm,
        "dst_column_norm": dst_column_norm
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
        rec["dst_conn_norm"], rec["dst_schema_norm"], rec["dst_table_norm"], rec["dst_column_norm"]
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
            "governance_source": "datalikegovernance"
        }
    }


def build_gca_column_entity(qn, name, column_desc, conn_code, conn_type, schema_name, table_name, job_id, job_cd, governance_id, dataset_qn):
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
            "governance_source": "datalikegovernance"
        },
        "relationshipAttributes": {
            "owner_dataset": {
                "typeName": "gca_dataset",
                "uniqueAttributes": {
                    "qualifiedName": dataset_qn
                }
            }
        }
    }


def build_process_entity(rec):
    return {
        "typeName": "Process",
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
            "governance_source": "datalikegovernance"
        },
        "relationshipAttributes": {
            "inputs": [
                {
                    "typeName": "gca_column",
                    "uniqueAttributes": {
                        "qualifiedName": rec["src_column_qn"]
                    }
                }
            ],
            "outputs": [
                {
                    "typeName": "gca_column",
                    "uniqueAttributes": {
                        "qualifiedName": rec["dst_column_qn"]
                    }
                }
            ]
        }
    }


def extract_build_payload_batch():
    last_id = int(Variable.get("gca_atlas_last_governance_id", default_var="0"))

    print(f"Last processed governance_id: {last_id}")
    print(f"Batch size: {BATCH_SIZE}")

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
    row_count = len(records)
    print(f"Fetched rows in batch: {row_count}")

    if row_count == 0:
        print("No new rows found.")
        return

    normalized_records = [normalize_record(row) for row in records]
    enriched_records = [enrich_with_qualified_names(rec) for rec in normalized_records]

    dataset_entities = {}
    column_entities = {}
    process_entities = {}

    for rec in enriched_records:
        src_dataset = build_gca_dataset_entity(
            qn=rec["src_dataset_qn"],
            name=rec["src_dataset_name"],
            conn_code=rec["src_conn_norm"],
            conn_type=rec["src_type"],
            schema_name=rec["src_schema_norm"],
            table_name=rec["src_table_norm"]
        )
        dataset_entities[rec["src_dataset_qn"]] = src_dataset

        dst_dataset = build_gca_dataset_entity(
            qn=rec["dst_dataset_qn"],
            name=rec["dst_dataset_name"],
            conn_code=rec["dst_conn_norm"],
            conn_type=rec["dst_type"],
            schema_name=rec["dst_schema_norm"],
            table_name=rec["dst_table_norm"]
        )
        dataset_entities[rec["dst_dataset_qn"]] = dst_dataset

        src_column = build_gca_column_entity(
            qn=rec["src_column_qn"],
            name=rec["src_column_name"],
            column_desc=rec["source_column_name_desc"],
            conn_code=rec["src_conn_norm"],
            conn_type=rec["src_type"],
            schema_name=rec["src_schema_norm"],
            table_name=rec["src_table_norm"],
            job_id=rec["job_id"],
            job_cd=rec["job_cd"],
            governance_id=rec["governance_id"],
            dataset_qn=rec["src_dataset_qn"]
        )
        column_entities[rec["src_column_qn"]] = src_column

        dst_column = build_gca_column_entity(
            qn=rec["dst_column_qn"],
            name=rec["dst_column_name"],
            column_desc=rec["destination_column_name_desc"],
            conn_code=rec["dst_conn_norm"],
            conn_type=rec["dst_type"],
            schema_name=rec["dst_schema_norm"],
            table_name=rec["dst_table_norm"],
            job_id=rec["job_id"],
            job_cd=rec["job_cd"],
            governance_id=rec["governance_id"],
            dataset_qn=rec["dst_dataset_qn"]
        )
        column_entities[rec["dst_column_qn"]] = dst_column

        process = build_process_entity(rec)
        process_entities[rec["process_qn"]] = process

    print(f"Unique dataset entities: {len(dataset_entities)}")
    print(f"Unique column entities: {len(column_entities)}")
    print(f"Unique process entities: {len(process_entities)}")

    sample_dataset = next(iter(dataset_entities.values()))
    sample_column = next(iter(column_entities.values()))
    sample_process = next(iter(process_entities.values()))

    print(f"Sample dataset payload: {sample_dataset}")
    print(f"Sample column payload: {sample_column}")
    print(f"Sample process payload: {sample_process}")

    max_governance_id = max(r["governance_id"] for r in enriched_records)
    print(f"Max governance_id in batch: {max_governance_id}")


with DAG(
    dag_id=DAG_NAME,
    start_date=datetime(2024, 1, 1),
    schedule=None,
    catchup=False,
    tags=["GCA", "ATLAS", "GOVERNANCE"]
) as dag:

    extract_build_payload = PythonOperator(
        task_id="extract_build_payload_batch",
        python_callable=extract_build_payload_batch
    )

    extract_build_payload
```

---

## What you should see in logs

Expected lines:

```text
Unique dataset entities: ...
Unique column entities: ...
Unique process entities: ...
Sample dataset payload: {...}
Sample column payload: {...}
Sample process payload: {...}
Max governance_id in batch: ...
```

---

## Very important note

This code only builds Python payloads.
It does **not** send anything to Atlas yet.

That is intentional.

We first verify:

* the JSON structure is stable
* deduplication works
* relationships are formed correctly

---

## One likely issue you may hit

Atlas standard `Process` may reject custom attributes like:

* `job_id`
* `job_cd`
* `sql_query`
* `mapping_level`

if those attributes do not exist in the Atlas type system.

That is normal.

At this stage, since we are only building Python dictionaries, it is fine.

In the next step, before sending to Atlas, we will decide one of these two professional options:

* extend Atlas `Process` type with custom attributes
* or create custom process type like `gca_process`

I will guide you carefully there.

---

## What I need from you

Run this step and reply with:

**Step 6 done**

Also tell me:

* did the payloads print correctly?
* any Python error?
* do you want to keep standard `Process`, or are you okay if next step we switch to custom `gca_process` for safer custom attributes?
