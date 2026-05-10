---
layout: post
title: "When does Iceberg beat Parquet+projection on AWS Glue, and when doesn't ?"
date: 2026-05-10
categories: [data-engineering]
tags: [aws, glue, iceberg, parquet]
repo: bilardi/etl-prototype
lang: en
social_summary: "When does #Iceberg beat #Parquet+projection on #AWSGlue, and when doesn't ?\n\nAn end-to-end #ETL PoC on #AWS to find out: producer, #Kinesis, two #Firehose paths, two #Glue jobs, #Athena.\n\n🔮 Spoiler: how the data is read is the key to the choice.\n\nIn the article: every choice with its why, plus a few gems from some Glue experience 😄"
---

![Architecture](https://raw.githubusercontent.com/bilardi/etl-prototype/master/images/architecture.drawio.png)

## Why this project

I built this [repo](https://github.com/bilardi/etl-prototype) because I didn't have one of this kind yet and, having worked on data ingestion with Glue for a while, I wanted to gather in one place three things: how to structure code so it stays testable, which Firehose and Glue features to use and on what criteria, and a few Docker and Terraform gems I'd always promised myself to slot in somewhere.

Plus, I had never set up Glue streaming from scratch, and for a personal project I needed a test bed to compare Iceberg and Parquet + partition projection on the same data flow and under the same Athena queries, to figure out when one solution wins over the other and why.

This project mixes a lot of the experience I've gathered over the years with a couple of curiosities I hadn't had a chance to test. So there are no real challenges here: I already took those hits long ago. What I'm sharing is deliberate choices, driven by knowing these services inside out.

The architecture in the image describes exactly this project: a Python producer simulating stock tickers, a Kinesis Data Stream as the single entry point, two Firehose streams persisting the same flow in two different formats (Iceberg and Parquet), two Glue jobs that write to both formats (one batch for OHLC computation on 1m and 5m, one streaming for anomaly detection via z-score on a sliding window), and Athena querying both databases.

## The choices and why

The goal was to compare Glue batch and Athena on top of an Iceberg-based database and a Parquet + partition projection one.

| Choice | Why (less effort) | Discarded alternative (more effort) |
|--------|-------------------|--------------------------------------|
| Python producer with `boto3.put_records` | Original code, controllable scenarios (`stable`, `trend`, `spike`, `mixed`), pytest tests | Kinesis Data Generator: webapp with Cognito, poorly maintained |
| Parquet | Partitioned with projection ready to use | The alternative forces you to run a Crawler or schedule MSCK REPAIR TABLE |
| `--LOAD_DATA_MODE` (`parquet`, `spark`, `iceberg`) | One parameter exposes three read strategies you can compare in the same deploy | Three separate Glue jobs |
| Wheel + `--additional-python-modules` | Explicit `pip install` at worker boot, `pip install -e .` locally: same import semantics | `--extra-py-files` with zip or wheel: less deterministic across Glue versions |
| 3-line wrapper in `src/glue_jobs/` | 3 lines that call `run()` from the wheel: all logic testable in pytest | All code in `script_location`: no pytest on the main scripts |

The record schema the producer writes (`ticker_symbol`, `sector`, `price`, `change`, `event_timestamp`) isn't something I made up: it's the one from the official AWS Firehose demo. That demo configures a single Firehose; this PoC configures two in parallel, one for Iceberg and one for Parquet+projection, to compare both storages on top of the same source. The Kinesis Data Generator is the tool the demo uses to produce the dataset, but rewriting it as a Python producer with `boto3` gave me control over the scenarios (`stable`, `trend`, `spike`, `mixed`) and made them testable in pytest. The scenarios feed Glue streaming, which handles anomaly detection: `spike` injects controlled price spikes to validate z-score detection on anomalies, `stable` and `trend` act as baseline to avoid false positives.

As a lazy developer, the criterion is always the same: less effort, in terms of time, code or cost. Two rows of the table deserve a deeper look: `--LOAD_DATA_MODE` raises the question of read modes, the 3-line wrapper carries the code organization that makes TDD possible. I'll cover them one at a time, starting with reading.

## Performance and read modes

To understand why the three `LOAD_DATA_MODE` exist, you have to start from the choice of [partition projection](https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html) as the partitioning strategy. The alternative would have been registering the partitions in Glue Catalog [via Crawler or `MSCK REPAIR TABLE`](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-partitions.html), letting you read them from Glue with `from_catalog` and leverage the push-down predicate, [up to 5x faster](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-partitions.html) than post-read filtering. `GetPartitions` can hit [API rate limits](https://repost.aws/knowledge-center/glue-throttling-rate-exceeded), S3 `LIST` instead scales because it's [paginated](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html). Projection skips the registration (the table above reminds you why: less effort), but comes with a [constraint](https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html):

> _Partition projection is usable only when the table is queried through Athena. If the same table is read through another service such as Amazon Redshift Spectrum, Athena for Spark, or Amazon EMR, the standard partition metadata is used._

So a Glue job reading the Parquet+projection database via `from_catalog` would fall back to standard partition metadata, which for a projection table aren't registered in the Catalog: no partition info available on the Glue side, full scan that goes nowhere, dead end. You have to go straight to S3 with `spark.read.parquet`, leaving Spark to handle [partition discovery](https://spark.apache.org/docs/latest/sql-data-sources-parquet.html#partition-discovery) via `LIST` of the prefixes. Projection only matters when you query the same table from Athena, where it does its job: no `GetPartitions` calls to the Catalog, partitions computed in memory from the template.

From here, the three modes of `LOAD_DATA_MODE` exposed by the Glue batch job:

| Mode | What it returns | Extra cost vs `spark` | When it makes sense |
|---|---|---|---|
| `parquet` | Glue DynamicFrame (`from_options(connection_type="s3", format="parquet")`) | Schema discovery on-the-fly + ResolveChoice (explicit encoding of columns with inconsistent types as "choice"); wrapper memory overhead | Raw "messy" data or unstable schema, where the DynamicFrame's flexibility helps |
| `spark` | Plain DataFrame (`spark.read.parquet(path)`) | No extra overhead: schema is what it is | Parquet data with stable schema, like Firehose-generated. The most direct path |
| `iceberg` | DynamicFrame from `from_catalog`, but the read goes through Iceberg metadata (manifest list, column statistics) | Reading the manifest list (small fixed cost); in exchange you get file skipping on non-partition filters | Data managed as Iceberg tables with MERGE/UPSERT, and when typical filters are on columns with useful statistics (timestamp, ticker, etc.) |

The DynamicFrame's traits are described in the [Glue documentation](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-api-crawler-pyspark-extensions-dynamic-frame.html):

> _A `DynamicFrame` is similar to a `DataFrame`, except that each record is self-describing, so no schema is required initially. Instead, AWS Glue computes a schema on-the-fly when required, and explicitly encodes schema inconsistencies using a choice (or union) type._

The access pattern shifts the balance between `spark`/`parquet` and `iceberg` as volume grows:

| Access pattern | Small volumes (~1 GB) | Large volumes (50-100 GB, many files) |
|---|---|---|
| Full read, no filter | `iceberg` slightly penalized by the fixed cost of the manifest read | `iceberg` comparable: the manifest cost dilutes against total I/O |
| Filter on partition column | comparable: both do basic pruning | `iceberg` wins: the manifest list is O(1) over partition count, S3 list grows with O(n) |
| Filter on non-partition column | `iceberg` wins via column statistics in the manifests: skips entire files without opening them | `iceberg` wins clearly: `parquet`/`spark` have to read and filter at runtime |

In practice, on large volumes [Iceberg](https://iceberg.apache.org/spec/) wins because it keeps, for each Parquet file, the min and max value of every column. When a query filters (say `ticker_symbol = 'AMZN'`), the query engine looks at those min/max and immediately knows which files might hold the data and which can't; the discarded files don't even get opened.

As a lazy developer I preferred reading the documentation rather than running a generic benchmark, because the access pattern is already clear. Then, case by case, the choice depends on the kind of data access required.

## Three-layer TDD on Glue jobs

Glue jobs are notoriously hard to test: you need `GlueContext`, you need a real Iceberg `MERGE INTO`, you need Spark configured the way it runs on the worker. I don't give up TDD here either: I split the code into three layers with clear boundaries.

1. **Pure Python logic** (argument parsing, naming derivation, producer scenarios): direct pytest, zero AWS or Spark dependencies
2. **Spark core transformations** (the `OhlcAggregator`, `ZScoreDetector` classes): `SparkSession.builder.master("local[1]")` as fixture, DataFrames built from literals. The classes are DataFrame-in / DataFrame-out, fully isolated
3. **Orchestrator `run()`**: takes `args`, `spark`, `glue_context`, `read_*_fn`, `write_fn` as parameters. Tests pass a mocked `GlueContext` and test source/sink functions. The principle is "the job builds, the classes consume": all Glue knowledge lives in `_cli_entrypoint`, which instantiates source and sink before calling `run()`

What stays out of pytest is just the real integration (Glue Data Catalog, Iceberg `MERGE INTO`, Kinesis Stream): covered by the JSON files in `tests/integration/`, which run both locally via docker compose and on AWS via `aws glue start-job-run`. The same file drives both: no duplication between AWS config and local test scripts.

Alongside, `docker-compose.yaml` exposes two profiles pointing to the official AWS images, `glue4` (Spark 3.3, Python 3.10) and `glue5` (Spark 3.5, Python 3.11, Iceberg built-in): `make test-integration-local PROFILE=glue5` (default) or `PROFILE=glue4`. The mount paths differ between the two images (`/home/glue_user/` vs `/home/hadoop/`), but `local_test.sh` uses relative paths so the same JSON works on both. It's the shortcut to validate the same script on two Glue versions before bumping `glue_version`.

The Python developer in me is now very satisfied.

## What I learned (the hard way)

### Firehose with format conversion: 64 MB minimum and cached schemas

Firehose accumulates records in a buffer before writing them to S3, and flushes in two cases: when the buffer reaches a certain size (`buffering_size`, in MB) or when a certain time passes (`buffering_interval`, in seconds).

For a while now, the minimum values for these buffers have been lowered: `buffering_size` starts at 1 MB and `buffering_interval` at 0 seconds.

For a PoC with small volumes I wanted a quick flush: I set `buffering_size = 1` MB and `buffering_interval = 60s`, counting on the flush to fire on time before size.

On the Iceberg Firehose it went smoothly. On the Parquet+projection Firehose, no:

```
Error: InvalidArgumentException: BufferingHints.SizeInMBs must be at least 64
```

When a Firehose has format conversion enabled (`data_format_conversion_configuration`, which converts the incoming JSON to Parquet before writing it to S3), AWS imposes `buffering_size >= 64` MB. On the Iceberg Firehose there's no conversion (Iceberg leans on its own native format), so 1 MB is accepted. On Parquet+projection I bumped the value to 64 MB and that was that: the flush stays governed by `buffering_interval = 60s`, and at PoC volumes the 64 MB never get saturated. Perceived latency unchanged.

Same Parquet+projection Firehose, second round: after apply, records were ending up in `s3://bucket/parquet_projection/_firehose_errors/format-conversion-failed/` instead of `raw/`. Cause: the producer writes `event_timestamp` as ISO 8601 with `T` and timezone (`"2026-04-23T20:48:32+00:00"`), but the OpenXJsonSerDe used by Firehose accepts as Hive timestamp only `yyyy-MM-dd HH:mm:ss[.fff]`. The Iceberg Firehose accepts ISO 8601 natively, the Parquet+projection one doesn't. Three options:

1. **change the producer to write epoch millis**: that was the cleanest, but assuming you can't touch the producer, where would it make sense to handle the conversion downstream ?
2. **add a Lambda processor in Firehose to reformat the timestamp**: such a simple operation, repeated on every record, was it really worth bringing in a Lambda ?
3. **type `event_timestamp` as `string` in the Glue raw tables, and cast it in Spark via `F.to_timestamp("event_timestamp")` when needed**: when Spark has all the data in hand, it can handle the typing with O(n) complexity but parallelized

Picked the third. The "natural" type lives in the layer where the data is born (`raw` populated by Firehose, `string` for portability), the `timestamp` type appears in `aggregated_*` and `anomalies` where DataFrames are already in Spark's hands.

After applying the fix, I updated the Glue raw table schema, changing the type of `event_timestamp` from `timestamp` to `string`. `terraform apply` went through fine, but for the next ~5 minutes the records kept landing in `_firehose_errors/`. Cause: Firehose caches the `schema_configuration` of the Glue table to avoid querying the Catalog on every record. AWS documents "up to 15 minutes" of cache; in tests 5 were enough before seeing records arrive cleanly in `raw/`. To skip the wait, `terraform apply -replace="aws_kinesis_firehose_delivery_stream.parquet_projection[0]"` recreates the delivery stream and clears the cache. For a PoC the wait is fine; in a real case the `replace` (or `aws firehose update-destination` directly) is the faster path.

### The wheel filename: a story unto itself

In the distant past, before I had local test management, I had the bad idea of providing the Glue job with the wheel renamed to `dist/glue_common.whl`, so I wouldn't have to touch any configuration on each new upload to S3.

But Glue throws a fit:

```
LAUNCH ERROR | Installation of Additional Python Modules failed:
ERROR: glue_common.whl is not a valid wheel filename
```

`pip install` requires the PEP 427 form: `{name}-{version}-{python}-{abi}-{platform}.whl`. The unversioned alias doesn't pass validation outside the PyPI context.

So as a lazy developer, what's the best way to do everything automatically without forgetting to upload the new wheel ?

- Terraform reads the version dynamically from `src/glue_common/__init__.py` via `regex()`, builds the PEP 427 name and uses it as S3 key and source path
- on `make patch` the filename changes, Terraform sees the new file and re-uploads it to S3 by itself

Another satisfying win.

### Iceberg on Glue 5.0: two ways to register the catalog

After the wheel fix, the batch job stopped on:

```
AnalysisException: [TABLE_OR_VIEW_NOT_FOUND]
The table or view 'etl_prototype_demo_iceberg.aggregated_1m' cannot be found
```

The tables were in the Glue Data Catalog (Terraform had created them, I could see them via `aws glue get-tables`). What was missing was the bridge between Spark and the Catalog: the keys `spark.sql.extensions`, `spark.sql.catalog.glue_catalog.*` and `spark.sql.defaultCatalog` that tell Spark "_for the `glue_catalog` catalog, use the Iceberg implementation that leans on the Glue Data Catalog_".

It's a technical constraint: these keys must be applied **before** the SparkSession is initialized. Once `GlueContext(sc)` has created the SparkSession, a runtime `spark.conf.set("spark.sql.catalog.glue_catalog", "...")` is accepted syntactically, but has no effect: the catalog doesn't get registered and the job answers "_Catalog 'glue_catalog' plugin class not found_". That was exactly my first attempt long ago, before I diligently read the documentation ..

The [Glue documentation for Iceberg](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-format-iceberg.html) lists two equivalent ways to apply the conf in the right place:

> _Create a key named `--conf` for your AWS Glue job, and set it to the following value. **Alternatively, you can set the following configuration using `SparkConf` in your script.**_

Under the hood, the two configurations achieve the same result:

- **SparkConf in Python code**:

  ```python
  sc = SparkContext()
  conf = sc.getConf()
  conf.set("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
  conf.set("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
  # ... other conf ...
  sc.stop()
  sc = SparkContext.getOrCreate(conf=conf)
  glueContext = GlueContext(sc)  # the SparkSession is born here with the right conf
  ```

  The configuration lives in the code. The `sc.stop()` + recreation of the `SparkContext` is when the configuration gets "injected" before SparkSession init.

- **`--conf` in Terraform's `default_arguments`**:

  ```hcl
  locals {
    iceberg_spark_conf = join(" --conf ", [
      "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
      "spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog",
      "spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
      "spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO",
      "spark.sql.catalog.glue_catalog.warehouse=s3://${data.aws_s3_bucket.main.id}/iceberg/",
      "spark.sql.defaultCatalog=glue_catalog",
    ])
  }
  ```

  Glue parses the concatenated string, applies the configurations at SparkSession boot, and then hands control to the Python script.

I chose to configure the PoC via Terraform: why ? Three reasons:

- **a single source of truth**: the `iceberg_spark_conf` `local` is defined once in Terraform and reused by both the Glue batch and the streaming via `--conf = local.iceberg_spark_conf` in their respective `default_arguments`. No per-job duplication, and if I add a third Glue job tomorrow I reuse the same `local` with a single line
- **separation of configuration and code**: the catalog setup lives in Terraform alongside `--datalake-formats=iceberg`; the Python code of the jobs doesn't know an Iceberg catalog exists, it imports `glue_common`, takes `spark` and `glue_context` as parameters and runs
- **low-cost configuration changes**: a different warehouse, catalog implementation or IO is touched only in Terraform, with no need to rebuild and re-upload the wheel

The configuration in code, on the other hand, stays handier when the catalog config depends on arguments the job receives at runtime (for instance a `warehouse` derived from the input bucket name passed as `--ARG`): in that case the conf is built naturally in the code, since you already have the resolved arguments there. In this PoC the warehouse is fixed per environment, so the configuration in Terraform wins on simplicity.

## What else is there to add ?

Once the PoC has been signed off, you start to get serious: there's what was simulated to integrate, and other services and approaches to evaluate:

- **Real APIs**: replace the simulated scenario with a real ingestion. It changes the producer's nature, not the architecture
- **Apache Flink** as an alternative to Glue streaming: it makes sense when you need stricter guarantees on how many times an event is processed (Flink natively supports exactly-once, i.e. each event processed exactly once; Glue streaming is at-least-once and duplicates are handled at the application layer), or when the required latency is sub-second (Glue streaming, working in micro-batches, typically lands in the 5-10 second range; Flink drops to hundreds of milliseconds)
- **Multi-environment deploy**: in a PoC, a single environment is enough. In production you need to separate so you can test feature rollouts without touching live data. So you introduce Terraform Workspaces or per-env modules, with all the implications for account management
- **CI/CD**: in a PoC, manual `make test` and `terraform apply` are enough. Working in a team or on mission-critical pipelines you need automation (lint, test, build wheel, terraform plan automatic on every PR) to catch regressions before merge
- **Cross-account Data Catalog sharing**: Lake Formation + RAM + KMS + `assume_role`. When the data lake aggregates flows from branches, departments, partners, the centralized schema changes everything
- **Data Management**: the evolution of centralized Data Catalog sharing is DataZone or SageMaker Unified Studio, with lineage, asset-level permissions and per-asset documentation
- **Extra time frames in the batch** as roll-up from 5m (1h, 1d), not from raw: each level computes on top of the previous level's output, hence on less data. It's a classic approach (cascade ETL) and works when the higher-level aggregate can be recomputed from the lower level (the high of one hour is the max of the highs of the 5 minutes). It doesn't work if the calculation needs to go back to the original values, like medians or exact distinct counts
