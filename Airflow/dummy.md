Great. Foundation is working.

## Step 3 — Add batch extraction logic

Now we move from just counting rows to actually reading the **next batch** from PostgreSQL.

### Goal of this step

Update the DAG so it:

* reads `gca_atlas_last_governance_id`
* fetches the next batch from the join between:

  * `public.data_like_governance`
  * `public.data_transfer_job`
* prints:

  * number of fetched rows
  * first few sample records
  * max `governance_id` in the batch

Still no Atlas push yet.

---

## 1) Decide batch size

For now, use:

```python
BATCH_SIZE = 1000
```

Since your pending rows are **58,064**, this means about **59 batches**, which is very manageable.

---

## 2) Replace your DAG code with this version

Use this full file:

```python
from datetime import datetime
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook


DAG_NAME = "gca_governance_to_atlas"
POSTGRES_CONN_ID = "YOUR_POSTGRES_CONNECTION"
BATCH_SIZE = 1000


def extract_governance_batch():
    # Read watermark
    last_id = int(
        Variable.get(
            "gca_atlas_last_governance_id",
            default_var="0"
        )
    )

    print(f"Last processed governance_id: {last_id}")
    print(f"Batch size: {BATCH_SIZE}")

    # Connect to PostgreSQL
    pg = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    # Main batch extraction query
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

    # Print first 3 rows as sample
    preview_count = min(3, row_count)
    for i in range(preview_count):
        row = records[i]
        print(f"Sample row {i + 1}: {row}")

    # Get max governance_id in this batch
    max_governance_id = max(row[0] for row in records)
    print(f"Max governance_id in batch: {max_governance_id}")


with DAG(
    dag_id=DAG_NAME,
    start_date=datetime(2024, 1, 1),
    schedule=None,
    catchup=False,
    tags=["GCA", "ATLAS", "GOVERNANCE"]
) as dag:

    extract_batch = PythonOperator(
        task_id="extract_governance_batch",
        python_callable=extract_governance_batch
    )

    extract_batch
```

---

## 3) Important

Replace this line:

```python
POSTGRES_CONN_ID = "YOUR_POSTGRES_CONNECTION"
```

with your real Airflow PostgreSQL connection id.

---

## 4) Trigger the DAG

Run it again from Airflow UI.

Expected log shape:

```text
Last processed governance_id: 0
Batch size: 1000
Fetched rows in batch: 1000
Sample row 1: (...)
Sample row 2: (...)
Sample row 3: (...)
Max governance_id in batch: 1000
```

The exact max id may differ, because your IDs may not be perfectly sequential.

---

## 5) What to check carefully

I want you to look at the sample rows in logs and confirm these fields are appearing correctly:

* `governance_id`
* `job_id`
* `job_cd`
* `data_src_conn_cd`
* `dest_conn_cd`
* `source_schema_name`
* `source_table_name`
* `source_column_name`
* `destination_schema_name`
* `destination_table_name`
* `destination_column_name`
* `sql_query`

Especially confirm:

* `dest_conn_cd` is really coming correctly
* Excel-like rows show null/empty schema/table as expected
* `job_cd` is populated for the matched rows

---

## 6) Reply with this

Send me:

* **Step 3 done**
* one sample row from the log, with sensitive SQL text shortened if needed

Then I will give you **Step 4: normalize and classify each row into hive / rdbms / excel**, which is the first real mapping step before Atlas.
