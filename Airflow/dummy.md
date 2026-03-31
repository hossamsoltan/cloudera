Good. Based on the new information, we should build it from the beginning like this:

**What we now know**

* Atlas is reachable and Kerberos auth works.
* Hive tables in Atlas use:

  * `typeName = hive_table`
  * `qualifiedName = schema.table@cm`
* Source tables should be treated as:

  * `typeName = rdbms_table`
* Spark source names are messy and should **not** be trusted.
* Your governance table `public.data_like_governance` contains all transitions:

  * source -> bronze
  * bronze -> silver
  * silver -> gold

So the correct design is:

**Governance table = lineage source of truth**
**Airflow = publisher**
**Atlas = target visualization/catalog**
**Spark lineage stays as extra technical lineage, not the main source**

---

# Final build plan

We will build this in 4 phases:

1. Read transitions from PostgreSQL
2. Build Atlas entity references correctly
3. Publish table-level lineage first
4. Add column lineage after table lineage works

---

# Phase 1 — Confirm the data model

## Step 1

Run this query to inspect distinct transitions:

```sql
select distinct
    source_schema_name,
    source_table_name,
    destination_schema_name,
    destination_table_name
from public.data_like_governance
order by 1,2,3,4;
```

What this gives you:

* every unique table-to-table lineage step

Each distinct row here will become **one Atlas Process**.

---

## Step 2

Count how many column mappings exist per transition:

```sql
select
    source_schema_name,
    source_table_name,
    destination_schema_name,
    destination_table_name,
    count(*) as column_count
from public.data_like_governance
group by
    source_schema_name,
    source_table_name,
    destination_schema_name,
    destination_table_name
order by 1,2,3,4;
```

What this gives you:

* how many source-column -> destination-column rows belong to each transition

That is what we will later use for column lineage.

---

## Step 3

Confirm whether one transition may belong to multiple job IDs:

```sql
select
    source_schema_name,
    source_table_name,
    destination_schema_name,
    destination_table_name,
    count(distinct job_id) as job_count
from public.data_like_governance
group by
    source_schema_name,
    source_table_name,
    destination_schema_name,
    destination_table_name
order by 1,2,3,4;
```

If `job_count` is mostly 1, life is easier.
If more than 1, we can still handle it, but the process naming must include the job.

---

# Phase 2 — Define the rules

## Step 4

Use these entity type rules:

### Source side

If schema does **not** start with `brz`, `slv`, or `gld`, then:

* `typeName = rdbms_table`

### Destination or internal medallion side

If schema starts with:

* `brz`
* `slv`
* `gld`

then:

* `typeName = hive_table`

---

## Step 5

Use these qualifiedName rules:

### Hive table

```python
def build_hive_qn(schema_name, table_name):
    return f"{schema_name}.{table_name}@cm"
```

### RDBMS source table

Since you do not want to depend on Spark’s weird source names, create your own clean qualifiedName:

```python
def build_rdbms_qn(schema_name, table_name):
    return f"{schema_name}.{table_name}@governance"
```

This is intentional.
It gives you stable business lineage names.

---

## Step 6

Use one process per transition.

Not one process per whole pipeline.

Example:

* `gca_employees.A -> brz_employees.A` = process 1
* `brz_employees.A -> slv_employees.A` = process 2
* `slv_employees.A -> gld_employees.A` = process 3

This is the correct Atlas design.

Use process qualifiedName like:

```python
def build_process_qn(source_schema, source_table, target_schema, target_table, job_id=None):
    base = f"{source_schema}.{source_table}__to__{target_schema}.{target_table}"
    if job_id is not None:
        return f"airflow://lineage/{base}/job_{job_id}"
    return f"airflow://lineage/{base}"
```

---

# Phase 3 — Build the Python modules

Create a folder under your Airflow DAGs area:

```bash
mkdir -p $AIRFLOW_HOME/dags/common
```

---

## Step 7 — PostgreSQL reader

Create:

```bash
vi $AIRFLOW_HOME/dags/common/governance_reader.py
```

Put this:

