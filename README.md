# flink-streaming-transforms

Streaming transformation jobs that read from Paimon lakehouse and produce enriched business models.

Mirrors the architecture of the company `flink-udm-ned` repo.

## Prerequisites

Repo 1 (`flink-cdc-ingestion`) must be running — this repo reads from the Paimon tables that repo 1 writes.

## Project Structure

```
flink-streaming-transforms/
├── infra/
│   └── docker-compose.yml          # Optional separate Flink cluster
├── src/main/
│   ├── java/com/learning/transforms/
│   │   ├── jobs/                    # One class per job (like ProgramStageJob, VideoWorkJob)
│   │   ├── config/                  # Config classes
│   │   ├── util/                    # Schema converter, table creation helpers
│   │   └── pojo/                    # Data type classes (like ProgramUpdate, VideoWorkVersion)
│   └── resources/
│       └── sql/                     # SQL files for transformations
│           ├── OrderEnrichment.sql
│           ├── InventoryTracking.sql
│           └── RevenueByCategory.sql
└── pom.xml
```

## Learning Exercises

### Phase 1: Read from Paimon (mirrors ProgramStageJob)
- [ ] Create a main class that reads from Paimon catalog
- [ ] Read the `orders` table as a changelog stream
- [ ] Print the stream to console — observe INSERT/UPDATE/DELETE events
- [ ] Understand: `toChangelogStream()` vs `toDataStream()`

### Phase 2: Temporal Joins (mirrors ProgramStage.sql)
- [ ] Complete `OrderEnrichment.sql` — join orders with customers
- [ ] Add product enrichment via order_items
- [ ] Write enriched results to a new Paimon table
- [ ] Key concept: `FOR SYSTEM_TIME AS OF proc_time`

### Phase 3: Side Outputs (mirrors VideoWorkJob)
- [ ] Create a job that fans one stream into multiple outputs
- [ ] Use `ProcessFunction` + `OutputTag` to split order stream by status
- [ ] Write each side output to a different Paimon table
- [ ] Key concept: one input stream → multiple transformations

### Phase 4: Stateful Streaming (no direct company equivalent)
- [ ] Complete `InventoryTracking.sql` — real-time stock levels
- [ ] Complete `RevenueByCategory.sql` — windowed revenue
- [ ] Understand state size, TTL, and cleanup

### Phase 5: Multi-Job Pipeline (mirrors the full company architecture)
- [ ] Chain jobs: OrderEnrichmentJob → OrderAnalyticsJob → RevenueJob
- [ ] Each job reads from the previous job's output table
- [ ] This mirrors: ProgramStageJob → VideoWorkJob → VideoWorkRelJob → VideoWorkRootJob

## Mapping to Company Repo

| This repo | Company repo (`flink-udm-ned`) |
|-----------|-------------------------------|
| `TransformApp.java` | `NedtransformerApplication.java` |
| `jobs/OrderEnrichmentJob.java` | `ProgramStageJob.java` |
| `jobs/OrderAnalyticsJob.java` | `VideoWorkJob.java` (with side outputs) |
| `sql/OrderEnrichment.sql` | `sql/ProgramStage.sql` |
| `sql/InventoryTracking.sql` | Streaming aggregation (new concept) |
| `sql/RevenueByCategory.sql` | Windowed aggregation (new concept) |
| `util/` | `util/CreateTable.java`, `SchemaConverter.java` |
| `pojo/` | `datatype/ProgramUpdate.java`, `VideoWorkVersion.java` |
