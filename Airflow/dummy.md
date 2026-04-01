Perfect. We continue.

## Step 4 — Normalize and classify each governance row

Now we build the first real transformation layer before Atlas.

### Goal of this step

For every extracted row, we will:

* normalize `data_src_conn_cd` and `dest_conn_cd`
* remove `_UAT` if it exists
* lowercase the values
* classify source type:

  * `excel`
  * `hive`
  * `rdbms`
* classify destination type the same way
* prepare clean normalized records for the next Atlas-building step

Still no Atlas push yet.

---

## What this step will produce

For each raw row, we will derive fields like:

* `src_conn_norm`
* `dst_conn_norm`
* `src_type`
* `dst_type`
* `src_schema_norm`
* `src_table_norm`
* `src_column_norm`
* `dst_schema_norm`
* `dst_table_norm`
* `dst_column_norm`

This is important because all later qualified names will depend on these normalized values.

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

    # Excel-like case: no schema and no table
    if not schema_name and not table_name:
        return "excel"

    if "hive" in conn:
        return "hive"

    return "rdbms"


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

    normalized = {
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

    return normalized


def extract_and_normalize_batch():
    last_id = int(
        Variable.get(
            "gca_atlas_last_governance_id",
            default_var="0"
        )
    )

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

    records = pg.get_records(
        sql,
        parameters=(last_id, BATCH_SIZE)
    )

    row_count = len(records)
    print(f"Fetched rows in batch: {row_count}")

    if row_count == 0:
        print("No new rows found.")
        return

    normalized_records = [normalize_record(row) for row in records]

    preview_count = min(3, len(normalized_records))
    for i in range(preview_count):
        print(f"Normalized row {i + 1}: {normalized_records[i]}")

    max_governance_id = max(r["governance_id"] for r in normalized_records)
    print(f"Max governance_id in batch: {max_governance_id}")

    src_type_counts = {}
    dst_type_counts = {}

    for rec in normalized_records:
        src_type_counts[rec["src_type"]] = src_type_counts.get(rec["src_type"], 0) + 1
        dst_type_counts[rec["dst_type"]] = dst_type_counts.get(rec["dst_type"], 0) + 1

    print(f"Source type counts: {src_type_counts}")
    print(f"Destination type counts: {dst_type_counts}")


with DAG(
    dag_id=DAG_NAME,
    start_date=datetime(2024, 1, 1),
    schedule=None,
    catchup=False,
    tags=["GCA", "ATLAS", "GOVERNANCE"]
) as dag:

    extract_normalize_batch = PythonOperator(
        task_id="extract_and_normalize_batch",
        python_callable=extract_and_normalize_batch
    )

    extract_normalize_batch
```

---

## What this code does

### Connection normalization

Examples:

* `HIVE_UAT` → `hive`
* `CRM_UAT` → `crm`
* `mostaql_UAT` → `mostaql`
* `exel_data` → `exel_data`

### Type classification

* no schema and no table → `excel`
* connection contains `hive` → `hive`
* otherwise → `rdbms`

### Fallbacks

If some names are missing:

* schema → `default`
* table → `logical_table`
* column → `unknown_column`

This matches the design we agreed on.

---

## Run the DAG again

After trigger, expected logs will include things like:

```text
Last processed governance_id: 0
Batch size: 1000
Fetched rows in batch: 1000
Normalized row 1: {...}
Normalized row 2: {...}
Normalized row 3: {...}
Max governance_id in batch: ...
Source type counts: {'hive': 700, 'rdbms': 250, 'excel': 50}
Destination type counts: {'hive': 1000}
```

The numbers will depend on your actual data.

---

## What I need from you after this step

Reply with:

* **Step 4 done**
* and tell me whether the classification looks reasonable:

  * are Excel rows detected correctly?
  * are Hive rows detected correctly?
  * any obvious wrong classification?

After that I will move to:

## Step 5 — Build final Atlas qualified names

In that step we will generate:

* `gca_dataset` qualified names
* `gca_column` qualified names
* `Process` qualified names

That is the key step before Atlas payload creation.
