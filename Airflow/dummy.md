Great. Next is the right point to prepare Atlas itself.

## Step 7 — Create the Atlas types before sending entities

Because Atlas exposes a type-definition API at `/v2/types/typedefs` and bulk entity creation at `/v2/entity/bulk`, the clean sequence is:

1. create your custom types once
2. then start sending entities in later steps. ([Apache Atlas][1])

Also, since you want custom attributes like `job_id`, `job_cd`, `sql_query`, and the owner relation from column to dataset, it is safer to use your own custom types rather than trying to force all of that into the built-in types. Atlas supports custom entity types and separate relationship definitions through the type system. ([Apache Atlas][2])

### What we will create

We will create exactly 3 items:

* `gca_dataset`
* `gca_column`
* `gca_column_to_dataset` relationship

For now I recommend we **keep Atlas `Process` for the next step only if your Atlas accepts it with minimal attributes**. If it becomes strict, we will switch to `gca_process` after that. Right now, do not create `gca_process` yet.

## 7.1 First, test Atlas through Knox

Run this from the Airflow server or any server that can reach Knox.

Replace:

* `KNOX_URL`
* `USERNAME`
* `PASSWORD`

Example shape:

```bash
curl -k -u 'USERNAME:PASSWORD' \
  'https://KNOX_URL/api/atlas/v2/types/entitydef/name/gca_dataset'
```

Expected:

* `404` or “not found” if the type does not exist yet
* `200` if it already exists

Atlas documents the `/v2/types/entitydef/name/{name}` endpoint for reading an entity definition by name. ([Apache Atlas][1])

## 7.2 Create a typedef JSON file

Create a file, for example:

```bash
vi /tmp/gca_atlas_types.json
```

Put this content in it:

```json
{
  "entityDefs": [
    {
      "category": "ENTITY",
      "name": "gca_dataset",
      "description": "Governance-controlled dataset entity for DataLike Governance lineage",
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
          "name": "connection_code",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "connection_type",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "schema_name",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "table_name",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "logical_path",
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
    },
    {
      "category": "ENTITY",
      "name": "gca_column",
      "description": "Governance-controlled column entity for DataLike Governance lineage",
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
          "name": "column_name_desc",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": false
        },
        {
          "name": "connection_code",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "connection_type",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "schema_name",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
        },
        {
          "name": "table_name",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "isUnique": false,
          "isIndexable": true
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
  "relationshipDefs": [
    {
      "category": "RELATIONSHIP",
      "name": "gca_column_to_dataset",
      "description": "Relationship from gca_column to owning gca_dataset",
      "typeVersion": "1.0",
      "relationshipCategory": "ASSOCIATION",
      "propagateTags": "NONE",
      "endDef1": {
        "type": "gca_column",
        "name": "owner_dataset",
        "isContainer": false,
        "cardinality": "SINGLE"
      },
      "endDef2": {
        "type": "gca_dataset",
        "name": "columns",
        "isContainer": false,
        "cardinality": "SET"
      },
      "attributeDefs": []
    }
  ],
  "classificationDefs": [],
  "enumDefs": [],
  "structDefs": [],
  "businessMetadataDefs": []
}
```

## 7.3 Create the types in Atlas

Run:

```bash
curl -k -u 'USERNAME:PASSWORD' \
  -H 'Content-Type: application/json' \
  -X POST \
  --data @/tmp/gca_atlas_types.json \
  'https://KNOX_URL/api/atlas/v2/types/typedefs'
```

Atlas documents `/v2/types/typedefs` as the CRUD endpoint for type definitions. ([Apache Atlas][1])

## 7.4 Verify the created types

Run these:

```bash
curl -k -u 'USERNAME:PASSWORD' \
  'https://KNOX_URL/api/atlas/v2/types/entitydef/name/gca_dataset'
```

```bash
curl -k -u 'USERNAME:PASSWORD' \
  'https://KNOX_URL/api/atlas/v2/types/entitydef/name/gca_column'
```

And this one for the relationship:

```bash
curl -k -u 'USERNAME:PASSWORD' \
  'https://KNOX_URL/api/atlas/v2/types/relationshipdef/name/gca_column_to_dataset'
```

Atlas documents both entity-definition and relationship-definition lookup-by-name endpoints. ([Apache Atlas][1])

## Small note on your DAG warnings

Your run log showed deprecation warnings around `airflow.models.Variable`. In Airflow 3, Variables are documented under `from airflow.sdk import Variable`, so we should clean that import in a later refactor, though it is not blocking your current prototype. ([Apache Airflow][3])

## What I need from you now

Do this step only, then reply with one of these:

* `Step 7 done - types created`
* `Step 7 done - already existed`
* or paste the Atlas error message if the POST fails

After that I’ll give you **Step 8: modify the DAG to push one small test batch into Atlas using `/v2/entity/bulk`**.

[1]: https://atlas.apache.org/api/v2/index.html "Atlas REST API"
[2]: https://atlas.apache.org/1.2.0/api/v2/index.html "Atlas REST API"
[3]: https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/variables.html?utm_source=chatgpt.com "Variables — Airflow 3.1.8 Documentation"
