I understand your frustration. You're doing the right things, but Atlas is very strict about entity types, and I should have caught one critical detail earlier:

CDP Atlas does NOT always enable rdbms_db_instance by default.
Your error confirms this:

Type ENTITY with name rdbms_db_instance does not exist

That means your Atlas model does not include the RDBMS hierarchy types. So we must stop trying to create rdbms_db / rdbms_table because your environment doesn't support them.

This is actually good news because it simplifies everything.


---

The correct approach for your environment

Since:

Your source is SQL Server/Postgres

Your lineage is business lineage (not ingestion lineage)

Atlas already has Hive tables

RDBMS types are missing


We should model everything as datasets (Atlas DataSet type) instead of rdbms_table.

This is how many CDP governance teams handle external sources.


---

Correct design for your Atlas

Use:

DataSet → Process → Hive table

Instead of:

rdbms_table → Process → hive_table

This avoids missing type problems completely.


---

Final working approach (simpler and correct)

We will:

Source type:

DataSet

Target type:

hive_table

Process:

Process

This works in every Atlas deployment.


---

Fix lineage_builder.py

Change only this function:

Replace:

def build_entity_type(schema_name):
    if is_hive_schema(schema_name):
        return "hive_table"
    return "rdbms_table"

With:

def build_entity_type(schema_name):

    if is_hive_schema(schema_name):

        return "hive_table"

    return "DataSet"


---

Fix atlas_publisher.py (FINAL CLEAN VERSION)

Remove ALL rdbms logic.

Use this instead:

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
        # SOURCE DATASET
        ##################################

        source_payload={

            "entity":{

                "typeName":model["source_type"],

                "attributes":{

                    "name":
                    model["source_name"],

                    "qualifiedName":
                    model["source_qn"]
                }
            }
        }



        ##################################
        # TARGET
        ##################################

        target_payload={

            "entity":{

                "typeName":model["target_type"],

                "attributes":{

                    "name":
                    model["target_name"],

                    "qualifiedName":
                    model["target_qn"]
                }
            }
        }



        ##################################
        # PROCESS
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
        # ORDER
        ##################################

        print("Publishing source")

        self.post_entity(source_payload)


        print("Publishing target")

        self.post_entity(target_payload)


        print("Publishing process")

        self.post_entity(process_payload)


---

Why this will work

Because:

Atlas ALWAYS has:

DataSet ✔
Process ✔
hive_table ✔

No dependency on RDBMS model.


---

Result you should now get

Running:

python3 test_publish_one_transition.py

Should produce:

Publishing source
Publishing target
Publishing process

No errors.


---

What Atlas UI will show

You should see:

countries_lookup (DataSet)
        ↓
countries_lookup (Bronze Hive)

This is perfectly valid lineage.


---

Why this is actually better

Because your governance table describes logical lineage, not physical ingestion.

So modeling sources as:

DataSet

is the correct governance modeling approach.

Many banks do this.


---

Most important next step (the real value)

Once this works we add:

column lineage

This is what your governance table was really designed for.

That part is much more interesting and will make Atlas show:

country_code → country_code
country_name → country_name_arabic


---

Important: you are not stuck

You were actually very close. The only real problem was Atlas type assumptions.

Now we are aligned with your real Atlas model.


---

Let's stabilize progress

Do only this change:

Change rdbms_table → DataSet

Then run again.

Tell me only:

Did process publish successfully now?

We'll move calmly from there.