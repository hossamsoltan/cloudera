Good point. Let's reset cleanly and **standardize all names and functions** so you don't hit mismatches again.
We will rebuild this **from zero with consistent naming** and correct Atlas requirements.

I will keep **exact function names**, **exact model fields**, and **correct Atlas attributes**.

---

# Final clean structure (no surprises later)

We will have only **3 files**:

```
common/
│
├── lineage_builder.py
├── atlas_publisher.py
└── test_publish_one_transition.py
```

---

# STEP 1 — lineage_builder.py (clean + stable)

This builds the model correctly.

Use EXACTLY this:

```python
def is_hive_schema(schema_name):

    return schema_name.startswith(("brz","slv","gld"))


def build_entity_type(schema_name):

    if is_hive_schema(schema_name):

        return "hive_table"

    return "rdbms_table"


def build_qualified_name(schema_name,table_name):

    if is_hive_schema(schema_name):

        return f"{schema_name}.{table_name}@cm"

    return f"{schema_name}.{table_name}@governance"


def build_process_qualified_name(
    source_schema,
    source_table,
    target_schema,
    target_table,
    job_id
):

    return f"airflow://job/{job_id}/{source_schema}.{source_table}_to_{target_schema}.{target_table}"


def build_transition_model(transition,columns):

    source_schema = transition["source_schema_name"]
    source_table  = transition["source_table_name"]

    target_schema = transition["destination_schema_name"]
    target_table  = transition["destination_table_name"]

    job_id = transition["job_id"]

    model = {

        "job_id":job_id,

        "source_type":build_entity_type(source_schema),

        "target_type":build_entity_type(target_schema),

        "source_name":source_table,

        "target_name":target_table,

        "source_qn":build_qualified_name(
            source_schema,
            source_table
        ),

        "target_qn":build_qualified_name(
            target_schema,
            target_table
        ),

        "process_name":
        f"{source_schema}.{source_table}_to_{target_schema}.{target_table}",

        "process_qn":
        build_process_qualified_name(
            source_schema,
            source_table,
            target_schema,
            target_table,
            job_id
        ),

        "columns":columns
    }

    return model
```

---

# STEP 2 — atlas_publisher.py (FINAL stable version)

This version fixes:

* rdbms_db requirement
* consistent attribute names
* process creation
* no missing fields

Use EXACTLY:

```python
import subprocess
import json
import tempfile


class AtlasPublisher:


    def __init__(self,atlas_url):

        self.atlas_url = atlas_url.rstrip("/")


    def post_entity(self,payload):

        subprocess.run(["klist"])

        with tempfile.NamedTemporaryFile(
            mode="w",
            delete=False
        ) as f:

            json.dump(payload,f)

            file_name=f.name


        cmd=[

            "curl",

            "--negotiate",

            "-u",":",

            "-k",

            "-H","Content-Type: application/json",

            "-X","POST",

            f"{self.atlas_url}/api/atlas/v2/entity",

            "-d",f"@{file_name}"

        ]


        result=subprocess.run(
            cmd,
            capture_output=True,
            text=True
        )

        print(result.stdout)

        if result.returncode !=0:

            raise Exception(result.stderr)



    def publish_table_lineage(self,model):


        ###################
        # 1 create rdbms_db
        ###################

        rdbms_db_payload={

            "entity":{

                "typeName":"rdbms_db",

                "attributes":{

                    "name":"governance_db",

                    "qualifiedName":
                    "governance_db@governance"
                }
            }
        }


        ###################
        # 2 source table
        ###################

        source_payload={

            "entity":{

                "typeName":model["source_type"],

                "attributes":{

                    "name":model["source_name"],

                    "qualifiedName":
                    model["source_qn"],

                    "db":{

                        "typeName":"rdbms_db",

                        "uniqueAttributes":{

                            "qualifiedName":
                            "governance_db@governance"
                        }
                    }
                }
            }
        }


        ###################
        # 3 target table
        ###################

        target_payload={

            "entity":{

                "typeName":model["target_type"],

                "attributes":{

                    "name":model["target_name"],

                    "qualifiedName":
                    model["target_qn"]
                }
            }
        }



        ###################
        # 4 process
        ###################

        process_payload={

            "entity":{

                "typeName":"Process",

                "attributes":{

                    "name":
                    model["process_name"],

                    "qualifiedName":
                    model["process_qn"],


                    "inputs":[

                        {

                            "typeName":
                            model["source_type"],

                            "uniqueAttributes":{

                                "qualifiedName":
                                model["source_qn"]
                            }
                        }
                    ],


                    "outputs":[

                        {

                            "typeName":
                            model["target_type"],

                            "uniqueAttributes":{

                                "qualifiedName":
                                model["target_qn"]
                            }
                        }
                    ]
                }
            }
        }



        print("Publishing rdbms_db")

        self.post_entity(rdbms_db_payload)


        print("Publishing source")

        self.post_entity(source_payload)


        print("Publishing target")

        self.post_entity(target_payload)


        print("Publishing process")

        self.post_entity(process_payload)
```

---

# STEP 3 — test_publish_one_transition.py

Use this stable test:

```python
from lineage_builder import build_transition_model
from atlas_publisher import AtlasPublisher


transition={

"job_id":382,

"source_schema_name":"dbo",

"source_table_name":"countries_lookup",

"destination_schema_name":"brz_etimad",

"destination_table_name":"countries_lookup"

}



columns=[{

"source_column_name":"country_code",

"destination_column_name":"country_code"

}]



model=build_transition_model(
transition,
columns
)



print(model)



publisher=AtlasPublisher(
"https://<atlas-host>:31443"
)



publisher.publish_table_lineage(model)
```

---

# Why this version will not break again

We standardized:

Model fields:

```
source_type
target_type
source_name
target_name
source_qn
target_qn
process_name
process_qn
columns
```

Functions:

```
build_entity_type
build_qualified_name
build_transition_model
publish_table_lineage
```

Atlas requirements handled:

```
rdbms_db ✔
rdbms_table db reference ✔
Process ✔
```

Naming consistency:

```
schema.table@system
```

---

# What should happen now

When you run:

```
python3 test_publish_one_transition.py
```

Atlas should create:

```
rdbms_db

rdbms_table

hive_table

Process
```

Atlas UI should show:

```
countries_lookup (RDBMS)
      ↓
countries_lookup (Bronze Hive)
```

---

# After this works we move to the real target:

Publishing:

```
Source → Bronze → Silver → Gold
WITH COLUMN LINEAGE
```

This is the real goal.

---

# Next step after you confirm success

Next we add:

**columnMapping attribute**

This gives:

FULL column lineage in Atlas UI.

That is the critical step for your governance table.

Just confirm this run succeeds.
