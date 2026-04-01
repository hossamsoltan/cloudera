Perfect. Now we move to the **real first implementation step**.

This step will only create the **DAG skeleton + connection test + reading the watermark**.
No Atlas yet. No transformation yet. We build the foundation first (professional approach).

---

# Step 2 — Create the first Airflow DAG skeleton

## Goal of this step

Create a DAG that:

* reads the Airflow Variable `gca_atlas_last_governance_id`
* connects to PostgreSQL using your existing Airflow connection
* prints how many rows are pending
* does nothing else yet

This validates:

* Variable works
* PostgreSQL connection works
* DAG structure is correct

---

# 1) DAG file location

Go to your Airflow DAG folder (example):

```
/opt/airflow/dags/
```

Create file:

```
gca_governance_to_atlas.py
```

---

# 2) First DAG skeleton (clean production structure)

Create this file:

```python
from datetime import datetime
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.models import Variable
from airflow.providers.postgres.hooks.postgres import PostgresHook


DAG_NAME = "gca_governance_to_atlas"


def check_governance_source():

    # Read watermark
    last_id = int(
        Variable.get(
            "gca_atlas_last_governance_id",
            default_var="0"
        )
    )

    print(f"Last processed governance_id: {last_id}")

    # Connect to PostgreSQL
    pg = PostgresHook(
        postgres_conn_id="YOUR_POSTGRES_CONNECTION"
    )

    # Check pending rows
    sql = """
    SELECT count(*)
    FROM public.data_like_governance
    WHERE governance_id > %s
    """

    result = pg.get_first(
        sql,
        parameters=(last_id,)
    )

    print(f"Pending rows: {result[0]}")


with DAG(

    dag_id=DAG_NAME,

    start_date=datetime(2024,1,1),

    schedule=None,

    catchup=False,

    tags=["GCA","ATLAS","GOVERNANCE"]

) as dag:


    check_source = PythonOperator(

        task_id="check_governance_source",

        python_callable=check_governance_source

    )


    check_source
```

---

# 3) Replace connection name

Replace:

```python
postgres_conn_id="YOUR_POSTGRES_CONNECTION"
```

with your real Airflow connection name.

Example:

```
postgres_conn_id="postgres_datalike"
```

Use exactly the connection you already created.

---

# 4) Deploy DAG

After saving file:

Either wait scheduler refresh OR run:

```bash
airflow dags list
```

You should see:

```
gca_governance_to_atlas
```

---

# 5) Test DAG

Open Airflow UI:

```
DAGs → gca_governance_to_atlas
```

Click:

```
Trigger DAG
```

Then open logs.

Expected output:

Example:

```
Last processed governance_id: 0
Pending rows: 298734
```

---

# 6) What we are validating now

We are confirming:

✔ Variable works
✔ PostgreSQL hook works
✔ Query works
✔ DAG execution works
✔ Logging works

This prevents debugging later when complexity increases.

---

# 7) Possible errors (normal)

If error appears like:

### Connection error

Fix connection name.

### Module error:

```
No module airflow.providers.postgres
```

Tell me.

### Permission error:

Tell me.

---

# When done tell me:

Reply with:

**Step 2 done**

and copy the output like:

```
Last processed governance_id: X
Pending rows: X
```

Then we move to:

**Step 3 → Batch extraction logic (real pipeline begins)**
