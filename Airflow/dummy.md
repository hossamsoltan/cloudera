Good, now we are very close. The errors you see are **Atlas schema validation errors**, not Python errors. That means the code structure is now correct, but we must fix **mandatory Atlas attributes**.

Let's fix this properly and **stabilize the final version**.

---

# What Atlas is telling you

From your screenshot:

## Error 1

```
rdbms_db_instance: mandatory attribute value missing
```

This means `rdbms_db` **must include `rdbms_db_instance`**

Atlas model requires hierarchy:

```
rdbms_db_instance → rdbms_db → rdbms_table
```

You created only:

```
rdbms_db → rdbms_table
```

So Atlas rejected it.

---

## Error 2

```
Referenced entity rdbms_db not found
```

Because the db creation failed, the table cannot reference it.

---

## Error 3

```
Referenced entity rdbms_table not found
```

Cascade failure.

---

# Correct Atlas hierarchy (this is the missing piece)

We must create:

```
rdbms_db_instance
        ↓
rdbms_db
        ↓
rdbms_table
```

This is mandatory in Atlas.

---

# Correct solution

We must add:

### 1 rdbms_db_instance

### 2 rdbms_db referencing instance

### 3 rdbms_table referencing db

---

# FIX atlas_publisher.py (FINAL CORRECT VERSION)

Replace your file with this:

```python
import json
import subprocess
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

        ##################################
        # 1 DB INSTANCE (MANDATORY)
        ##################################

        instance_payload={

            "entity":{

                "typeName":"rdbms_db_instance",

                "attributes":{

                    "name":"governance_instance",

                    "qualifiedName":
                    "governance_instance@governance"
                }
            }
        }


        ##################################
        # 2 DB
        ##################################

        db_payload={

            "entity":{

                "typeName":"rdbms_db",

                "attributes":{

                    "name":"governance_db",

                    "qualifiedName":
                    "governance_db@governance",

                    "instance":{

                        "typeName":"rdbms_db_instance",

                        "uniqueAttributes":{

                            "qualifiedName":
                            "governance_instance@governance"
                        }
                    }
                }
            }
        }



        ##################################
        # 3 SOURCE TABLE
        ##################################

        if model["source_type"]=="rdbms_table":

            source_payload={

                "entity":{

                    "typeName":"rdbms_table",

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

        else:

            source_payload={

                "entity":{

                    "typeName":model["source_type"],

                    "attributes":{

                        "name":model["source_name"],

                        "qualifiedName":
                        model["source_qn"]
                    }
                }
            }



        ##################################
        # 4 TARGET TABLE
        ##################################

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



        ##################################
        # 5 PROCESS
        ##################################

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



        ##################################
        # PUBLISH ORDER IMPORTANT
        ##################################

        print("Publishing db instance")

        self.post_entity(instance_payload)


        print("Publishing db")

        self.post_entity(db_payload)


        print("Publishing source")

        self.post_entity(source_payload)


        print("Publishing target")

        self.post_entity(target_payload)


        print("Publishing process")

        self.post_entity(process_payload)
```

---

# Why this will now work

Because Atlas now gets:

```
rdbms_db_instance ✔
rdbms_db ✔
rdbms_table ✔
Process ✔
```

Correct dependency order.

---

# One more fix needed in lineage_builder.py

Your source_qn showed:

```
@governance
```

So fix build_qualified_name:

Replace with:

```python
def build_qualified_name(schema_name,table_name):

    schema_name=str(schema_name)
    table_name=str(table_name)

    if is_hive_schema(schema_name):

        return f"{schema_name}.{table_name}@cm"

    return f"{schema_name}.{table_name}@governance"
```

---

# Expected result now

Running:

```
python3 test_publish_one_transition.py
```

Should show:

```
Publishing db instance
Publishing db
Publishing source
Publishing target
Publishing process
```

NO ERRORS.

---

# What Atlas UI should show now

You should see:

```
countries_lookup (RDBMS)
        ↓
countries_lookup (Bronze)
```

---

# After this works we go to the real important step:

**COLUMN LINEAGE**

This is where your governance table becomes powerful.

We will add:

```
columnMapping attribute
```

Which gives:

```
column → column lineage
```

---

# Next step after this succeeds

Tell me:

**Did process publish successfully?**

If yes next we build:

**production column lineage publisher**

That is the real governance value.
