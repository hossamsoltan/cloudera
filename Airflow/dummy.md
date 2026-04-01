Excellent. Then we will follow the safer design:

* `gca_dataset`
* `gca_column`
* `gca_process`
* `gca_column_to_dataset`

Using custom `gca_process` is the cleanest way to keep your business attributes like:

* `job_id`
* `job_cd`
* `sql_query`
* `governance_id`
* `action_type`
* `create_timestamp`

without depending on what Atlas standard `Process` allows.

# Step 8 — Create `gca_process` type

## 1) Create this file

On the Atlas-access server, create:

```bash
vi /tmp/gca_process_type.json
```

Put this JSON in it:

```json
{
  "entityDefs": [
    {
      "category": "ENTITY",
      "name": "gca_process",
      "description": "Governance-controlled transformation process for DataLike Governance lineage",
      "typeVersion": "1.0",
      "superTypes": [],
      "attributeDefs": [
        {
          "name": "qualifiedName",
          "typeName": "string",
          "isOptional": false,
          "cardinality": "SINGLE",
          "isUnique": true,
          "isIndexable": true
        },
        {
          "name": "name",
          "typeName": "string",
          "isOptional": false,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "description",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": false
        },
        {
          "name": "job_id",
          "typeName": "long",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "job_cd",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "governance_id",
          "typeName": "long",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "action_type",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "create_timestamp",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "source_connection_code",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "destination_connection_code",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "mapping_level",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "sql_query",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": false
        },
        {
          "name": "governance_source",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        }
      ]
    }
  ],
  "relationshipDefs": [],
  "classificationDefs": [],
  "enumDefs": [],
  "structDefs": [],
  "businessMetadataDefs": []
}
```

## 2) Create the type in Atlas

Use your direct Atlas URL with Kerberos:

```bash
curl --negotiate -u : \
  -H "Content-Type: application/json" \
  -X POST \
  --data @/tmp/gca_process_type.json \
  "${ATLAS_URL}/api/atlas/v2/types/typedefs"
```

## 3) Verify

Run:

```bash
curl --negotiate -u : \
  -X GET \
  "${ATLAS_URL}/api/atlas/v2/types/entitydef/name/gca_process"
```

---

# Step 9 — Modify the DAG to build `gca_process` instead of `Process`

Now update only the process builder function in your DAG.

## Replace this function

Replace:

```python
def build_process_entity(rec):
    return {
        "typeName": "Process",
        ...
    }
```

with this:

```python
def build_process_entity(rec):
    return {
        "typeName": "gca_process",
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
```

## Also change the sample print label

Change:

```python
print(f"Sample process payload: {sample_process}")
```

No structural change needed there, just keep it.

## Run the DAG again

This is still only payload build, not Atlas push.
We only want to confirm there is no Python issue after moving to `gca_process`.

---

# Step 10 — Prepare the first real Atlas bulk push test

After Step 9 works, the next step will be:

* send a very small batch, like 5 or 10 rows
* directly to Atlas `/api/atlas/v2/entity/bulk`
* first datasets
* then columns
* then processes
* and only if success, later we automate watermark update

We do it in that order so debugging is easy.

---

# What I need from you now

Do these two items:

1. Create `gca_process` type
2. Update DAG function to use `gca_process`

Then reply with:

* `Step 8 done`
* or paste any Atlas error if type creation fails

After that I will give you **Step 11: first live Atlas bulk push from Airflow for 5 test rows only**.