```python
import psycopg2


class GovernanceReader:
    def __init__(self, host, port, dbname, user, password):
        self.host = host
        self.port = port
        self.dbname = dbname
        self.user = user
        self.password = password

    def _connect(self):
        return psycopg2.connect(
            host=self.host,
            port=self.port,
            dbname=self.dbname,
            user=self.user,
            password=self.password
        )

    def get_transitions(self):
        conn = self._connect()
        cur = conn.cursor()

        cur.execute("""
            select distinct
                source_schema_name,
                source_table_name,
                destination_schema_name,
                destination_table_name,
                job_id
            from public.data_like_governance
            order by 1,2,3,4,5
        """)

        rows = cur.fetchall()
        cur.close()
        conn.close()

        result = []
        for r in rows:
            result.append({
                "source_schema_name": r[0],
                "source_table_name": r[1],
                "destination_schema_name": r[2],
                "destination_table_name": r[3],
                "job_id": r[4],
            })
        return result

    def get_transition_columns(self, source_schema, source_table, target_schema, target_table, job_id):
        conn = self._connect()
        cur = conn.cursor()

        cur.execute("""
            select
                source_column_name,
                source_column_name_desc,
                destination_column_name,
                destination_column_name_desc,
                action_type,
                create_timestamp
            from public.data_like_governance
            where source_schema_name = %s
              and source_table_name = %s
              and destination_schema_name = %s
              and destination_table_name = %s
              and job_id = %s
            order by source_column_name, destination_column_name
        """, (source_schema, source_table, target_schema, target_table, job_id))

        rows = cur.fetchall()
        cur.close()
        conn.close()

        result = []
        for r in rows:
            result.append({
                "source_column_name": r[0],
                "source_column_name_desc": r[1],
                "destination_column_name": r[2],
                "destination_column_name_desc": r[3],
                "action_type": r[4],
                "create_timestamp": str(r[5]),
            })
        return result
```

---

## Step 8 — Lineage model builder

Create:

```bash
vi $AIRFLOW_HOME/dags/common/lineage_builder.py
```

Put this:

```python
def is_hive_schema(schema_name: str) -> bool:
    schema_name = schema_name.lower()
    return schema_name.startswith("brz") or schema_name.startswith("slv") or schema_name.startswith("gld")


def build_entity_type(schema_name: str) -> str:
    return "hive_table" if is_hive_schema(schema_name) else "rdbms_table"


def build_qualified_name(schema_name: str, table_name: str) -> str:
    if is_hive_schema(schema_name):
        return f"{schema_name}.{table_name}@cm"
    return f"{schema_name}.{table_name}@governance"


def build_process_qualified_name(source_schema: str, source_table: str,
                                 target_schema: str, target_table: str,
                                 job_id) -> str:
    return (
        f"airflow://lineage/"
        f"{source_schema}.{source_table}__to__{target_schema}.{target_table}"
        f"/job_{job_id}"
    )


def build_transition_model(transition: dict, columns: list[dict]) -> dict:
    source_schema = transition["source_schema_name"]
    source_table = transition["source_table_name"]
    target_schema = transition["destination_schema_name"]
    target_table = transition["destination_table_name"]
    job_id = transition["job_id"]

    return {
        "job_id": job_id,
        "source_type": build_entity_type(source_schema),
        "target_type": build_entity_type(target_schema),
        "source_name": source_table,
        "target_name": target_table,
        "source_qn": build_qualified_name(source_schema, source_table),
        "target_qn": build_qualified_name(target_schema, target_table),
        "process_name": f"{source_schema}.{source_table}_to_{target_schema}.{target_table}",
        "process_qn": build_process_qualified_name(
            source_schema, source_table, target_schema, target_table, job_id
        ),
        "columns": columns,
    }
```

---

## Step 9 — Atlas publisher

Create:

```bash
vi $AIRFLOW_HOME/dags/common/atlas_publisher.py
```

Put this:

```python
import requests
from requests_kerberos import HTTPKerberosAuth, OPTIONAL


class AtlasPublisher:
    def __init__(self, atlas_url: str):
        self.atlas_url = atlas_url.rstrip("/")
        self.auth = HTTPKerberosAuth(mutual_authentication=OPTIONAL)

    def post_entity(self, payload: dict):
        response = requests.post(
            f"{self.atlas_url}/api/atlas/v2/entity",
            auth=self.auth,
            headers={"Content-Type": "application/json"},
            json=payload,
            verify=False,
            timeout=30,
        )
        print("Atlas status:", response.status_code)
        print(response.text)
        response.raise_for_status()
        return response.json()

    def publish_table_lineage(self, model: dict):
        source_payload = {
            "entity": {
                "typeName": model["source_type"],
                "attributes": {
                    "name": model["source_name"],
                    "qualifiedName": model["source_qn"],
                }
            }
        }

        target_payload = {
            "entity": {
                "typeName": model["target_type"],
                "attributes": {
                    "name": model["target_name"],
                    "qualifiedName": model["target_qn"],
                }
            }
        }

        process_payload = {
            "entity": {
                "typeName": "Process",
                "attributes": {
                    "name": model["process_name"],
                    "qualifiedName": model["process_qn"],
                    "inputs": [
                        {
                            "typeName": model["source_type"],
                            "uniqueAttributes": {
                                "qualifiedName": model["source_qn"]
                            }
                        }
                    ],
                    "outputs": [
                        {
                            "typeName": model["target_type"],
                            "uniqueAttributes": {
                                "qualifiedName": model["target_qn"]
                            }
                        }
                    ]
                }
            }
        }

        self.post_entity(source_payload)
        self.post_entity(target_payload)
        self.post_entity(process_payload)
```

