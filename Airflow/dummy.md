You're right. I skipped the PostgreSQL connection in the last full example and mixed partial snippets across replies.

Let's reset with one **complete, consistent working set of files** using the names we already established and keeping them stable:

* `governance_reader.py`
* `lineage_builder.py`
* `atlas_publisher.py`
* `test_publish_one_transition.py`
* `publish_all_transitions.py`

This version includes:

* PostgreSQL connection
* governance table reading
* Atlas publishing through `curl --negotiate`
* `rdbms_db` creation
* `rdbms_table` creation with required `db`
* `hive_table` target references
* one process per transition
* stable function and field names

---

# 1) Folder structure

Use this exact structure:

```text
/data01/airflow310/dags/common/
├── governance_reader.py
├── lineage_builder.py
├── atlas_publisher.py
├── test_publish_one_transition.py
└── publish_all_transitions.py
```

---

# 2) governance_reader.py

This file reads from PostgreSQL table `public.data_like_governance`.

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
            order by
                source_schema_name,
                source_table_name,
                destination_schema_name,
                destination_table_name,
                job_id
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
                "job_id": r[4]
            })

        return result

    def get_transition_columns(
        self,
        source_schema_name,
        source_table_name,
        destination_schema_name,
        destination_table_name,
        job_id
    ):
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
        """, (
            source_schema_name,
            source_table_name,
            destination_schema_name,
            destination_table_name,
            job_id
        ))

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
                "create_timestamp": str(r[5])
            })

        return result
```

---

# 3) lineage_builder.py

This file contains all stable naming rules and model-building functions.

```python
def is_hive_schema(schema_name):
    schema_name = schema_name.lower()
    return schema_name.startswith(("brz", "slv", "gld"))


def build_entity_type(schema_name):
    if is_hive_schema(schema_name):
        return "hive_table"
    return "rdbms_table"


def build_qualified_name(schema_name, table_name):
    if is_hive_schema(schema_name):
        return f"{schema_name}.{table_name}@cm"
    return f"{schema_name}.{table_name}@governance"


def build_process_qualified_name(
    source_schema_name,
    source_table_name,
    destination_schema_name,
    destination_table_name,
    job_id
):
    return (
        f"airflow://lineage/"
        f"{source_schema_name}.{source_table_name}"
        f"__to__"
        f"{destination_schema_name}.{destination_table_name}"
        f"/job_{job_id}"
    )


def build_transition_model(transition, columns):
    source_schema_name = transition["source_schema_name"]
    source_table_name = transition["source_table_name"]
    destination_schema_name = transition["destination_schema_name"]
    destination_table_name = transition["destination_table_name"]
    job_id = transition["job_id"]

    model = {
        "job_id": job_id,

        "source_schema_name": source_schema_name,
        "source_table_name": source_table_name,
        "destination_schema_name": destination_schema_name,
        "destination_table_name": destination_table_name,

        "source_type": build_entity_type(source_schema_name),
        "target_type": build_entity_type(destination_schema_name),

        "source_name": source_table_name,
        "target_name": destination_table_name,

        "source_qn": build_qualified_name(source_schema_name, source_table_name),
        "target_qn": build_qualified_name(destination_schema_name, destination_table_name),

        "process_name": (
            f"{source_schema_name}.{source_table_name}"
            f"_to_"
            f"{destination_schema_name}.{destination_table_name}"
        ),

        "process_qn": build_process_qualified_name(
            source_schema_name,
            source_table_name,
            destination_schema_name,
            destination_table_name,
            job_id
        ),

        "columns": columns
    }

    return model
```

---

# 4) atlas_publisher.py

This is the final consistent publisher using `curl --negotiate` and creating:

* `rdbms_db`
* source `rdbms_table`
* target entity
* `Process`

```python
import json
import subprocess
import tempfile


class AtlasPublisher:
    def __init__(self, atlas_url):
        self.atlas_url = atlas_url.rstrip("/")

    def post_entity(self, payload):
        subprocess.run(["klist"])

        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            json.dump(payload, f)
            file_name = f.name

        cmd = [
            "curl",
            "--negotiate",
            "-u", ":",
            "-k",
            "-H", "Content-Type: application/json",
            "-X", "POST",
            f"{self.atlas_url}/api/atlas/v2/entity",
            "-d", f"@{file_name}"
        ]

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True
        )

        print("STDOUT:")
        print(result.stdout)
        print("STDERR:")
        print(result.stderr)

        if result.returncode != 0:
            raise Exception(result.stderr)

    def publish_table_lineage(self, model):
        rdbms_db_payload = {
            "entity": {
                "typeName": "rdbms_db",
                "attributes": {
                    "name": "governance_db",
                    "qualifiedName": "governance_db@governance"
                }
            }
        }

        if model["source_type"] == "rdbms_table":
            source_payload = {
                "entity": {
                    "typeName": "rdbms_table",
                    "attributes": {
                        "name": model["source_name"],
                        "qualifiedName": model["source_qn"],
                        "db": {
                            "typeName": "rdbms_db",
                            "uniqueAttributes": {
                                "qualifiedName": "governance_db@governance"
                            }
                        }
                    }
                }
            }
        else:
            source_payload = {
                "entity": {
                    "typeName": model["source_type"],
                    "attributes": {
                        "name": model["source_name"],
                        "qualifiedName": model["source_qn"]
                    }
                }
            }

        if model["target_type"] == "rdbms_table":
            target_payload = {
                "entity": {
                    "typeName": "rdbms_table",
                    "attributes": {
                        "name": model["target_name"],
                        "qualifiedName": model["target_qn"],
                        "db": {
                            "typeName": "rdbms_db",
                            "uniqueAttributes": {
                                "qualifiedName": "governance_db@governance"
                            }
                        }
                    }
                }
            }
        else:
            target_payload = {
                "entity": {
                    "typeName": model["target_type"],
                    "attributes": {
                        "name": model["target_name"],
                        "qualifiedName": model["target_qn"]
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

        if model["source_type"] == "rdbms_table" or model["target_type"] == "rdbms_table":
            print("Publishing rdbms_db entity...")
            self.post_entity(rdbms_db_payload)

        print("Publishing source entity...")
        self.post_entity(source_payload)

        print("Publishing target entity...")
        self.post_entity(target_payload)

        print("Publishing process entity...")
        self.post_entity(process_payload)
```

---

# 5) test_publish_one_transition.py

This tests one transition from PostgreSQL.

Update the connection values before running.

```python
from governance_reader import GovernanceReader
from lineage_builder import build_transition_model
from atlas_publisher import AtlasPublisher


POSTGRES_HOST = "YOUR_PG_HOST"
POSTGRES_PORT = 5432
POSTGRES_DBNAME = "YOUR_PG_DB"
POSTGRES_USER = "YOUR_PG_USER"
POSTGRES_PASSWORD = "YOUR_PG_PASSWORD"

ATLAS_URL = "https://YOUR_ATLAS_HOST:31443"


reader = GovernanceReader(
    host=POSTGRES_HOST,
    port=POSTGRES_PORT,
    dbname=POSTGRES_DBNAME,
    user=POSTGRES_USER,
    password=POSTGRES_PASSWORD
)

transitions = reader.get_transitions()

if not transitions:
    raise Exception("No transitions found in public.data_like_governance")

transition = transitions[0]

columns = reader.get_transition_columns(
    transition["source_schema_name"],
    transition["source_table_name"],
    transition["destination_schema_name"],
    transition["destination_table_name"],
    transition["job_id"]
)

model = build_transition_model(transition, columns)

print("MODEL:")
print(model)

publisher = AtlasPublisher(ATLAS_URL)
publisher.publish_table_lineage(model)
```

---

# 6) publish_all_transitions.py

This publishes all transitions from the governance table.

```python
from governance_reader import GovernanceReader
from lineage_builder import build_transition_model
from atlas_publisher import AtlasPublisher


POSTGRES_HOST = "YOUR_PG_HOST"
POSTGRES_PORT = 5432
POSTGRES_DBNAME = "YOUR_PG_DB"
POSTGRES_USER = "YOUR_PG_USER"
POSTGRES_PASSWORD = "YOUR_PG_PASSWORD"

ATLAS_URL = "https://YOUR_ATLAS_HOST:31443"


reader = GovernanceReader(
    host=POSTGRES_HOST,
    port=POSTGRES_PORT,
    dbname=POSTGRES_DBNAME,
    user=POSTGRES_USER,
    password=POSTGRES_PASSWORD
)

publisher = AtlasPublisher(ATLAS_URL)

transitions = reader.get_transitions()

print(f"Found {len(transitions)} transitions")

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
    print("MODEL:", model)

    publisher.publish_table_lineage(model)
```

---

# 7) How to run

Go to the folder:

```bash
cd /data01/airflow310/dags/common
```

Make sure Kerberos ticket exists:

```bash
klist
```

If needed:

```bash
kinit your_user@REALM
```

Run one transition first:

```bash
python3 test_publish_one_transition.py
```

After it works:

```bash
python3 publish_all_transitions.py
```

---

# 8) What this version solves

This version correctly handles all the things we discovered:

* PostgreSQL governance table is the source of truth
* source schemas not starting with `brz/slv/gld` become `rdbms_table`
* medallion schemas become `hive_table`
* Hive qualified names use:

  * `schema.table@cm`
* RDBMS qualified names use:

  * `schema.table@governance`
* `rdbms_table` requires `db`
* `rdbms_db` is created first
* Atlas publishing uses `curl --negotiate`
* no `requests_kerberos` needed

---

# 9) What to do after table lineage works

Once `test_publish_one_transition.py` works and Atlas shows the transition correctly, the next step is to add **column lineage** from `model["columns"]`.

That part should be done only after the table-level publishing is confirmed.

---

# 10) One important note

This code assumes your governance table columns are exactly these names:

* `source_schema_name`
* `source_table_name`
* `destination_schema_name`
* `destination_table_name`
* `job_id`
* `source_column_name`
* `source_column_name_desc`
* `destination_column_name`
* `destination_column_name_desc`
* `action_type`
* `create_timestamp`

If any one of these differs, tell me the exact column name and I’ll adjust the files consistently.

Start with `test_publish_one_transition.py`. Once it runs, send me the output or the first Atlas response and we’ll move to column lineage.
