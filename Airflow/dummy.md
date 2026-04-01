Perfect — that is better for production.

We will change from:

* **Knox + LDAP**

to:

* **Atlas direct URL + Kerberos authentication**

So Step 7 will be repeated in the new correct form.

# Step 7 — Create Atlas types using direct Atlas URL with Kerberos

## Goal

Create these Atlas types directly on Atlas:

* `gca_dataset`
* `gca_column`
* `gca_column_to_dataset`

using:

* direct Atlas endpoint
* Kerberos ticket authentication

---

# 1) First verify Kerberos works on the server

On the server where you will run the command, first make sure you have a valid Kerberos ticket.

Run:

```bash
klist
```

If no valid ticket exists, run:

```bash
kinit your_user@YOUR.REALM
```

Then confirm again:

```bash
klist
```

You must see a valid TGT before calling Atlas.

---

# 2) Atlas direct URL format

Use the direct Atlas URL, usually like one of these:

```bash
http://atlas-host:21000
```

or

```bash
https://atlas-host:21443
```

You should use your actual direct Atlas URL.

Example placeholder:

```bash
ATLAS_URL=http://your-atlas-host:21000
```

---

# 3) Test direct Atlas access with Kerberos

Run this first:

```bash
curl --negotiate -u : \
  -X GET \
  "${ATLAS_URL}/api/atlas/v2/types/entitydef/name/gca_dataset"
```

### Expected result

* if type does not exist: not found / 404
* if it already exists: returns JSON
* if Kerberos/auth issue: unauthorized / 401 / forbidden / SPNEGO problem

If this fails, stop here and send me the error.

---

# 4) Create the typedef JSON file

Create file:

```bash
vi /tmp/gca_atlas_types.json
```

Put this content exactly:

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

---

# 5) Create the Atlas types using Kerberos

Run:

```bash
curl --negotiate -u : \
  -H "Content-Type: application/json" \
  -X POST \
  --data @/tmp/gca_atlas_types.json \
  "${ATLAS_URL}/api/atlas/v2/types/typedefs"
```

---

# 6) Verify the created types

Run these 3 checks:

```bash
curl --negotiate -u : \
  -X GET \
  "${ATLAS_URL}/api/atlas/v2/types/entitydef/name/gca_dataset"
```

```bash
curl --negotiate -u : \
  -X GET \
  "${ATLAS_URL}/api/atlas/v2/types/entitydef/name/gca_column"
```

```bash
curl --negotiate -u : \
  -X GET \
  "${ATLAS_URL}/api/atlas/v2/types/relationshipdef/name/gca_column_to_dataset"
```

---

# 7) If curl gives Kerberos/SPNEGO issue

Try with:

```bash
curl --negotiate -u : -b ~/cookiejar.txt -c ~/cookiejar.txt \
  -X GET \
  "${ATLAS_URL}/api/atlas/v2/types/entitydef/name/gca_dataset"
```

But first try the simpler one.

---

# 8) Important note before next step

We have only created:

* `gca_dataset`
* `gca_column`
* `gca_column_to_dataset`

We did **not** yet create:

* `gca_process`

In the next step, when we start pushing entities, we will decide whether:

* standard `Process` is enough
* or we create custom `gca_process`

My recommendation is likely we will create **`gca_process`** too, because you need custom attributes cleanly.

---

# What I need from you now

Run this step and reply with one of these:

* `Step 7 done - types created`
* `Step 7 done - already existed`
* or paste the exact Atlas/Kerberos error message