---

# Phase 4 — Test outside Airflow first

## Step 10 — Create a standalone test

Create:

```bash
vi test_publish_one_transition.py
```

Put this:

```python
from common.governance_reader import GovernanceReader
from common.lineage_builder import build_transition_model
from common.atlas_publisher import AtlasPublisher

reader = GovernanceReader(
    host="POSTGRES_HOST",
    port=5432,
    dbname="POSTGRES_DB",
    user="POSTGRES_USER",
    password="POSTGRES_PASSWORD"
)

transitions = reader.get_transitions()

# Pick the first one for testing
transition = transitions[0]

columns = reader.get_transition_columns(
    transition["source_schema_name"],
    transition["source_table_name"],
    transition["destination_schema_name"],
    transition["destination_table_name"],
    transition["job_id"]
)

model = build_transition_model(transition, columns)
print(model)

publisher = AtlasPublisher("https://ATLAS_HOST:31443")
publisher.publish_table_lineage(model)
```

Run:

```bash
kinit your_user@REALM
python test_publish_one_transition.py
```

Then check Atlas UI.

Expected result:

* source entity exists
* target entity exists
* process exists
* lineage between them exists

---

# Phase 5 — Publish all transitions

## Step 11 — Create a bulk publisher test

Create:

```bash
vi test_publish_all_transitions.py
```

Put this:

```python
from common.governance_reader import GovernanceReader
from common.lineage_builder import build_transition_model
from common.atlas_publisher import AtlasPublisher

reader = GovernanceReader(
    host="POSTGRES_HOST",
    port=5432,
    dbname="POSTGRES_DB",
    user="POSTGRES_USER",
    password="POSTGRES_PASSWORD"
)

publisher = AtlasPublisher("https://ATLAS_HOST:31443")

transitions = reader.get_transitions()

for transition in transitions:
    print("Publishing transition:", transition)

    columns = reader.get_transition_columns(
        transition["source_schema_name"],
        transition["source_table_name"],
        transition["destination_schema_name"],
        transition["destination_table_name"],
        transition["job_id"]
    )

    model = build_transition_model(transition, columns)
    publisher.publish_table_lineage(model)
```

Run it only after the one-transition test works.

---

# Phase 6 — Integrate with Airflow

## Step 12 — Build one Airflow DAG

Create:

```bash
vi $AIRFLOW_HOME/dags/publish_governance_lineage.py
```

Put this:

```python
from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime

from common.governance_reader import GovernanceReader
from common.lineage_builder import build_transition_model
from common.atlas_publisher import AtlasPublisher


def publish_all_lineage():
    reader = GovernanceReader(
        host="POSTGRES_HOST",
        port=5432,
        dbname="POSTGRES_DB",
        user="POSTGRES_USER",
        password="POSTGRES_PASSWORD"
    )

    publisher = AtlasPublisher("https://ATLAS_HOST:31443")

    transitions = reader.get_transitions()

    for transition in transitions:
        columns = reader.get_transition_columns(
            transition["source_schema_name"],
            transition["source_table_name"],
            transition["destination_schema_name"],
            transition["destination_table_name"],
            transition["job_id"]
        )

        model = build_transition_model(transition, columns)
        publisher.publish_table_lineage(model)


with DAG(
    dag_id="publish_governance_lineage",
    start_date=datetime(2025, 1, 1),
    schedule=None,
    catchup=False
) as dag:

    publish_lineage_task = PythonOperator(
        task_id="publish_lineage_task",
        python_callable=publish_all_lineage
    )
```

Run it manually first.

---

# Phase 7 — What you should expect in Atlas

After this, Atlas should show a clean graph like:

* `rdbms_table` -> `hive_table(brz...)`
* `hive_table(brz...)` -> `hive_table(slv...)`
* `hive_table(slv...)` -> `hive_table(gld...)`

That already gives you the full table-level chain.

---

# Phase 8 — Then add column lineage

Do **not** start with columns now.

First confirm the full table chain works.

After that, we enhance the `Process` payload using the column mappings from your governance table.

That is phase 2.

---

# What you should do right now

Do exactly this order:

1. Run the distinct transition SQL.
2. Create `governance_reader.py`.
3. Create `lineage_builder.py`.
4. Create `atlas_publisher.py`.
5. Run `test_publish_one_transition.py`.
6. Check Atlas UI.
7. Run `test_publish_all_transitions.py`.
8. Only then create the Airflow DAG.

When the one-transition test succeeds, send me:

* one real source schema/table
* one real target schema/table
* whether Atlas showed the new process correctly

Then I’ll give you the **next phase: column lineage payload**.
