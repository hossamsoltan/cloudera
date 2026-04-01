Excellent.

## Step 5 — Build the final Atlas qualified names

Now we move to the most important transformation step before pushing to Atlas.

### Goal of this step

For each normalized record, generate:

* `src_dataset_qn`
* `src_column_qn`
* `dst_dataset_qn`
* `dst_column_qn`
* `process_qn`

and also clean display names for:

* source dataset
* destination dataset
* source column
* destination column
* process name

This step still does **not** push to Atlas.
It only prepares the exact identifiers we will later use in Atlas entities.

---

## Qualified name rules we will implement

### Dataset qualified name

#### Hive / RDBMS

```text
{conn}.{schema}.{table}@datalikegovernance
```

#### Excel

```text
excel.{conn}.default.logical_table@datalikegovernance
```

---

### Column qualified name

#### Hive / RDBMS

```text
{conn}.{schema}.{table}.{column}@datalikegovernance
```

#### Excel

```text
excel.{conn}.default.logical_table.{column}@datalikegovernance
```

---

### Process qualified name

```text
process.{job_id}.{src_conn}.{src_schema}.{src_table}.{src_col}.{dst_conn}.{dst_schema}.{dst_table}.{dst_col}@datalikegovernance
```

### Process display name

```text
job_cd
```

If `job_cd` is null, fallback:

```text
job_{job_id}
```

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


def enrich_with_qualified_names(rec):
    rec["src_dataset_qn"] = build_dataset_qn(
        rec["src_conn_norm"],
        rec["src_type"],
        rec["src_schema_norm"],
        rec["src_table_norm"]
    )

    rec["src_column_qn"] = build_column_qn(
        rec["src_conn_norm"],
        rec["src_type"],
        rec["src_schema_norm"],
        rec["src_table_norm"],
        rec["src_column_norm"]
    )

    rec["dst_dataset_qn"] = build_dataset_qn(
        rec["dst_conn_norm"],
        rec["dst_type"],
        rec["dst_schema_norm"],
        rec["dst_table_norm"]
    )

    rec["dst_column_qn"] = build_column_qn(
        rec["dst_conn_norm"],
        rec["dst_type"],
        rec["dst_schema_norm"],
        rec["dst_table_norm"],
        rec["dst_column_norm"]
    )

    rec["process_qn"] = build_process_qn(
        rec["job_id"],
        rec["src_conn_norm"],
        rec["src_schema_norm"],
        rec["src_table_norm"],
        rec["src_column_norm"],
        rec["dst_conn_norm"],
        rec["dst_schema_norm"],
        rec["dst_table_norm"],
        rec["dst_column_norm"]
    )

    rec["src_dataset_name"] = build_dataset_display_name(
        rec["src_type"],
        rec["src_conn_norm"],
        rec["src_schema_norm"],
        rec["src_table_norm"]
    )

    rec["dst_dataset_name"] = build_dataset_display_name(
        rec["dst_type"],
        rec["dst_conn_norm"],
        rec["dst_schema_norm"],
        rec["dst_table_norm"]
    )

    rec["src_column_name"] = build_column_display_name(
        rec["src_type"],
        rec["src_table_norm"],
        rec["src_column_norm"]
    )

    rec["dst_column_name"] = build_column_display_name(
        rec["dst_type"],
        rec["dst_table_norm"],
        rec["dst_column_norm"]
    )

    rec["process_name"] = build_process_display_name(
        rec["job_cd"],
        rec["job_id"]
    )

    return rec


def extract_normalize_enrich_batch():
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

    records = pg.get_records(sql, parameters=(last_id, BATCH_SIZE))

    row_count = len(records)
    print(f"Fetched rows in batch: {row_count}")

    if row_count == 0:
        print("No new rows found.")
        return

    normalized_records = [normalize_record(row) for row in records]
    enriched_records = [enrich_with_qualified_names(rec) for rec in normalized_records]

    preview_count = min(3, len(enriched_records))
    for i in range(preview_count):
        rec = enriched_records[i]
        preview = {
            "governance_id": rec["governance_id"],
            "job_id": rec["job_id"],
            "process_name": rec["process_name"],
            "src_type": rec["src_type"],
            "dst_type": rec["dst_type"],
            "src_dataset_qn": rec["src_dataset_qn"],
            "src_column_qn": rec["src_column_qn"],
            "dst_dataset_qn": rec["dst_dataset_qn"],
            "dst_column_qn": rec["dst_column_qn"],
            "process_qn": rec["process_qn"]
        }
        print(f"Enriched row {i + 1}: {preview}")

    max_governance_id = max(r["governance_id"] for r in enriched_records)
    print(f"Max governance_id in batch: {max_governance_id}")

    src_type_counts = {}
    dst_type_counts = {}

    for rec in enriched_records:
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

    extract_normalize_enrich = PythonOperator(
        task_id="extract_normalize_enrich_batch",
        python_callable=extract_normalize_enrich_batch
    )

    extract_normalize_enrich
```

---

## What to expect in logs

You should now see log output like:

```text
Enriched row 1: {
  'governance_id': ...,
  'job_id': ...,
  'process_name': 'L_SPRK_...',
  'src_type': 'hive',
  'dst_type': 'hive',
  'src_dataset_qn': 'hive.schema.table@datalikegovernance',
  'src_column_qn': 'hive.schema.table.column@datalikegovernance',
  'dst_dataset_qn': 'crm.schema.table@datalikegovernance',
  'dst_column_qn': 'crm.schema.table.column@datalikegovernance',
  'process_qn': 'process....@datalikegovernance'
}
```

For Excel-like rows, you should see:

```text
excel.exel_data.default.logical_table@datalikegovernance
```

---

## What this step validates

This confirms that:

* naming rules are correct
* `_UAT` removal works
* Excel fallback naming works
* process uniqueness is deterministic
* all later Atlas entities will be built on stable IDs

---

## After this step

Reply with:

**Step 5 done**

and tell me if:

* the qualified names look correct
* Excel rows are getting `excel.{conn}.default.logical_table...`
* any name looks wrong

Then I will give you:

## Step 6 — Build Atlas entity JSON payloads

That step will create the actual JSON structures for:

* `gca_dataset`
* `gca_column`
* `Process`

before we connect to Atlas.
