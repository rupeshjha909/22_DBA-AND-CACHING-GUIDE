# Cassandra Interview Preparation Guide

> A concept-first guide with real-world examples from the digital-reminder microservice that handles bill reminders, notifications, and bill management at scale for Paytm Recharges & Bill Payments.

---

## Table of Contents

1. [What is Cassandra and Why We Chose It](#1-what-is-cassandra-and-why-we-chose-it)
2. [Architecture Fundamentals](#2-architecture-fundamentals)
3. [Data Modeling — The Heart of Cassandra](#3-data-modeling--the-heart-of-cassandra)
4. [Partition Key vs Clustering Key](#4-partition-key-vs-clustering-key)
5. [Consistency Levels](#5-consistency-levels)
6. [Write Path — How Writes Work](#6-write-path--how-writes-work)
7. [Read Path — How Reads Work](#7-read-path--how-reads-work)
8. [Lightweight Transactions (LWT)](#8-lightweight-transactions-lwt)
9. [TTL and Data Expiry](#9-ttl-and-data-expiry)
10. [Batch Operations](#10-batch-operations)
11. [Counter Columns](#11-counter-columns)
12. [Secondary Indexes](#12-secondary-indexes)
13. [ALLOW FILTERING](#13-allow-filtering)
14. [Tombstones and Compaction](#14-tombstones-and-compaction)
15. [Multi-Datacenter Replication](#15-multi-datacenter-replication)
16. [Our Keyspace and Cluster Architecture](#16-our-keyspace-and-cluster-architecture)
17. [Table Design Patterns We Use](#17-table-design-patterns-we-use)
18. [Common Interview Questions](#18-common-interview-questions)

---

## 1. What is Cassandra and Why We Chose It

### Concept

Apache Cassandra is a distributed, wide-column NoSQL database designed for high availability and linear scalability. It has no single point of failure — every node in the cluster is equal (peer-to-peer architecture).

### Why Cassandra over MySQL for certain use cases?

| Aspect | MySQL (our bill tables) | Cassandra (our notification/non-RU tables) |
|--------|------------------------|-------------------------------------------|
| Scale | Vertical scaling, sharding is complex | Horizontal scaling by adding nodes |
| Write throughput | Limited by master-slave replication lag | Optimized for high write throughput |
| Availability | Master failure = downtime | No single point of failure |
| Schema | Rigid relational schema | Flexible wide-column model |
| Read pattern | Complex joins, aggregations | Fast reads by partition key only |

### Why we use both MySQL AND Cassandra

In digital-reminder, we use a **polyglot persistence** approach:

- **MySQL** — RU (registered user) bill records, where we need complex queries, joins, and transactional guarantees for bill status updates, publisher queries with date-range filtering, and batch-based processing
- **Cassandra** — Non-RU bill records, notification caches, payment caches, recent bills, WhatsApp whitelists, user activity tracking — workloads that are write-heavy with simple key-based lookups at massive scale

---

## 2. Architecture Fundamentals

### Ring Architecture

Cassandra organizes data using a **consistent hashing ring**. Each node owns a range of token values. When data is written, the partition key is hashed to determine which node(s) store that data.

```
        Node A (token 0-25)
       /                    \
  Node D (token 76-100)     Node B (token 26-50)
       \                    /
        Node C (token 51-75)
```

### Key Terms

- **Node** — A single Cassandra instance running on a server
- **Rack** — A logical grouping of nodes (usually maps to physical racks or availability zones)
- **Datacenter** — A logical grouping of racks (e.g., `mumbai`, `ap-south-1` in our setup)
- **Cluster** — The full collection of all datacenters
- **Keyspace** — The top-level namespace (equivalent to a database in MySQL)
- **Replication Factor (RF)** — How many copies of data exist across nodes

### How data distribution works

1. You write a record with a partition key (e.g., `customer_id = 12345`)
2. Cassandra hashes the partition key using a **partitioner** (Murmur3 by default)
3. The hash determines which node is the **coordinator** for this partition
4. Based on the replication factor, the data is replicated to RF number of nodes
5. The write is acknowledged based on the **consistency level** requested

### Snitch

The snitch tells Cassandra which nodes belong to which datacenter and rack. This is critical for multi-DC setups. In our production setup, we use `localDataCenter` configuration to ensure reads prefer the nearest datacenter.

---

## 3. Data Modeling — The Heart of Cassandra

### Concept: Query-First Design

This is the **single most important** difference from relational databases:

> In MySQL, you model data first and then write queries.
> In Cassandra, you design your queries first and then model your tables around them.

This means **denormalization is expected and encouraged**. You may store the same data in multiple tables, each optimized for a different query pattern.

### Why query-first?

Because Cassandra can only efficiently query data by:
1. The **full partition key** (mandatory)
2. Optionally, **clustering columns** in order

It cannot do:
- Joins between tables
- Arbitrary WHERE clauses on non-key columns (without ALLOW FILTERING, which is expensive)
- GROUP BY or complex aggregations efficiently

### Example from our codebase

We have separate tables for the same "non-RU bill" data:

| Table | Query Pattern |
|-------|--------------|
| `bills_non_paytm` | Look up bills by `(recharge_number, customer_id, operator, service)` |
| `bills_recent_records` | Look up recent bills by `(customer_id, service)` |
| `bills_due_date` | Look up bills by due date for notification scheduling |

Each table stores overlapping data but is optimized for its specific access pattern.

---

## 4. Partition Key vs Clustering Key

### Concept

The **PRIMARY KEY** in Cassandra has two parts:

```
PRIMARY KEY ((partition_key_columns), clustering_key_columns)
```

- **Partition Key** (in double parentheses) — Determines WHICH node stores the data. All rows with the same partition key are stored together on the same node.
- **Clustering Key** — Determines the ORDER of rows within a partition. Rows are sorted by clustering columns on disk.

### Why this matters

Think of it like a filing cabinet:
- **Partition key** = which drawer to open
- **Clustering key** = how files are sorted inside that drawer

A query MUST specify the full partition key. You can optionally filter by clustering columns, but only in order.

### Example from our tables

For `bills_non_paytm`:

```
WHERE recharge_number = ? AND customer_id = ? AND operator = ? AND service = ?
```

This suggests a primary key like:

```
PRIMARY KEY ((recharge_number, customer_id), operator, service)
```

- Partition key: `(recharge_number, customer_id)` — all bills for a specific recharge number and customer are on the same node
- Clustering key: `operator, service` — within that partition, rows are sorted by operator then service

For `notification_cache`:

```
WHERE customer_id = ? AND recharge_number = ? AND operator = ?
```

Different query pattern = different table design = same underlying data.

### Composite Partition Keys

When you combine multiple columns into a partition key (e.g., `(recharge_number, customer_id)`), ALL columns must be specified in every query. You cannot query by `recharge_number` alone. This is a tradeoff — you get better data distribution but lose the ability to query by individual columns.

---

## 5. Consistency Levels

### Concept

Cassandra lets you choose, per query, how many replicas must acknowledge a read or write before it's considered successful. This is the consistency level.

### Common Consistency Levels

| Level | Meaning | Use When |
|-------|---------|----------|
| `ONE` | Only 1 replica must respond | Maximum speed, eventual consistency is acceptable |
| `QUORUM` | Majority of replicas (RF/2 + 1) must respond | Balance of consistency and performance |
| `LOCAL_QUORUM` | Majority of replicas IN THE LOCAL DC | Multi-DC setups where cross-DC latency is unacceptable |
| `ALL` | Every replica must respond | Maximum consistency, lowest availability |
| `EACH_QUORUM` | Quorum in EACH datacenter | Strong consistency across all DCs |

### The CAP Theorem Connection

With RF=3:
- `ONE` write + `ONE` read = possible stale reads (AP)
- `QUORUM` write + `QUORUM` read = always consistent (CP-ish)
- `LOCAL_QUORUM` = consistent within a datacenter

### How we use it

In our notification cache and CleverTap filter operations, we use `LOCAL_QUORUM` because:
1. We're in a multi-DC setup (`mumbai` + `ap-south-1`)
2. Notification deduplication requires strong consistency (we don't want to send the same notification twice)
3. But we don't want cross-DC latency penalty

For regular bill reads/writes, we use the default (`ONE` or `LOCAL_ONE`) because slight staleness is acceptable and throughput matters more.

---

## 6. Write Path — How Writes Work

### Concept

Cassandra writes are extremely fast because they are **append-only**. The write path:

1. **Client sends write** to any node (the coordinator)
2. Coordinator determines which nodes own this partition
3. Write goes to those replica nodes simultaneously
4. On each replica node:
   - Write is appended to the **commit log** (durability on disk)
   - Write is stored in the **memtable** (in-memory sorted structure)
   - Acknowledgment is sent back
5. When memtable is full, it's **flushed** to disk as an **SSTable** (Sorted String Table)
6. SSTables are periodically merged via **compaction**

### Why writes are fast

- No read-before-write (unlike MySQL UPDATE which reads then modifies)
- Append-only to commit log (sequential I/O, the fastest disk operation)
- Memtable is in-memory
- No locking or transaction overhead (except LWT)

### Hinted Handoff

If a replica node is down during a write:
1. The coordinator stores a **hint** locally
2. When the downed node comes back, the hint is replayed
3. This provides eventual consistency even during node failures

---

## 7. Read Path — How Reads Work

### Concept

Reads are more complex than writes in Cassandra:

1. Client sends read to coordinator
2. Coordinator sends request to replicas based on consistency level
3. On each replica:
   - Check **row cache** (if enabled)
   - Check **memtable** (in-memory, most recent data)
   - Check **bloom filters** for each SSTable (probabilistic: "this SSTable definitely does NOT contain your key" or "might contain your key")
   - If bloom filter says maybe, check **partition index** to find exact offset
   - Read from **SSTable** on disk
4. Merge results from memtable + SSTables (latest timestamp wins)
5. Return to coordinator
6. Coordinator compares responses and returns the most recent

### Why reads can be slower

- Data might be spread across multiple SSTables
- Each SSTable requires a disk seek
- This is why **compaction** is important — it merges SSTables to reduce read amplification

### Read Repair

If during a read the coordinator detects replicas have different versions of data, it triggers a **read repair** — updating stale replicas with the latest data. This happens in the background.

---

## 8. Lightweight Transactions (LWT)

### Concept

Cassandra is eventually consistent by default, but sometimes you need conditional writes — "update only if the current value is X" or "insert only if the row doesn't exist." These are **Lightweight Transactions**, which use the **Paxos consensus protocol** internally.

LWT provides **linearizable consistency** for a single partition, at the cost of:
- 4 round trips instead of 1 (Paxos prepare, promise, propose, accept)
- Approximately 4x latency of a normal write
- Coordinator must communicate with a quorum of replicas

### When to use LWT

- Preventing duplicate records
- Conditional updates where race conditions matter
- Claiming/locking a resource

### How we use it

For non-RU bill mark-as-paid operations:

```sql
UPDATE bills_non_paytm SET amount=?, status=15, update_at=?
WHERE recharge_number=? AND customer_id=? AND operator=? AND service=?
IF EXISTS
```

The `IF EXISTS` makes this an LWT. We use it because multiple consumers might try to update the same bill simultaneously. Without LWT, the last write wins (which could be an older update).

For Airtel cron execution claiming:

```sql
INSERT INTO cron_execution_log (...) IF NOT EXISTS
```

This ensures only one instance of a cron job claims a particular execution slot — preventing duplicate processing across service replicas.

### The `[applied]` column

LWT responses include an `[applied]` boolean column:
- `true` — the condition was met and the write was applied
- `false` — the condition was NOT met, the write was rejected. The response also contains the current row values so you can see why.

---

## 9. TTL and Data Expiry

### Concept

Every column value in Cassandra can have a **Time To Live (TTL)** in seconds. After the TTL expires, the data is marked with a **tombstone** and eventually removed during compaction.

This is extremely useful for:
- Cache data that should auto-expire
- Temporary records
- Compliance requirements (auto-delete after N days)

### How we use TTL

**Payment remind-later cache** — When a user says "remind me later," we store this with a TTL so it auto-expires:

```sql
INSERT INTO payment_remind_later_events
  (recharge_number, service, operator, payment_date, is_encrypted)
VALUES (?, ?, ?, ?, ?)
USING TTL ?
```

The TTL value is configurable, typically set to a few days.

**Map column updates with TTL** — For remind-later data stored as a map:

```sql
UPDATE payment_remind_later_events USING TTL ?
SET remind_later_data[?] = ?
WHERE customer_id = ? AND service = ? AND operator = ?
```

This is powerful — individual map entries expire independently.

**Customer updates** — Active customer records are stored with TTL to auto-purge inactive users.

### TTL Gotchas for Interviews

- TTL is per-column, not per-row (unless set at insert time for all columns)
- A TTL of 0 means no expiry
- Expired data creates tombstones (see Section 14)
- You can check remaining TTL with `TTL(column_name)` in SELECT
- Updating a column resets its TTL (you must re-specify TTL on update)

---

## 10. Batch Operations

### Concept

Cassandra batches group multiple writes into a single operation. But **Cassandra batches are NOT the same as SQL transactions**.

There are two types:
- **Logged batch** (default) — Guarantees atomicity (all or nothing) across partitions using a batchlog. Higher overhead.
- **Unlogged batch** — No atomicity guarantee. Useful only for batching writes to the SAME partition for performance.

### Important: Anti-pattern Warning

Using batches to group writes to DIFFERENT partitions is an **anti-pattern** in most cases. It:
- Creates coordinator overhead (one node must coordinate all writes)
- Introduces a batchlog write (extra I/O)
- Can create hotspots

The right use case for batches is grouping related writes to keep them atomic.

### How we use batches

For payment cache inserts, we batch related inserts together:

```javascript
const batchQuery = [
    { query: insertQuery, params: insertQueryParams }
]
client.batch(batchQuery, { prepare: true })
```

We use `{ prepare: true }` which sends prepared statements — Cassandra only parses the CQL once and reuses the execution plan, improving performance.

---

## 11. Counter Columns

### Concept

Counter columns are a special Cassandra column type that supports atomic increment and decrement operations. They exist because normal columns use "last write wins" semantics, which doesn't work for counting.

Rules:
- A table with counter columns can ONLY have counter columns (plus the primary key)
- You can only UPDATE counters (not INSERT)
- You can increment or decrement by any value
- You cannot set a counter to a specific value or read-then-write

### How we use counters

For **service notification capping** — tracking how many notifications have been sent per service per day:

```sql
UPDATE service_notification_capping
SET notification_count = notification_count + ?
WHERE service = ? AND date = ? AND type = ?
```

This is atomic — even if multiple consumer instances increment simultaneously, the count is always accurate. We use this to enforce daily notification limits per service category.

---

## 12. Secondary Indexes

### Concept

Secondary indexes in Cassandra allow you to query on non-primary-key columns. However, they are fundamentally different from MySQL indexes.

How they work internally:
- Each node maintains a local index of the data on that node
- A query using a secondary index must check ALL nodes (scatter-gather)
- On each node, the local index narrows down the SSTables to read

### When to use (and avoid)

**Good for:**
- Low-cardinality columns (e.g., `status` with values like ACTIVE/INACTIVE)
- Columns queried in combination with the partition key

**Bad for:**
- High-cardinality columns (e.g., email addresses, UUIDs)
- Columns that are frequently updated
- Tables with very large partitions

### How we use secondary indexes

For notification fallback events table, we create indexes at runtime:

```sql
CREATE INDEX IF NOT EXISTS ON reminder.notification_fallback_events (...)
```

This allows querying fallback events by attributes beyond the primary key. We use this sparingly and only for operational/recovery use cases, not high-throughput production reads.

---

## 13. ALLOW FILTERING

### Concept

When your query doesn't fully match the primary key structure, Cassandra rejects it by default. Adding `ALLOW FILTERING` tells Cassandra to proceed anyway, but this means Cassandra must read all data matching the partition key and then filter in-memory.

### Why it's dangerous

```sql
SELECT * FROM users WHERE age > 25 ALLOW FILTERING
```

This scans the ENTIRE table across ALL nodes. On a table with millions of rows, this can:
- Cause timeouts
- Create massive heap pressure
- Overwhelm nodes with GC pauses
- Impact other queries on the same nodes

### When it's acceptable

- Small tables (configuration/lookup tables)
- Combined with partition key (filtering within a single partition is fine)
- Operational/reporting queries that run infrequently

### How we use it

Only for rare reporting queries like Airtel bucket processing status counts:

```sql
SELECT COUNT(*) as completed_count
FROM airtel_bucket_processing_state
WHERE execution_date = ? AND status = 'COMPLETED'
ALLOW FILTERING
```

This is acceptable because:
1. `execution_date` is likely the partition key (limiting scope)
2. This is a daily reporting query, not a production hot path
3. The result set per execution_date is bounded (max 2000 buckets)

---

## 14. Tombstones and Compaction

### Concept: Tombstones

Cassandra doesn't immediately delete data. Instead, a **tombstone** (a deletion marker with a timestamp) is written. The actual data is removed later during compaction.

Why? Because in a distributed system, you can't guarantee all replicas received the delete. If you just removed data from one node, the other replicas might "resurrect" it during read repair. Tombstones prevent this.

### The tombstone lifecycle

1. DELETE or TTL expiry creates a tombstone
2. Tombstone has a `gc_grace_seconds` (default 10 days) — during this window, repair can propagate the tombstone to all replicas
3. After `gc_grace_seconds`, compaction physically removes the tombstone and the original data

### Tombstone problems

Excessive tombstones cause:
- **Read performance degradation** — Cassandra must read through tombstones to find live data
- **Heap pressure** — Tombstones consume memory during reads
- Cassandra will emit warnings or even abort queries if too many tombstones are encountered

Common causes of tombstone accumulation:
- Frequent deletes
- Wide partitions with column-level TTLs
- Inserting NULL values (each NULL is a tombstone)
- Range deletes

### Compaction Strategies

| Strategy | Best For | How It Works |
|----------|----------|-------------|
| **SizeTiered (STCS)** | Write-heavy workloads | Merges SSTables of similar sizes. Default strategy. |
| **Leveled (LCS)** | Read-heavy workloads | Organizes SSTables into levels (L0, L1, L2...). Guarantees 90% of reads touch only 1 SSTable. Higher write amplification. |
| **TimeWindow (TWCS)** | Time-series data | Groups SSTables by time window. Old windows are never compacted with new ones. Best for TTL data. |

### Relevance to our system

Our notification tables and payment caches use TTL extensively. This means tombstones are created regularly as TTLs expire. Time-window compaction would be ideal for these tables to efficiently drop entire time windows of expired data.

---

## 15. Multi-Datacenter Replication

### Concept

Cassandra natively supports replication across multiple datacenters. Each keyspace defines its replication strategy:

- **SimpleStrategy** — For single DC; distributes replicas around the ring
- **NetworkTopologyStrategy** — For multi-DC; you specify RF per datacenter

```sql
CREATE KEYSPACE reminder WITH replication = {
    'class': 'NetworkTopologyStrategy',
    'mumbai': 3,
    'ap-south-1': 3
};
```

This means 3 copies in Mumbai, 3 copies in ap-south-1 = 6 total copies.

### How multi-DC reads/writes work

- **Writes**: Coordinator forwards write to a replica in each DC. Each DC's local coordinator ensures local replication. Cross-DC writes happen asynchronously.
- **Reads with LOCAL_QUORUM**: Only replicas in the coordinator's DC participate. This avoids cross-DC latency.
- **Reads with EACH_QUORUM**: Requires quorum in every DC. Highest consistency, highest latency.

### Our multi-DC setup

We run Cassandra across two datacenters:
- `mumbai` — Primary datacenter for our reminder keyspace
- `ap-south-1` — Secondary datacenter

Our clients are configured with `localDataCenter` to ensure operations are served from the nearest DC:

```
contactPoints: ['reminderkeyspace.prod.paytmdgt.io']
localDataCenter: 'mumbai'
```

Some clusters (like the new notification cluster) run exclusively in `ap-south-1`:

```
contactPoints: ['cass-remnotificationdb.prod.paytmdgt.io']
localDataCenter: 'ap-south-1'
```

---

## 16. Our Keyspace and Cluster Architecture

### Keyspaces

| Keyspace | Purpose | Client in Code |
|----------|---------|---------------|
| `reminder` | RU bill data in Cassandra, user agents, CT filters, customer scores, name details | `cassandraDbClient` |
| `reminder_non_ru` | Non-RU (non-Paytm) bill records — separate cluster for isolation | `nonRuCassandraDbClient` |
| `notification` | Notification cache, WhatsApp whitelists, notification logs, service capping counters | `notificationNewClusterClient` |
| `recharge_saga` | Recharge-to-customer mappings for plan validity | `rechargeSagaCassandraDb` |
| `recent` | Recent transactions and recents table for plan validity | `rechargeSagaCassandraDbRecentKeySpace` |

### Why multiple clusters?

1. **Workload isolation** — Notification writes (extremely high volume) don't compete with bill reads
2. **Independent scaling** — We can scale the notification cluster independently
3. **Failure isolation** — A problem with the notification cluster doesn't affect bill operations
4. **Different consistency needs** — Notification cache needs LOCAL_QUORUM; bill reads can tolerate ONE

### Client initialization pattern

Our startup sequence creates five Cassandra clients, each pointing to a specific cluster and keyspace. A simplified view of the flow:

```
config loading
  → create reminder client (keyspace: reminder)
  → create notification client on same cluster (keyspace: notification)
  → create non-RU client on new cluster (keyspace: reminder_non_ru)
  → create saga client (keyspace: recharge_saga)
  → create recent client (keyspace: recent)
  → create new notification cluster client (keyspace: notification, separate cluster)
```

All clients are injected via the `options` pattern into services and models.

---

## 17. Table Design Patterns We Use

### Pattern 1: Lookup Table (partition key = query key)

For simple key-value lookups:

```sql
-- User agent / blocked customers
SELECT customerid FROM user_agent WHERE customerid = ?

-- Customer score
SELECT * FROM customer_score WHERE customer_id = ?
```

Partition key IS the lookup key. Fast, single-partition read.

### Pattern 2: Composite Partition Key

When a single column doesn't provide enough cardinality or the query always specifies multiple columns:

```sql
-- Non-RU bills: always queried by all four columns
SELECT * FROM bills_non_paytm
WHERE recharge_number = ? AND customer_id = ? AND operator = ? AND service = ?
```

### Pattern 3: Partition Key + Clustering Key for Range Queries

When you need ordering within a partition:

```sql
-- Recent records: partition by customer, cluster by timestamp
SELECT * FROM bills_recent_records
WHERE customer_id = ? AND service = ?
```

### Pattern 4: Cache Tables with TTL

For temporary data that should auto-expire:

```sql
-- Notification cache with TTL
INSERT INTO notification_cache (...) VALUES (...) USING TTL ?

-- Payment cache with TTL
INSERT INTO bills_recent_cache (...) VALUES (...) USING TTL ?
```

### Pattern 5: Counter Tables for Rate Limiting

For atomic counting operations:

```sql
-- Notification capping: how many notifications sent today per service
UPDATE service_notification_capping
SET notification_count = notification_count + 1
WHERE service = ? AND date = ? AND type = ?
```

### Pattern 6: Map Columns for Flexible Data

For storing key-value pairs within a row:

```sql
-- Remind-later events: store arbitrary metadata as a map
UPDATE payment_remind_later_events USING TTL ?
SET remind_later_data[?] = ?
WHERE customer_id = ? AND service = ? AND operator = ?
```

Individual map entries can have different TTLs and be updated independently.

### Pattern 7: Table Resolver for Sharding

We use a `CustomTableResolver` to route queries to different physical tables based on customer ID range:

| Condition | Table |
|-----------|-------|
| `customerId <= INT_MAX` | `bills_non_paytm` |
| `customerId > INT_MAX` | `bills_non_ru_bigint` |

This is application-level sharding to handle the migration from integer to bigint customer IDs without schema changes.

### Pattern 8: Pagination with Token-Based Cursors

For scanning large tables (e.g., loading blocked user list into memory):

```javascript
// Using fetchSize and pageState for paginated reads
options = { prepare: true, fetchSize: 5000 }
// After each page, use result.pageState to fetch next page
```

This is how Cassandra handles pagination — not with OFFSET/LIMIT like SQL, but with opaque page state tokens.

---

## 18. Common Interview Questions

### Q1: How does Cassandra ensure high availability?

Cassandra uses a **peer-to-peer architecture** with no master node. Data is replicated across multiple nodes (replication factor). If a node goes down, other replicas serve the request. **Hinted handoff** stores writes temporarily when a node is unavailable, replaying them when it returns. **Read repair** fixes inconsistencies during reads. With RF=3 and consistency level QUORUM, you can tolerate 1 node failure per replication group without any data loss or downtime.

### Q2: Explain the difference between partition key and clustering key

The **partition key** determines data placement — which node stores the row. The **clustering key** determines sort order within a partition. Think of partition key as "which folder" and clustering key as "how files are sorted in that folder." You must always query by the full partition key. You can optionally filter by clustering columns, but only in their defined order (you can't skip a clustering column).

### Q3: When would you use LOCAL_QUORUM vs ONE?

Use **LOCAL_QUORUM** when you need strong consistency within your datacenter — for example, notification deduplication where sending a duplicate notification is costly. Use **ONE** for high-throughput, read-heavy workloads where occasional staleness is acceptable — like reading bill records where a slightly stale amount is fine and will be refreshed soon.

### Q4: What are tombstones and why are they problematic?

Tombstones are markers Cassandra writes when data is deleted or TTL expires. They exist because in a distributed system, you can't guarantee all replicas received the delete. Without tombstones, deleted data could be "resurrected" by a replica that missed the delete. They're problematic because reads must scan through them to find live data — too many tombstones cause slow reads, high memory usage, and potential query aborts.

### Q5: Why are Cassandra writes faster than reads?

Writes are append-only — they go to an in-memory memtable and a sequential commit log. No disk seeks, no read-before-write, no locking. Reads are more complex — they must check memtable, potentially multiple SSTables (requiring bloom filter checks, index lookups, and disk seeks), then merge results by timestamp.

### Q6: Explain Lightweight Transactions (LWT)

LWT provides conditional writes using the Paxos consensus protocol. `IF NOT EXISTS` prevents duplicate inserts; `IF condition` prevents conflicting updates. They guarantee linearizable consistency but at ~4x the latency of normal writes (due to Paxos prepare-promise-propose-accept rounds). Use sparingly — only when race conditions would cause business logic errors.

**Our example**: We use `UPDATE ... IF EXISTS` for non-RU bill mark-as-paid to prevent multiple consumers from conflicting on the same bill update.

### Q7: When should you NOT use Cassandra?

- When you need complex joins or aggregations (use a relational DB)
- When you need strong multi-row transactions (use MySQL/PostgreSQL)
- When you have small datasets that fit on one machine (overhead not justified)
- When your read patterns are unpredictable or ad-hoc (Cassandra requires query-first design)
- When you need to update and read the same data frequently with strict consistency (the eventually consistent model adds complexity)

### Q8: What is the difference between STCS, LCS, and TWCS compaction?

- **STCS (SizeTiered)** — Groups SSTables by size, merges when enough similar-sized SSTables exist. Good for write-heavy, bad for reads (many SSTables to scan). Default.
- **LCS (Leveled)** — Organizes into levels, each level 10x the previous. Guarantees most reads touch 1 SSTable. Good for reads, higher write amplification.
- **TWCS (TimeWindow)** — Groups by time window. Old windows are dropped entirely when all data expires. Ideal for time-series or TTL-heavy data. Our notification caches would benefit from this.

### Q9: How does Cassandra handle a network partition between datacenters?

Each DC continues to serve reads and writes independently (using LOCAL_QUORUM or lower consistency levels). Writes to unreachable DCs are stored as hints or replayed during repair. When connectivity is restored, anti-entropy repair synchronizes the data. This is the AP (Availability + Partition tolerance) side of the CAP theorem.

### Q10: What is the `prepare: true` option in queries?

Prepared statements send the CQL to Cassandra once, where it's parsed, validated, and the execution plan is cached. Subsequent executions only send the parameters. Benefits:
- Reduced parsing overhead on the server
- Better type safety (driver handles serialization)
- Protection against CQL injection
- Token-aware routing (driver knows which node owns the partition)

We use `{ prepare: true }` on virtually every query in our codebase.

### Q11: How do you model a one-to-many relationship in Cassandra?

Use the "one" side as the partition key and the "many" side as clustering columns. For example, one customer has many bills:

```sql
PRIMARY KEY ((customer_id), service, operator, recharge_number)
```

All bills for a customer are in one partition, sorted by service, operator, then recharge number. You can efficiently query "all bills for customer X" or "all electricity bills for customer X."

### Q12: What happens when you do a rolling restart of a Cassandra cluster?

With RF >= 2 and clients using LOCAL_QUORUM or lower, you can restart one node at a time with zero downtime. The driver detects the node is down, routes to other replicas, and reconnects when the node returns. We leverage this for deployments and maintenance.

### Q13: How would you handle a scenario where reads are slow?

Diagnostic steps:
1. Check **compaction** — too many SSTables mean more disk seeks per read
2. Check **tombstones** — excessive deletes or TTL-heavy tables with STCS
3. Check **partition size** — partitions > 100MB cause performance issues
4. Check **bloom filter** false positive rate — may need tuning
5. Check **consistency level** — QUORUM reads are slower than ONE
6. Check **read repair** — can add latency on inconsistent replicas
7. Consider **LCS** compaction if workload is read-heavy
8. Look at **hot partitions** — uneven data distribution

### Q14: Explain your multi-cluster architecture decision

We run separate Cassandra clusters for different workloads:
- **Reminder cluster** — Bill data with moderate writes, frequent reads
- **Non-RU cluster** — High-volume non-Paytm bill writes, isolated for performance
- **Notification cluster** — Extremely high write volume (every notification creates cache entries), needs LOCAL_QUORUM for dedup
- **Saga/Recent cluster** — Plan validity and recent transaction data

Separation provides workload isolation, independent scaling, and failure blast radius reduction. The tradeoff is operational complexity of managing multiple clusters.

### Q15: How do you handle schema changes in production?

Cassandra schema changes are eventually consistent — they propagate across nodes. Safe changes:
- `ALTER TABLE ADD column` — adding columns is safe, existing rows return NULL for the new column
- `CREATE INDEX` — safe but may trigger a full table rebuild

Dangerous changes:
- `ALTER TABLE DROP column` — data loss
- Changing partition key — requires creating a new table and migrating
- `ALTER TABLE ALTER column_type` — limited type changes supported

We never modify partition keys in production. If the query pattern changes, we create a new table and double-write during migration.

---

## Quick Reference: CQL vs SQL

| SQL Concept | CQL Equivalent | Key Difference |
|-------------|---------------|----------------|
| `DATABASE` | `KEYSPACE` | Includes replication strategy |
| `PRIMARY KEY` | `PRIMARY KEY ((part_key), clust_key)` | Two-level: partition + clustering |
| `AUTO_INCREMENT` | `UUID` or `TIMEUUID` | No sequences; use UUIDs |
| `JOIN` | Not supported | Denormalize instead |
| `GROUP BY` | Limited support | Pre-aggregate in application |
| `INDEX` | `SECONDARY INDEX` | Local per-node, not global |
| `TRANSACTION` | `BATCH` / `LWT` | No multi-row ACID |
| `NULL` | Absence of value | NULLs create tombstones on write |
| `ORDER BY` | Defined at table creation | Clustering order, not query-time |
| `OFFSET/LIMIT` | `fetchSize` + `pageState` | Token-based pagination |

---

*Prepared for interview reference. Based on Apache Cassandra concepts and real-world usage patterns from the digital-reminder microservice.*
