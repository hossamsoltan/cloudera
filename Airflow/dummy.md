That error means Atlas is trying to create the **process** entity, but the entity you referenced in `inputs` or `outputs` by `qualifiedName` does **not already exist** in Atlas. Atlas lineage is built with a process that points to input and output assets, and those referenced assets must already exist if you reference them by `uniqueAttributes.qualifiedName`. Atlas bulk/entity APIs match existing entities by unique attributes such as `qualifiedName`, but a reference by `qualifiedName` fails when Atlas cannot find that entity. ([Apache Atlas][1])

So you have 2 correct ways to proceed.

## Option 1 — easiest

Create the datasets first, then create the process.

### Step A

Create the source dataset alone.

Example:

```json
{
  "entity": {
    "typeName": "DataSet",
    "attributes": {
      "name": "orders_source_test",
      "qualifiedName": "mssql://sql-prod/testdb/dbo/orders"
    }
  }
}
```

Send it to:

```bash
curl --negotiate -u : -k \
  -H "Content-Type: application/json" \
  -X POST \
  https://<atlas-host>:31443/api/atlas/v2/entity \
  -d @source.json
```

### Step B

Create the target dataset alone.

Example:

```json
{
  "entity": {
    "typeName": "DataSet",
    "attributes": {
      "name": "orders_bronze_test",
      "qualifiedName": "hive://cdp-prod/bronze/orders_test"
    }
  }
}
```

Send it:

```bash
curl --negotiate -u : -k \
  -H "Content-Type: application/json" \
  -X POST \
  https://<atlas-host>:31443/api/atlas/v2/entity \
  -d @target.json
```

### Step C

After both exist, create the process entity that references them.

Example:

```json
{
  "entity": {
    "typeName": "Process",
    "attributes": {
      "name": "airflow_orders_test_process",
      "qualifiedName": "airflow://prod/test_dag/test_task",
      "inputs": [
        {
          "typeName": "DataSet",
          "uniqueAttributes": {
            "qualifiedName": "mssql://sql-prod/testdb/dbo/orders"
          }
        }
      ],
      "outputs": [
        {
          "typeName": "DataSet",
          "uniqueAttributes": {
            "qualifiedName": "hive://cdp-prod/bronze/orders_test"
          }
        }
      ]
    }
  }
}
```

This is the safest first test.

---

## Option 2 — create all in one request

You can create the datasets and process in the same bulk request, but then do **not** reference the datasets only by `qualifiedName` as if they already exist. In Atlas bulk create/update, one common pattern is to include all entities together and connect them using internal entity references in the same request, rather than expecting Atlas to resolve not-yet-created assets by `qualifiedName`. Atlas supports bulk create/update, but references by unique attributes are for matching existing entities. ([Apache Atlas][1])

For your first success test, **Option 1 is much easier**.

## One more important point

Your payload used generic type names like:

* `DataSet`
* `Process`

These may work only if your Atlas type model actually has those exact types enabled in your environment. Atlas type definitions vary by deployment, and in Cloudera environments many real assets are represented by more specific types such as Hive table types rather than generic placeholders. First verify which type names actually exist in your Atlas type system. Atlas exposes type APIs for that. ([Apache Atlas][2])

Run this first:

```bash
curl --negotiate -u : -k \
  https://<atlas-host>:31443/api/atlas/v2/types/typedefs
```

Then search in the output for:

* `DataSet`
* `Process`
* or the real table types you want to use

## Best next step

Do this exact sequence:

1. Create **one source dataset only**
2. Create **one target dataset only**
3. Search them in Atlas UI
4. Then create the **process** referencing them

If step 1 or 2 fails, the issue is your **type name** or required attributes.
If steps 1 and 2 succeed but step 3 fails, the issue is the **reference format**.

Send me the response from creating the **source dataset only**, and I’ll give you the exact corrected JSON for your Atlas type model.

[1]: https://atlas.apache.org/api/v2/resource_EntityREST.html?utm_source=chatgpt.com "Atlas REST API: EntityREST"
[2]: https://atlas.apache.org/api/v2/application.wadl?utm_source=chatgpt.com "https://atlas.apache.org/api/v2/application.wadl"
