# MySQL Interview Preparation Guide

> A concept-first guide with real-world examples from the digital-reminder microservice. Covers fundamentals, advanced topics, and modern interview questions that are commonly asked in 2025-2026.

---

## Table of Contents

1. [InnoDB Storage Engine](#1-innodb-storage-engine)
2. [Indexing — The Most Asked Topic](#2-indexing--the-most-asked-topic)
3. [Query Execution Plan (EXPLAIN)](#3-query-execution-plan-explain)
4. [Master-Slave Replication](#4-master-slave-replication)
5. [Connection Pooling](#5-connection-pooling)
6. [Transactions and ACID](#6-transactions-and-acid)
7. [Locking — Row, Table, Gap, and Deadlocks](#7-locking--row-table-gap-and-deadlocks)
8. [INSERT ON DUPLICATE KEY UPDATE (Upsert)](#8-insert-on-duplicate-key-update-upsert)
9. [Parameterized Queries and SQL Injection](#9-parameterized-queries-and-sql-injection)
10. [Pagination — OFFSET vs Cursor](#10-pagination--offset-vs-cursor)
11. [Partitioning and Sharding](#11-partitioning-and-sharding)
12. [JOINs — Types, Performance, and When to Avoid](#12-joins--types-performance-and-when-to-avoid)
13. [Aggregations and GROUP BY](#13-aggregations-and-group-by)
14. [Slow Query Diagnosis](#14-slow-query-diagnosis)
15. [MySQL 8.0+ Modern Features](#15-mysql-80-modern-features)
16. [Our Architecture — How We Use MySQL](#16-our-architecture--how-we-use-mysql)
17. [Top 25 Interview Questions](#17-top-25-interview-questions)

---

## 1. InnoDB Storage Engine

### Concept

InnoDB is the default and most widely used MySQL storage engine. Understanding InnoDB internals is critical for interviews.

### Key characteristics

- **Row-level locking** — Multiple transactions can modify different rows in the same table simultaneously (unlike MyISAM which locks the entire table)
- **ACID compliant** — Full transaction support with commit, rollback, and crash recovery
- **MVCC (Multi-Version Concurrency Control)** — Readers don't block writers and writers don't block readers. Each transaction sees a snapshot of data at the time it started
- **Clustered index** — Data is physically stored in primary key order on disk. The primary key IS the data structure
- **Buffer Pool** — In-memory cache for frequently accessed data pages. The most important tuning parameter in MySQL

### How InnoDB stores data

```
InnoDB Architecture:
┌─────────────────────────────┐
│         Buffer Pool          │  ← In-memory cache (data + index pages)
├─────────────────────────────┤
│        Change Buffer         │  ← Buffers changes to secondary indexes
├─────────────────────────────┤
│      Redo Log (WAL)          │  ← Write-ahead log for crash recovery
├─────────────────────────────┤
│       Undo Logs              │  ← For rollback + MVCC read views
├─────────────────────────────┤
│    Tablespace (.ibd files)   │  ← Actual data on disk
└─────────────────────────────┘
```

### Buffer Pool — The single most important concept

The buffer pool is where InnoDB caches table data and index pages. When MySQL reads data, it first checks the buffer pool. If found (buffer pool hit), no disk I/O is needed. If not found (miss), a page is read from disk and cached.

**Interview tip**: Set `innodb_buffer_pool_size` to 70-80% of available RAM on a dedicated MySQL server. This is the #1 performance tuning parameter.

### Write-Ahead Logging (WAL)

Every change is first written to the **redo log** before the actual data files. If MySQL crashes:
1. On restart, InnoDB reads the redo log
2. Replays any changes that were committed but not yet written to data files
3. Rolls back any uncommitted transactions using the undo log

This guarantees **durability** — committed data is never lost even on crash.

---

## 2. Indexing — The Most Asked Topic

### Concept

An index is a separate data structure that allows MySQL to find rows without scanning the entire table. Think of it like a book's index — instead of reading every page, you look up the topic and jump to the page number.

### Types of Indexes

| Type | Description | When to Use |
|------|-------------|-------------|
| **Primary Key (Clustered)** | Data is stored in PK order. Only one per table. | Every table must have one |
| **Secondary Index** | Separate B+Tree that stores the indexed columns + primary key | Columns frequently in WHERE, JOIN, ORDER BY |
| **Composite Index** | Index on multiple columns | Queries that filter on multiple columns |
| **Unique Index** | Like secondary but enforces uniqueness | Natural unique constraints (email, phone) |
| **Covering Index** | Index contains all columns needed by query | Avoid reading the actual table row |
| **Full-Text Index** | Inverted index for text search | MATCH ... AGAINST queries |
| **Prefix Index** | Index on first N characters of a string | Long VARCHAR columns where full index is wasteful |

### B+Tree — How indexes actually work

MySQL indexes use a **B+Tree** structure:

```
              [50]                    ← Root node (one page)
             /    \
        [20,30]   [70,80]            ← Internal nodes
       /   |   \    |    \
   [10,15][20,25][30,40][70,75][80,90]  ← Leaf nodes (linked list)
```

- **Internal nodes** contain keys and pointers to child nodes
- **Leaf nodes** contain keys and pointers to actual data (for clustered index, leaf nodes ARE the data)
- **Leaf nodes are linked** — enabling efficient range scans
- **Tree depth is typically 3-4 levels** — meaning any row can be found in 3-4 disk reads

### The Clustered Index — Critical Concept

In InnoDB, the primary key index IS the table. The data rows are stored in the leaf nodes of the primary key B+Tree. This means:

1. Lookups by primary key are the fastest possible read (data is right there)
2. **Secondary indexes store the primary key value** (not a row pointer) — so a secondary index lookup requires two B+Tree traversals: one on the secondary index to find the PK, then one on the clustered index to find the actual row
3. This second traversal is called a **bookmark lookup** or **clustered index lookup**

### Composite Index and the Leftmost Prefix Rule

A composite index on `(A, B, C)` can be used for queries filtering on:
- `A` alone
- `A AND B`
- `A AND B AND C`

But NOT:
- `B` alone (leftmost column missing)
- `B AND C` (leftmost column missing)
- `A AND C` (B is skipped — only A part is used efficiently)

This is the **leftmost prefix rule** and is one of the most commonly asked index questions.

### Index hints — FORCE INDEX

Sometimes MySQL's query optimizer chooses the wrong index. You can override it:

```sql
SELECT * FROM bills_creditcard
FORCE INDEX (next_bill_fetch_date)
WHERE status NOT IN (7, 13)
  AND next_bill_fetch_date > '2026-03-01'
  AND next_bill_fetch_date < '2026-03-30'
  AND operator = 'HDFC Credit Card'
ORDER BY id ASC
LIMIT 1000
```

In our codebase, we use `FORCE INDEX` for the credit card publisher because the optimizer sometimes prefers the primary key index over the `next_bill_fetch_date` index, resulting in a full table scan on large tables.

**When to use FORCE INDEX**: Only when you've confirmed via EXPLAIN that MySQL is choosing a suboptimal plan, and only after analyzing table statistics.

---

## 3. Query Execution Plan (EXPLAIN)

### Concept

`EXPLAIN` shows you HOW MySQL will execute a query — which indexes it uses, how many rows it estimates to scan, and what join strategy it picks.

### Reading EXPLAIN output

```sql
EXPLAIN SELECT * FROM bills_airtel
WHERE status NOT IN (7, 13)
  AND next_bill_fetch_date > '2026-03-01'
  AND next_bill_fetch_date < '2026-03-30'
  AND operator = 'Airtel'
ORDER BY next_bill_fetch_date
LIMIT 1000;
```

Key columns to look at:

| Column | What It Means | Good Values | Bad Values |
|--------|--------------|-------------|------------|
| **type** | How rows are accessed | `const`, `eq_ref`, `ref`, `range` | `ALL` (full table scan) |
| **key** | Which index is used | An actual index name | `NULL` (no index) |
| **rows** | Estimated rows to examine | Small number | Millions |
| **Extra** | Additional info | `Using index` (covering) | `Using filesort`, `Using temporary` |

### Access types (best to worst)

1. **const** — One row, primary/unique key lookup (fastest)
2. **eq_ref** — One row per JOIN match via unique index
3. **ref** — Multiple rows via non-unique index
4. **range** — Index range scan (BETWEEN, >, <, IN)
5. **index** — Full index scan (reads every entry in the index)
6. **ALL** — Full table scan (worst — reads every row)

### "Using index" vs "Using index condition"

- **Using index** — The query is answered entirely from the index (covering index). No need to read the actual row. Optimal.
- **Using index condition** — Index Condition Pushdown (ICP). MySQL pushes WHERE conditions down to the storage engine to filter during index scan. Good.
- **Using filesort** — MySQL needs to sort results outside the index order. Can be expensive for large result sets.
- **Using temporary** — MySQL needs a temporary table. Common with GROUP BY or DISTINCT on non-indexed columns.

---

## 4. Master-Slave Replication

### Concept

MySQL replication copies data from one server (master/source) to one or more servers (slaves/replicas). The master handles writes; slaves handle reads. This provides:

1. **Read scaling** — Distribute read load across replicas
2. **High availability** — Promote a slave if master fails
3. **Backup** — Take backups from slave without impacting master
4. **Geographic distribution** — Slaves in different regions for lower latency

### How replication works

```
Master                          Slave
┌──────────┐    Binary Log     ┌──────────┐
│  Client   │ ──── write ────→ │  I/O     │
│  writes   │                  │  Thread  │
│           │   binlog events  │    ↓     │
│  Binary   │ ───────────────→ │  Relay   │
│  Log      │                  │  Log     │
└──────────┘                   │    ↓     │
                               │  SQL     │
                               │  Thread  │
                               │    ↓     │
                               │  Data    │
                               └──────────┘
```

1. Master writes changes to its **binary log** (binlog)
2. Slave's **I/O thread** reads binlog events from master
3. Events are written to the slave's **relay log**
4. Slave's **SQL thread** replays relay log events against the slave data

### Replication lag — The critical tradeoff

Replication is **asynchronous** by default. There is always some delay between a write on master and when it appears on slave. This means:

- A record just inserted on master may not be visible on slave yet
- If you write then immediately read from slave, you might get stale data
- Critical reads after writes should go to master

### Our master-slave setup

We explicitly route queries by cluster name:

- **Writes** → `DIGITAL_REMINDER_MASTER`, `RECHARGE_ANALYTICS`, `FS_RECHARGE_MASTER`
- **Reads** → `DIGITAL_REMINDER_SLAVE`, `RECHARGE_ANALYTICS_SLAVE`, `FS_RECHARGE_SLAVE1`

This is application-level read/write splitting. The developer decides which cluster to use per query. Example flow:

```
Publisher writes bill status       → DIGITAL_REMINDER_MASTER
Publisher reads fresh records      → DIGITAL_REMINDER_SLAVE
API reads bill for customer        → DIGITAL_REMINDER_SLAVE
API creates new bill               → DIGITAL_REMINDER_MASTER
```

### Semi-synchronous replication

In semi-sync replication, the master waits for at least one slave to acknowledge receipt of the binlog event before committing. This reduces the risk of data loss if the master crashes but adds latency to every write. Most production setups use this mode.

### Interview tip: What happens if the master crashes?

1. **Async replication**: Some committed transactions may be lost (exist only on master)
2. **Semi-sync replication**: At most one transaction can be lost (the one in-flight)
3. **Group Replication / InnoDB Cluster**: Consensus-based — no data loss, automatic failover

---

## 5. Connection Pooling

### Concept

Creating a new MySQL connection is expensive — TCP handshake, authentication, session setup. Connection pooling maintains a pool of reusable connections, eliminating this overhead.

### How it works

```
Application                     Pool                        MySQL
    │                            │                            │
    │── request connection ─────→│                            │
    │                            │── reuse existing ─────────→│
    │← return connection ────────│                            │
    │                            │                            │
    │── execute query ───────────│────────────────────────────→│
    │← results ──────────────────│←────────────────────────────│
    │                            │                            │
    │── release connection ─────→│                            │
    │                            │── return to pool ──────────│
```

### Key pooling parameters

| Parameter | Our Value | Meaning |
|-----------|----------|---------|
| `connectionLimit` | 5 (most), 10 (FS slaves) | Max connections in pool per cluster |
| `waitForConnections` | true | Queue requests when pool is full instead of erroring |
| `queueLimit` | 0 | Unlimited queue length |
| `acquireTimeout` | 120000ms (2 min) | Max time to wait for a free connection |

### Why connection limits matter

MySQL has a global `max_connections` setting (typically 150-500). If your application pool limit is 5 per cluster and you have 20 pods, that's 100 connections to master alone. Add slave connections and you can easily exhaust the limit.

**Interview tip**: Connection limit should be `(max_connections - reserved) / number_of_application_instances`.

### Our cluster routing

sqlwrap (our MySQL wrapper) implements cluster-based connection pooling. Each cluster name (like `DIGITAL_REMINDER_MASTER`) has its own pool. The application passes the cluster name on every query:

```javascript
dbInstance.exec(callback, 'DIGITAL_REMINDER_SLAVE', query, params)
```

This allows transparent failover within a cluster and wildcard routing (e.g., `FS_RECHARGE_SLAVE*` distributes reads across multiple slaves).

---

## 6. Transactions and ACID

### Concept

A transaction is a unit of work that is either fully completed or fully rolled back. ACID properties guarantee data integrity:

- **Atomicity** — All operations in a transaction succeed or all fail. No partial state.
- **Consistency** — A transaction moves the database from one valid state to another. Constraints, triggers, and cascades are respected.
- **Isolation** — Concurrent transactions don't see each other's intermediate states (depending on isolation level).
- **Durability** — Once committed, data survives crashes (via WAL/redo log).

### Isolation Levels (most asked in interviews)

| Level | Dirty Read | Non-Repeatable Read | Phantom Read | Performance |
|-------|-----------|-------------------|--------------|-------------|
| **READ UNCOMMITTED** | Yes | Yes | Yes | Fastest |
| **READ COMMITTED** | No | Yes | Yes | Fast |
| **REPEATABLE READ** (MySQL default) | No | No | Possible* | Good |
| **SERIALIZABLE** | No | No | No | Slowest |

*MySQL's InnoDB uses gap locking to prevent most phantom reads even at REPEATABLE READ.

### Understanding the anomalies

**Dirty Read**: Transaction A reads data that Transaction B has modified but not yet committed. If B rolls back, A read data that never existed.

**Non-Repeatable Read**: Transaction A reads a row, Transaction B modifies and commits that row, Transaction A reads again and gets a different value.

**Phantom Read**: Transaction A runs a range query and gets 10 rows. Transaction B inserts a new row in that range and commits. Transaction A reruns the same query and gets 11 rows.

### MVCC — How InnoDB avoids locking on reads

Instead of locking rows during reads, InnoDB maintains multiple versions of each row (via undo logs). Each transaction sees a snapshot:

- **REPEATABLE READ**: Transaction sees data as it was at the start of the transaction
- **READ COMMITTED**: Transaction sees data as it was at the start of each statement

This means readers never block writers, and writers never block readers — a massive performance advantage over lock-based isolation.

---

## 7. Locking — Row, Table, Gap, and Deadlocks

### Row Locks

InnoDB uses **row-level locking** (not table-level like MyISAM). Two types:

- **Shared lock (S)** — Multiple transactions can hold S locks on the same row. Used for `SELECT ... LOCK IN SHARE MODE`
- **Exclusive lock (X)** — Only one transaction can hold an X lock. Used for `UPDATE`, `DELETE`, `SELECT ... FOR UPDATE`

### Gap Locks and Next-Key Locks

To prevent phantom reads, InnoDB uses:

- **Gap lock** — Locks the gap between index records (prevents inserts in that range)
- **Next-key lock** — A combination of row lock + gap lock on the gap before it

Example: If index has values 10, 20, 30 and you do `WHERE id > 15 AND id < 25`, InnoDB locks:
- Gap (10, 20) — prevents insert of 11-19
- Record 20
- Gap (20, 30) — prevents insert of 21-29

### Deadlocks

A deadlock occurs when two transactions are each waiting for a lock the other holds:

```
Transaction A: Locks row 1, then tries to lock row 2 (waits...)
Transaction B: Locks row 2, then tries to lock row 1 (waits...)
→ DEADLOCK — neither can proceed
```

MySQL detects deadlocks automatically and rolls back one transaction (the one with less work done). The other transaction continues.

### How we handle deadlocks

In our plan validity model, we implement a deadlock retry pattern:

```javascript
// On ER_LOCK_DEADLOCK, retry the query once
if (error && error.code === 'ER_LOCK_DEADLOCK') {
    return self.retryOnDeadlock(query, params, callback);
}
```

**Interview tip**: Deadlocks are normal in high-concurrency systems. The solution is not to prevent all deadlocks but to:
1. Keep transactions short
2. Access tables in a consistent order
3. Use appropriate indexes (reduces lock scope)
4. Implement retry logic

---

## 8. INSERT ON DUPLICATE KEY UPDATE (Upsert)

### Concept

This MySQL-specific syntax combines INSERT and UPDATE in one atomic statement. If the INSERT would violate a unique key, it performs an UPDATE instead.

### Why it matters for us

In a bill reminder system, we frequently receive the same bill information from multiple sources. Instead of:
1. SELECT to check if record exists
2. If yes, UPDATE; if no, INSERT

(which has a race condition between step 1 and step 2)

We use a single atomic statement:

```sql
INSERT INTO bills_airtel
  (recharge_number, customer_id, operator, service, product_id, status, next_bill_fetch_date)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE
  operator = VALUES(operator),
  service = VALUES(service),
  product_id = VALUES(product_id),
  status = VALUES(status),
  next_bill_fetch_date = VALUES(next_bill_fetch_date)
```

### How it works internally

1. MySQL attempts the INSERT
2. If a **unique key** (primary or unique index) violation occurs:
   - The row is not inserted
   - Instead, the UPDATE clause is executed against the existing row
3. If no violation, the row is inserted normally

### Gotchas

- **Auto-increment**: Even if the UPDATE path is taken, the auto-increment counter is incremented (creates gaps)
- **Locking**: Acquires an exclusive lock on the existing row during the UPDATE path
- **VALUES() vs value**: `VALUES(column)` refers to the value that WOULD have been inserted. In MySQL 8.0.20+, this is deprecated in favor of aliases
- **Multiple unique keys**: If the table has multiple unique keys and the INSERT violates more than one, only one row is updated (the first match). This can cause unexpected behavior

### Bulk upsert pattern

For bulk operations, we build multi-row inserts:

```sql
INSERT INTO bills_prepaid
  (recharge_number, customer_id, operator, ...)
VALUES
  (?, ?, ?, ...),
  (?, ?, ?, ...),
  (?, ?, ?, ...)
ON DUPLICATE KEY UPDATE
  status = VALUES(status),
  next_bill_fetch_date = VALUES(next_bill_fetch_date)
```

This is significantly faster than individual upserts because it's one round-trip to the database instead of N.

---

## 9. Parameterized Queries and SQL Injection

### Concept

SQL injection is one of the most critical security vulnerabilities. It occurs when user input is directly concatenated into SQL strings:

```sql
-- DANGEROUS: String concatenation
"SELECT * FROM users WHERE name = '" + userInput + "'"

-- If userInput = "'; DROP TABLE users; --"
-- Resulting query: SELECT * FROM users WHERE name = ''; DROP TABLE users; --'
```

### Parameterized queries (prepared statements)

The solution is to separate SQL structure from data:

```sql
-- SAFE: Parameterized
"SELECT * FROM users WHERE name = ?"  params: [userInput]
```

The database treats `?` as a data placeholder, not as SQL code. No matter what the user inputs, it can never change the query structure.

### Our pattern

We use parameterized queries throughout the codebase:

```javascript
const query = 'SELECT * FROM ?? WHERE recharge_number = ? AND operator = ?';
const params = [tableName, rechargeNumber, operator];
dbInstance.exec(callback, 'DIGITAL_REMINDER_SLAVE', query, params);
```

- `?` — Value placeholder (automatically quoted/escaped)
- `??` — Identifier placeholder (for table/column names, escaped with backticks)

### Where to watch out

Areas that are vulnerable to injection (even in our codebase) include:
- String concatenation of WHERE clauses
- Dynamic table name construction without escaping
- Building IN clauses by joining arrays directly into SQL strings

**Interview tip**: Always use parameterized queries. OWASP lists SQL injection as one of the top 10 web application security risks. Even internal services should parameterize because data can flow from untrusted sources through Kafka or APIs.

---

## 10. Pagination — OFFSET vs Cursor

### The OFFSET problem

```sql
SELECT * FROM bills_airtel ORDER BY id LIMIT 1000 OFFSET 500000;
```

MySQL must read and discard 500,000 rows before returning the 1000 you actually want. As OFFSET grows, performance degrades linearly. For a table with millions of rows, this becomes unusable.

### Cursor-based pagination (Keyset pagination)

Instead of OFFSET, use the last seen value as a cursor:

```sql
-- First page
SELECT * FROM bills_airtel
WHERE next_bill_fetch_date > '2026-03-01'
  AND next_bill_fetch_date < '2026-03-30'
ORDER BY id ASC
LIMIT 1000;

-- Next page (using last id from previous page as cursor)
SELECT * FROM bills_airtel
WHERE next_bill_fetch_date > '2026-03-01'
  AND next_bill_fetch_date < '2026-03-30'
  AND id > 45678   -- last id from previous page
ORDER BY id ASC
LIMIT 1000;
```

### How we use cursor pagination

Our publisher service uses cursor-based pagination via `id > ?` to iterate through bill records:

```sql
SELECT * FROM bills_creditcard
FORCE INDEX (next_bill_fetch_date)
WHERE status NOT IN (7, 13)
  AND next_bill_fetch_date > ?
  AND next_bill_fetch_date < ?
  AND operator = ?
  AND id > ?               -- cursor from previous batch
ORDER BY id ASC
LIMIT ?
```

Each batch returns the next N records starting after the last processed ID. This is O(1) regardless of how deep into the table we are.

### When to use OFFSET vs Cursor

| Approach | When to Use |
|----------|------------|
| **OFFSET** | Small tables, UI pagination with page numbers, total count needed |
| **Cursor** | Large tables, infinite scroll, batch processing, background jobs |

---

## 11. Partitioning and Sharding

### Table Partitioning (MySQL native)

MySQL can split a single logical table into multiple physical partitions:

- **RANGE partitioning** — By value ranges (e.g., by date: Jan data in partition p1, Feb in p2)
- **LIST partitioning** — By discrete values (e.g., by region)
- **HASH partitioning** — By hash of a column (even distribution)
- **KEY partitioning** — Like hash but MySQL chooses the hash function

Benefits:
- Query pruning — only relevant partitions are scanned
- Easier data management — drop an entire partition instead of DELETE
- Parallel query execution on different partitions

### Application-level sharding (what we do)

We shard at the application level by operator. Each operator's bills go to a different table:

| Operator | Table |
|----------|-------|
| Airtel | `bills_airtel` |
| Vodafone | `bills_vodafone` |
| Credit Card | `bills_creditcard` |
| Airtel Prepaid | `bills_airtelprepaid0` through `bills_airtelprepaid9` |

The CVR (Catalog Vertical Recharge) registry maps product IDs to table names. This gives us:

1. **Workload isolation** — A heavy Airtel publisher doesn't affect credit card queries
2. **Independent scaling** — Tables can be on different storage
3. **Simpler indexing** — Each table is smaller, indexes fit in memory
4. **Operational flexibility** — Can archive/rebuild one operator's table without touching others

For Airtel prepaid, we further shard into 10 tables (0-9) based on a hash of the recharge number, because Airtel prepaid has the highest volume.

### Application-level table routing

We use a `CustomTableResolver` pattern that routes to different tables based on customer ID ranges:

| Condition | MySQL Table |
|-----------|------------|
| Standard customer ID | `bills_<operator>` |
| Airtel prepaid shard | `bills_airtelprepaid<0-9>` |

This is pure application logic — MySQL sees them as independent tables.

---

## 12. JOINs — Types, Performance, and When to Avoid

### Types of JOINs

| Type | Returns |
|------|---------|
| **INNER JOIN** | Only rows that match in both tables |
| **LEFT JOIN** | All rows from left table + matches from right (NULL if no match) |
| **RIGHT JOIN** | All rows from right table + matches from left |
| **CROSS JOIN** | Cartesian product of both tables (every row with every row) |

### How MySQL executes JOINs

MySQL uses the **Nested Loop Join** algorithm (with variations):

1. **Simple Nested Loop**: For each row in table A, scan all rows in table B. O(n*m). Terrible.
2. **Block Nested Loop (BNL)**: Read a block of rows from A into memory, then scan B comparing against the entire block. Better.
3. **Index Nested Loop**: For each row in table A, use an index on table B to find matches. O(n*log(m)). Best for indexed JOINs.
4. **Hash Join** (MySQL 8.0.18+): Build a hash table from the smaller table, probe with the larger table. O(n+m). Used when no index is available.

### Our JOIN usage

We use JOINs sparingly. The main example is for IPL match predictions:

```sql
SELECT p.id, p.customer_id, p.match_id, p.predicted_team_code,
       m.match_date, m.team1_code, m.team2_code, m.match_status
FROM ipl_match_predictions p
LEFT JOIN ipl_match_schedule m ON p.match_id = m.match_id
WHERE p.customer_id = ?
ORDER BY m.match_date_time ASC
```

We use LEFT JOIN here because we want all predictions even if the match schedule hasn't been populated yet.

### Why we mostly avoid JOINs

For our core bill processing, we avoid JOINs because:
1. **Sharded tables** — Bill tables are per-operator, JOINing across them is impractical
2. **Performance at scale** — Our bill tables have millions of rows; JOINs would be slow
3. **Simplicity** — Denormalized data in one table means faster reads and simpler queries
4. **Microservice boundary** — Data that would traditionally be JOINed often lives in different services

**Interview tip**: In modern microservice architectures, JOINs at the database level are increasingly replaced by application-level data composition or denormalization.

---

## 13. Aggregations and GROUP BY

### Concept

Aggregation functions (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`) compute a single value from multiple rows. `GROUP BY` partitions results into groups, with each group getting its own aggregate.

### How MySQL processes GROUP BY

1. **Using index** — If the GROUP BY columns match an index prefix, MySQL can group without sorting. Fastest.
2. **Using temporary + filesort** — MySQL creates a temporary table, sorts data, then groups. Slower.

### Our aggregation usage

For daily reports, we aggregate bill processing statistics:

```sql
SELECT operator,
       COUNT(*) as total,
       AVG(DATEDIFF(NOW(), bill_fetch_date)) as avg_age
FROM bills_airtel
WHERE published_date BETWEEN ? AND ?
GROUP BY operator
```

For notification reports, we use conditional counting:

```sql
SELECT product_id,
       COUNT(CASE WHEN status = 'SENT' THEN 1 END) as sent_count,
       COUNT(CASE WHEN status = 'FAILED' THEN 1 END) as failed_count,
       COUNT(CASE WHEN status = 'PENDING' THEN 1 END) as pending_count
FROM notification
WHERE send_at >= ? AND send_at <= NOW()
GROUP BY product_id
```

This pattern avoids multiple queries — one pass through the data gives us all status breakdowns.

### Performance tips for GROUP BY

- Ensure GROUP BY columns are indexed (especially the leftmost prefix)
- Add a WHERE clause to reduce the dataset before grouping
- Consider materialized summaries (pre-computed tables updated periodically) for dashboards
- In MySQL 8.0+, use window functions instead of self-joins for running totals

---

## 14. Slow Query Diagnosis

### Step-by-step diagnosis process

**Step 1: Enable slow query log**

```sql
SET GLOBAL slow_query_log = 1;
SET GLOBAL long_query_time = 1;  -- log queries taking > 1 second
```

**Step 2: Identify the slow query**

Check the slow query log or use `SHOW PROCESSLIST` for currently running queries.

**Step 3: EXPLAIN the query**

Run `EXPLAIN` and look for red flags:
- `type: ALL` — full table scan
- `rows` — very large number
- `Extra: Using filesort` or `Using temporary`
- `key: NULL` — no index used

**Step 4: Common causes and fixes**

| Cause | Symptom | Fix |
|-------|---------|-----|
| Missing index | `type: ALL`, `key: NULL` | Add appropriate index |
| Wrong index chosen | Index exists but not used | Use FORCE INDEX or add composite index |
| Large OFFSET | Query takes longer for later pages | Switch to cursor pagination |
| Too many rows in result | `rows` is millions | Add WHERE conditions or LIMIT |
| Lock contention | Query hangs, not slow | Check `SHOW ENGINE INNODB STATUS` for lock waits |
| Unoptimized subquery | Dependent subquery in EXPLAIN | Rewrite as JOIN |
| Missing covering index | Frequent bookmark lookups | Add columns to index to make it covering |
| Stale statistics | Optimizer makes bad decisions | Run `ANALYZE TABLE` |
| Buffer pool too small | High disk I/O | Increase `innodb_buffer_pool_size` |

**Step 5: Validate with EXPLAIN after fix**

Always re-run EXPLAIN after adding an index or modifying a query to confirm the improvement.

---

## 15. MySQL 8.0+ Modern Features

### Window Functions

Perform calculations across a set of rows related to the current row, without collapsing into groups:

```sql
-- Running total of notifications per day
SELECT date, count,
       SUM(count) OVER (ORDER BY date) as running_total
FROM daily_notification_counts;

-- Rank operators by bill volume
SELECT operator, bill_count,
       RANK() OVER (ORDER BY bill_count DESC) as rank
FROM operator_summary;
```

### Common Table Expressions (CTEs)

Named temporary result sets for readability:

```sql
WITH high_value_bills AS (
    SELECT customer_id, operator, amount
    FROM bills_airtel
    WHERE amount > 1000 AND status = 4
)
SELECT customer_id, COUNT(*) as bill_count
FROM high_value_bills
GROUP BY customer_id
HAVING bill_count > 5;
```

Recursive CTEs can traverse hierarchical data (org charts, categories).

### JSON Support

MySQL 8.0 has native JSON column type with operators:

```sql
-- Store flexible data as JSON
ALTER TABLE bills ADD COLUMN extra JSON;

-- Query JSON fields
SELECT * FROM bills WHERE JSON_EXTRACT(extra, '$.isPrepaid') = '1';
SELECT * FROM bills WHERE extra->'$.isPrepaid' = '1';  -- shorthand
```

### Hash Joins

Before 8.0.18, JOINs without indexes used nested loop (very slow). Now MySQL automatically uses hash joins — builds a hash table from the smaller table and probes with the larger one.

### Descending Indexes

Before 8.0, MySQL stored indexes only in ascending order. `DESC` index scans were reverse scans (slower). Now you can create true descending indexes:

```sql
CREATE INDEX idx_recent ON bills (operator, created_at DESC);
```

### Invisible Indexes

Test the impact of dropping an index without actually dropping it:

```sql
ALTER TABLE bills ALTER INDEX idx_status INVISIBLE;
-- Test performance, if it degrades:
ALTER TABLE bills ALTER INDEX idx_status VISIBLE;
```

### Instant DDL

Adding a column no longer rebuilds the table:

```sql
ALTER TABLE bills ADD COLUMN new_flag TINYINT DEFAULT 0, ALGORITHM=INSTANT;
```

This takes milliseconds regardless of table size.

---

## 16. Our Architecture — How We Use MySQL

### Database Clusters

| Cluster | Database | Purpose | Typical Tables |
|---------|----------|---------|---------------|
| `DIGITAL_REMINDER_MASTER` | `digital_reminder` | Bill writes, status updates | `bills_*`, `notification`, `digital_reminder_config` |
| `DIGITAL_REMINDER_SLAVE` | `digital_reminder` | Bill reads, publisher queries | Same tables (read replicas) |
| `RECHARGE_ANALYTICS` | `recharge_analytics` | Legacy bill writes | `bills`, `plan_validity` |
| `RECHARGE_ANALYTICS_SLAVE` | `recharge_analytics` | Plan validity reads | Same tables |
| `FS_RECHARGE_MASTER` | `fs_recharge` | Product catalog writes | `catalog_vertical_recharge` |
| `FS_RECHARGE_SLAVE*` | `fs_recharge` | Product catalog reads | Same tables |
| `OPERATOR_SYNC` / `_SLAVE` | `operator_sync` | VIL/plan sync | Operator-specific tables |

### Why MySQL AND Cassandra?

| Requirement | MySQL | Cassandra |
|-------------|-------|-----------|
| Complex publisher queries with date ranges, status filters, ORDER BY | Best choice | Poor (requires ALLOW FILTERING) |
| ACID transactions for bill status updates | Full support | LWT only (slow) |
| Aggregation reports (COUNT, AVG, GROUP BY) | Native support | Not supported |
| High-volume notification cache writes | Bottlenecks | Designed for this |
| Non-RU bills (billions of records, simple lookups) | Sharding painful | Natural fit |
| Time-based data expiry (TTL) | Manual cleanup jobs | Native TTL |

### Our query access patterns

**Publisher flow (read-heavy on SLAVE)**:
- Fetch fresh records with date range + status filter + cursor pagination
- FORCE INDEX for optimal plan on large tables
- Batch size controlled dynamically

**Subscriber flow (write-heavy on MASTER)**:
- Upsert bill records (INSERT ON DUPLICATE KEY UPDATE)
- Update bill status after processing
- Update next_bill_fetch_date for scheduling

**API flow (mixed)**:
- Read bill by customer + operator from SLAVE
- Create/update bills on MASTER
- Mark-as-paid on MASTER

### Cluster failover settings

```
canRetry: true              — Auto-retry on transient failures
restoreNodeTimeout: 3000    — Wait 3s before trying a failed node again
removeNodeErrorCount: 10000 — Remove node from pool after 10K consecutive errors
```

---

## 17. Top 25 Interview Questions

### Q1: What is the difference between InnoDB and MyISAM?

| Feature | InnoDB | MyISAM |
|---------|--------|--------|
| Locking | Row-level | Table-level |
| Transactions | Yes (ACID) | No |
| Foreign keys | Yes | No |
| Crash recovery | Yes (redo log) | No |
| MVCC | Yes | No |
| Full-text index | Yes (5.6+) | Yes |
| Storage | Clustered index | Heap |
| Use case | OLTP, concurrent writes | Read-heavy analytics (legacy) |

InnoDB is the default and recommended for virtually all use cases since MySQL 5.5.

### Q2: Explain the difference between clustered and non-clustered index

**Clustered index**: The data IS the index. Rows are physically stored in primary key order. Only one per table (the primary key). A lookup by PK requires one B+Tree traversal.

**Non-clustered (secondary) index**: A separate B+Tree that stores indexed columns + the primary key. A lookup requires two B+Tree traversals — one on the secondary index to find the PK, then one on the clustered index to find the row. This second step is called a "bookmark lookup."

### Q3: What is a covering index?

An index that contains ALL columns needed by a query. MySQL can answer the query entirely from the index without accessing the table data. In EXPLAIN, this shows as `Using index`.

Example: If you have `INDEX(operator, status)` and your query is:
```sql
SELECT operator, status FROM bills WHERE operator = 'Airtel'
```
The index covers the query — no table access needed.

### Q4: Explain MVCC and how it enables concurrent access

InnoDB maintains multiple versions of each row using undo logs. When a transaction modifies a row, the old version is preserved. Other transactions reading that row see the version that was current when their transaction (or statement) started. This means readers never block writers and writers never block readers. Each isolation level determines which version a transaction sees.

### Q5: What is a deadlock and how do you handle it?

A deadlock occurs when two or more transactions hold locks that the others need, creating a circular wait. MySQL detects deadlocks automatically and rolls back the smaller transaction (victim). Handling strategies:
1. Keep transactions short and small
2. Access tables in consistent order across all code paths
3. Use proper indexes to minimize lock scope
4. Implement retry logic in the application

### Q6: Explain the difference between REPEATABLE READ and READ COMMITTED

**REPEATABLE READ** (MySQL default): Transaction sees a snapshot taken at the start of the FIRST read statement. All subsequent reads see the same snapshot, even if other transactions commit changes. Uses gap locks to prevent phantoms.

**READ COMMITTED**: Each statement sees the latest committed data at the moment it executes. No gap locks. Better concurrency but allows non-repeatable reads.

### Q7: How does replication work and what is replication lag?

Master writes changes to binary log. Slave's I/O thread fetches binlog events and writes them to relay log. Slave's SQL thread replays relay log events. **Replication lag** is the time difference between a write on master and when it's available on slave. It occurs because replication is asynchronous — the slave may be seconds behind the master. Critical reads after writes should go to master.

### Q8: What is the difference between DELETE, TRUNCATE, and DROP?

| Command | What it does | Logging | Rollback | Speed |
|---------|-------------|---------|----------|-------|
| `DELETE` | Removes rows one by one | Row-level (slow) | Yes | Slow |
| `TRUNCATE` | Removes all rows, resets table | DDL (minimal) | No | Fast |
| `DROP` | Removes entire table + schema | DDL | No | Instant |

`DELETE WHERE ...` can remove specific rows and fires triggers. `TRUNCATE` removes everything and resets auto-increment. Neither drops the table structure.

### Q9: How do you optimize a slow SELECT query?

1. Run `EXPLAIN` to identify the access pattern
2. Add appropriate indexes (covering the WHERE, JOIN, ORDER BY columns)
3. Ensure leftmost prefix rule is satisfied for composite indexes
4. Use cursor pagination instead of large OFFSET
5. Limit the result set (don't SELECT * if you only need 3 columns)
6. Check for lock contention if the query hangs
7. Consider partitioning for very large tables
8. Ensure statistics are up to date (`ANALYZE TABLE`)
9. Check buffer pool hit rate — increase `innodb_buffer_pool_size` if needed

### Q10: What is the N+1 query problem?

When your application fetches a list of N items, then makes N individual queries to fetch related data for each item. Example:

```
SELECT * FROM customers;              -- 1 query, returns 100 customers
SELECT * FROM bills WHERE cust=1;     -- 100 queries, one per customer
SELECT * FROM bills WHERE cust=2;
...
```

Total: 101 queries instead of:
```
SELECT * FROM customers;
SELECT * FROM bills WHERE cust IN (1,2,3,...100);  -- 2 queries total
```

Or a single JOIN.

### Q11: What is the difference between WHERE and HAVING?

`WHERE` filters rows BEFORE grouping. `HAVING` filters groups AFTER aggregation.

```sql
SELECT operator, COUNT(*) as cnt FROM bills
WHERE status = 4              -- filter rows first (can use indexes)
GROUP BY operator
HAVING cnt > 100;             -- filter groups after counting
```

You cannot use aggregate functions in WHERE. Use HAVING for post-aggregation filtering.

### Q12: Explain INSERT ON DUPLICATE KEY UPDATE vs REPLACE INTO

**ON DUPLICATE KEY UPDATE**: On key conflict, updates the existing row. The row retains its primary key and auto-increment value. One INSERT or one UPDATE — never both.

**REPLACE INTO**: On key conflict, DELETES the existing row then INSERTS a new one. The row gets a new auto-increment value. Triggers ON DELETE + ON INSERT. Dangerous because it cascades foreign key deletes.

Always prefer ON DUPLICATE KEY UPDATE unless you specifically want replacement semantics.

### Q13: How would you handle a table with 500 million rows?

1. **Partitioning** — RANGE partition by date or HASH by ID
2. **Application-level sharding** — Split into multiple tables by a key (like our per-operator tables)
3. **Archival** — Move old records to archive tables
4. **Indexing** — Ensure all query paths have optimal indexes
5. **Read replicas** — Scale reads across slaves
6. **Cursor pagination** — Never use OFFSET for deep pages
7. **Consider Cassandra** — For simple key-lookup patterns at this scale

### Q14: What is a composite index and when would you use it?

A composite index indexes multiple columns in order. Use when queries filter on multiple columns together. The column order matters:
- Put equality conditions first, range conditions last
- Put highest-cardinality columns first (within equality group)
- Match the ORDER BY column order

Example: For `WHERE operator = ? AND status IN (0,2) AND next_bill_fetch_date > ?`:
Best index: `(operator, status, next_bill_fetch_date)`

### Q15: What are the pros and cons of UUID vs auto-increment as primary key?

| Aspect | Auto-increment | UUID |
|--------|---------------|------|
| Size | 4-8 bytes | 16 bytes (36 as string) |
| Insert performance | Sequential, cache-friendly | Random, causes page splits |
| Replication | Can conflict across masters | Globally unique |
| Predictability | Sequential (security risk) | Random (no guessing) |
| Index size | Smaller | Larger (affects all secondary indexes) |

For InnoDB, auto-increment is generally preferred because sequential inserts are much more efficient with the clustered index. UUIDs cause random inserts that fragment the B+Tree.

### Q16: Explain the difference between CHAR and VARCHAR

**CHAR(N)**: Fixed-length. Always stores exactly N characters (padded with spaces). Faster for fixed-size data. Uses N bytes (latin1) or N*3 bytes (utf8).

**VARCHAR(N)**: Variable-length. Stores actual data + 1-2 bytes for length prefix. More space-efficient for varying lengths.

Use CHAR for fixed-size data (country codes, status flags). Use VARCHAR for everything else.

### Q17: What is a transaction log and why is it important?

InnoDB uses two types of logs:
- **Redo log (WAL)**: Records what changes were made. Used for crash recovery — replays committed changes not yet written to data files. Provides durability.
- **Undo log**: Records how to reverse changes. Used for rollback and MVCC read views. Provides atomicity and isolation.

Together, they guarantee ACID compliance even during crashes.

### Q18: How does MySQL handle concurrent writes to the same row?

Through **row-level exclusive locks**. When Transaction A updates row X, it acquires an exclusive lock. If Transaction B tries to update the same row, it waits until A commits or rolls back. This serializes writes to the same row while allowing concurrent writes to different rows.

With MVCC, Transaction B can still READ the old version of row X while waiting to write — readers and writers don't block each other.

### Q19: What is query cache and why was it removed in MySQL 8.0?

Query cache stored the exact text of SELECT queries and their results. If the same query came again, results were returned from cache. It was removed because:
1. Single global mutex — became a bottleneck on multi-core servers
2. Invalidated on ANY write to the table — even if the write didn't affect cached query results
3. High-concurrency workloads spent more time managing the cache than it saved
4. Application-level caching (Redis, Memcached) is more flexible and effective

### Q20: Explain the difference between horizontal and vertical scaling

**Vertical scaling (scale up)**: Add more CPU, RAM, SSD to the existing server. Simpler but has physical limits and is expensive.

**Horizontal scaling (scale out)**: Add more servers. For MySQL:
- Read replicas for read scaling
- Sharding for write scaling
- ProxySQL or application-level routing

Our approach: Vertical for masters (bigger instances), horizontal for reads (multiple slaves), application-level sharding for write distribution (per-operator tables).

### Q21: What is the difference between pessimistic and optimistic locking?

**Pessimistic**: Lock the row BEFORE reading it, preventing others from modifying it. Uses `SELECT ... FOR UPDATE`. Assumes conflicts are likely.

**Optimistic**: Read without locking, check for conflicts at write time using a version column or timestamp. Retry on conflict. Assumes conflicts are rare.

MySQL natively uses pessimistic locking (InnoDB row locks). Optimistic locking is implemented at the application level.

### Q22: How do you handle schema migrations in production?

1. **Always additive first**: ADD COLUMN before modifying existing columns
2. **Use online DDL**: MySQL 8.0 `ALGORITHM=INSTANT` for adding columns
3. **Backward compatible**: New code handles both old and new schema
4. **pt-online-schema-change**: Percona tool for zero-downtime ALTER TABLE on large tables
5. **Blue-green deployment**: Run old and new code simultaneously during migration
6. **Never rename/drop columns** in the same deploy as code changes

### Q23: What is the binary log and its formats?

The binlog records all changes to data. Used for replication and point-in-time recovery.

Three formats:
- **STATEMENT**: Logs the SQL statement. Compact but non-deterministic functions (NOW(), RAND()) may produce different results on slave.
- **ROW**: Logs the actual row changes. Larger but deterministic and safe. Default since 5.7.7.
- **MIXED**: Uses STATEMENT normally, switches to ROW for non-deterministic statements.

### Q24: What is the difference between a stored procedure and a function?

| Aspect | Stored Procedure | Function |
|--------|-----------------|----------|
| Return | Zero or more via OUT params | Exactly one value |
| Use in SQL | CALL procedure() | Can use in SELECT, WHERE |
| Transactions | Can manage transactions | Cannot manage transactions |
| DML | Can modify data | Should not modify data |

Modern practice: Avoid stored procedures in microservice architectures. Keep business logic in application code where it's version-controlled and testable.

### Q25: How would you design a database for a bill reminder system?

This is an open-ended design question. Key considerations:

1. **Separate tables per operator** — Workload isolation, independent scaling
2. **Master-slave replication** — Read scaling for publisher queries
3. **Composite indexes** — On `(operator, status, next_bill_fetch_date)` for publisher scans
4. **Cursor pagination** — `id > last_id ORDER BY id LIMIT N` for batch processing
5. **Upsert pattern** — ON DUPLICATE KEY UPDATE for idempotent bill creation
6. **Cassandra for non-relational patterns** — Notification caches, non-RU bills, TTL data
7. **Connection pooling** — Bounded per-cluster pools to prevent connection exhaustion
8. **Deadlock handling** — Retry logic for concurrent bill updates
9. **Archival strategy** — Move old records to archive tables to keep active tables lean

---

## Quick Reference: MySQL vs PostgreSQL (Common Interview Comparison)

| Feature | MySQL (InnoDB) | PostgreSQL |
|---------|---------------|------------|
| MVCC implementation | Undo log based | Heap-based (old versions in same table) |
| Vacuum needed | No | Yes (VACUUM to reclaim space) |
| Replication | Binlog-based, async/semi-sync | WAL-based, streaming, logical |
| JSON support | JSON column, limited operators | JSONB (binary, indexed, richer operators) |
| Partitioning | RANGE, LIST, HASH, KEY | Declarative (10+), table inheritance |
| Full-text search | Basic | Advanced with tsvector |
| Stored procedures | Limited language | PL/pgSQL, PL/Python, PL/V8, etc. |
| Clustering | Group Replication, InnoDB Cluster | Patroni, Citus, pgpool |
| Best for | Web apps, read-heavy, replication | Complex queries, analytics, extensibility |

---

*Prepared for interview reference. Based on MySQL 8.0 concepts and real-world usage patterns from the digital-reminder microservice.*
