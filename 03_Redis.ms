# Redis Interview Preparation Guide

> A concept-first guide with real-world examples from the digital-reminder microservice. Covers fundamentals, advanced patterns, and how we migrated some Redis workloads to Cassandra — including the reasoning behind it.

---

## Table of Contents

1. [What is Redis and Why It Exists](#1-what-is-redis-and-why-it-exists)
2. [Data Structures — Redis's Superpower](#2-data-structures--rediss-superpower)
3. [Persistence — RDB vs AOF](#3-persistence--rdb-vs-aof)
4. [Expiry and TTL](#4-expiry-and-ttl)
5. [Redis Sentinel — High Availability](#5-redis-sentinel--high-availability)
6. [Redis Cluster — Horizontal Scaling](#6-redis-cluster--horizontal-scaling)
7. [Caching Patterns](#7-caching-patterns)
8. [Cache Invalidation Strategies](#8-cache-invalidation-strategies)
9. [Distributed Locking with Redis](#9-distributed-locking-with-redis)
10. [Pub/Sub Messaging](#10-pubsub-messaging)
11. [Pipelining and Transactions](#11-pipelining-and-transactions)
12. [Memory Management and Eviction](#12-memory-management-and-eviction)
13. [Redis Streams](#13-redis-streams)
14. [Our Architecture — How We Use Redis](#14-our-architecture--how-we-use-redis)
15. [Why We Migrated From Redis to Cassandra](#15-why-we-migrated-from-redis-to-cassandra)
16. [Redis vs Cassandra — When to Use Which](#16-redis-vs-cassandra--when-to-use-which)
17. [Top 25 Interview Questions](#17-top-25-interview-questions)

---

## 1. What is Redis and Why It Exists

### Concept

Redis (Remote Dictionary Server) is an **in-memory** key-value data store. It keeps all data in RAM, which makes it extremely fast — typical latency is under 1 millisecond for most operations. It can also optionally persist data to disk.

### Why Redis over a traditional database for caching?

| Aspect | MySQL / Cassandra | Redis |
|--------|------------------|-------|
| Storage | Disk-based | In-memory (RAM) |
| Latency | 1-10ms (with index) | Sub-millisecond |
| Data model | Tables/rows or wide-columns | Key-value with rich data structures |
| Persistence | Primary storage | Optional (cache-first) |
| Capacity | Terabytes | Limited by RAM (typically GB range) |
| Best for | Durable storage of record | Hot data that needs blazing-fast access |

### Common use cases

- **Caching** — Store frequently accessed data to reduce database load
- **Session storage** — User sessions with automatic expiry
- **Rate limiting** — Track API call counts with TTL
- **Distributed locking** — Coordinate access across multiple service instances
- **Pub/Sub** — Lightweight real-time messaging between services
- **Counters and leaderboards** — Atomic increment/decrement operations
- **Queue** — Simple task queues using lists
- **Deduplication** — "Have I seen this before?" with SET + TTL

### Single-threaded model

Redis processes commands in a **single thread** using an event loop. This means:
- No locking overhead — every command is atomic by nature
- No race conditions within Redis itself
- Throughput is high because there's zero context-switching cost
- The bottleneck is usually network I/O, not CPU

This is counter-intuitive but works because most Redis operations are O(1) or O(log N) and complete in microseconds. A single thread processing 100K+ operations per second is faster than multi-threaded approaches with locking overhead.

---

## 2. Data Structures — Redis's Superpower

### Why data structures matter

Redis isn't just a key-value store — it's a **data structure server**. Each value can be a rich data type, and Redis provides atomic operations on each type. This is what separates Redis from simpler caches like Memcached.

### String

The simplest type. A key maps to a value (up to 512MB). Can store text, numbers, or serialized JSON.

```
SET user:1234:name "Rupesh Kumar"
GET user:1234:name → "Rupesh Kumar"

SET counter 100
INCR counter → 101      (atomic increment)
INCRBY counter 5 → 106  (atomic increment by N)

SETEX session:abc 3600 "user_data"  (set with 1-hour TTL)
```

**Our usage**: We store JSON-serialized state objects as strings. For example, the Airtel publisher stores its daily processing state as a JSON string with a 24-hour TTL.

### Hash

A key maps to a collection of field-value pairs. Think of it as a nested object or a mini-record.

```
HSET user:1234 name "Rupesh" age 30 city "Delhi"
HGET user:1234 name → "Rupesh"
HGETALL user:1234 → {name: "Rupesh", age: "30", city: "Delhi"}
HINCRBY user:1234 age 1 → 31  (increment a single field)
```

**When to use**: When you need to read/update individual fields without fetching/rewriting the entire value. Saves bandwidth and avoids race conditions on partial updates.

### List

An ordered sequence of strings. Supports push/pop from both ends (doubly linked list).

```
LPUSH queue:tasks "task1" "task2"
RPOP queue:tasks → "task1"  (FIFO queue: push left, pop right)

LRANGE queue:tasks 0 -1 → all items
LLEN queue:tasks → count
```

**Use case**: Simple message queues, activity feeds, recent items list.

### Set

An unordered collection of unique strings. Supports set operations (union, intersection, difference).

```
SADD online:users "user1" "user2" "user3"
SISMEMBER online:users "user2" → 1 (true)
SMEMBERS online:users → {"user1", "user2", "user3"}

SINTER online:users premium:users → users who are both online AND premium
```

**Use case**: Tagging, tracking unique visitors, feature flags per user.

### Sorted Set (ZSet)

Like a set but each member has a **score**. Members are ordered by score. Supports range queries by score or rank.

```
ZADD leaderboard 100 "user1" 200 "user2" 150 "user3"
ZRANGE leaderboard 0 -1 WITHSCORES → user1(100), user3(150), user2(200)
ZRANGEBYSCORE leaderboard 100 200 → members with score between 100-200
ZRANK leaderboard "user2" → 2 (0-indexed position)
```

**Use case**: Leaderboards, priority queues, time-series with timestamps as scores, rate limiting with sliding windows.

### HyperLogLog

A probabilistic data structure for counting unique elements with minimal memory (~12KB regardless of count).

```
PFADD unique:visitors "user1" "user2" "user3" "user1"
PFCOUNT unique:visitors → 3 (approximate unique count)
```

**Use case**: Counting unique visitors, unique events — when you need cardinality estimation, not exact counts.

### Bitmap

Bit-level operations on strings. Each bit position represents a flag.

```
SETBIT daily:active:20260413 1234 1    (user 1234 was active on April 13)
GETBIT daily:active:20260413 1234 → 1
BITCOUNT daily:active:20260413 → total active users
BITOP AND weekly:active daily:active:20260407 daily:active:20260408 ...
```

**Use case**: Feature flags, daily active user tracking, bloom filter implementations.

---

## 3. Persistence — RDB vs AOF

### The fundamental question

Redis keeps data in memory. What happens if the server crashes? Redis offers two persistence mechanisms that can be used independently or together.

### RDB (Redis Database Snapshots)

Redis periodically takes a **point-in-time snapshot** of all data and writes it to disk as a binary `.rdb` file.

**How it works**:
1. Redis forks the main process
2. The child process writes all data to a temporary RDB file
3. When complete, the temp file atomically replaces the old RDB file
4. The main process continues serving requests uninterrupted (copy-on-write)

**Configuration**:
```
save 900 1      # Snapshot if at least 1 key changed in 900 seconds
save 300 10     # Snapshot if at least 10 keys changed in 300 seconds
save 60 10000   # Snapshot if at least 10000 keys changed in 60 seconds
```

**Pros**: Compact file, fast restart, minimal performance impact
**Cons**: Data loss between snapshots (e.g., up to 5 minutes of data)

### AOF (Append-Only File)

Every write operation is appended to a log file. On restart, Redis replays the log to reconstruct data.

**Sync policies**:
- `always` — fsync after every write. Safest, slowest.
- `everysec` — fsync once per second. Good balance (at most 1 second of data loss).
- `no` — Let the OS decide when to flush. Fastest, riskiest.

**Pros**: Minimal data loss (1 second with `everysec`), human-readable log
**Cons**: Larger files, slower restart (must replay entire log), AOF rewrite overhead

### RDB + AOF (recommended for production)

Use both: AOF for durability (minimal data loss), RDB for fast restarts and backups. On restart, Redis prefers AOF if both exist (it's more complete).

### Interview tip

For a cache-only use case (like ours), persistence is optional. If Redis restarts, the cache is cold but refills naturally as requests come in. We use **Sentinel** for high availability rather than relying on disk persistence for data safety.

---

## 4. Expiry and TTL

### Concept

Every Redis key can have a TTL (Time To Live). When the TTL expires, the key is automatically deleted. This is fundamental for caching — data auto-evicts without application logic.

### Setting TTL

```
SET key "value"
EXPIRE key 3600           # Expire in 3600 seconds
TTL key → 3598            # Remaining time

SETEX key 3600 "value"    # SET + EXPIRE in one atomic command
PSETEX key 3600000 "value" # Same but milliseconds

SET key "value" EX 3600   # SET with EX flag (Redis 2.6.12+)
```

### How expiry works internally

Redis uses two strategies for cleaning expired keys:

1. **Lazy expiry** — When a key is accessed, Redis checks if it has expired. If yes, it deletes it and returns nil. Keys that are never accessed again stay in memory until...

2. **Active expiry** — Redis runs a background task 10 times per second that randomly samples 20 expired keys. If more than 25% of sampled keys are expired, it repeats immediately. This probabilistically cleans up expired keys even if they're never accessed.

### Our TTL patterns

| Use Case | Key Pattern | TTL | Purpose |
|----------|-------------|-----|---------|
| Airtel publisher state | `airtelPublisher_state_DDMMYYYY` | 24 hours | Persist daily processing cursor across restarts |
| Notification order cache | `PREFIX:order_id` | 25 hours | Hold pending items for order-level clubbing |
| Recharge nudge — recharge cache | `RNRC_productId:custId:rechargeNumber` | 2 days | Track recent recharges for nudge correlation |
| Recharge nudge — dedup | `RNN_...` | 1 day | Prevent duplicate nudge notifications |

### TTL gotchas

- Overwriting a key with SET removes its TTL (unless you re-specify it)
- PERSIST removes TTL, making the key permanent
- TTL returns -1 if key exists but has no expiry, -2 if key doesn't exist
- Renaming a key with RENAME preserves its TTL
- In a cluster, TTL expiry happens on the node that owns the key

---

## 5. Redis Sentinel — High Availability

### Concept

Redis Sentinel is a system for managing Redis high availability. It monitors Redis instances, detects failures, and performs automatic failover.

### What Sentinel does

1. **Monitoring** — Continuously checks if master and slave instances are working
2. **Notification** — Alerts administrators or other systems via API when something goes wrong
3. **Automatic failover** — If the master fails, Sentinel promotes a slave to master and reconfigures other slaves to use the new master
4. **Configuration provider** — Clients ask Sentinel for the current master address instead of hardcoding it

### How failover works

```
Normal state:
  Sentinel 1 ─── monitors ───→ Master ←── replicates ── Slave 1
  Sentinel 2 ─── monitors ───→ Master ←── replicates ── Slave 2
  Sentinel 3 ─── monitors ───→ Master

Master fails:
  Sentinel 1 detects failure ──→ Marks master as SDOWN (subjective down)
  Sentinel 2 also detects    ──→ Quorum agrees → ODOWN (objective down)
  Sentinels elect a leader   ──→ Leader promotes Slave 1 to Master
  All clients reconnect      ──→ New Master: Slave 1
```

### Quorum

Sentinels use a quorum (majority) to agree that a master is down. This prevents false positives from network partitions. With 3 Sentinels, quorum = 2. At least 2 must agree the master is unreachable before failover.

### Our Sentinel setup

We use Sentinel in all environments with 3 Sentinel instances per cluster:

**Production (main Redis cluster)**:
- 3 Sentinel nodes at ports 26379
- Master name: `cluster`
- Used by: notification service, Airtel publisher, recharge nudge

**Production (notification Redis cluster)**:
- Separate 3-node Sentinel group
- Master name: `cluster`
- Dedicated to notification workloads (historical — mostly migrated to Cassandra)

**Why 3 Sentinels?** With 3, you can lose 1 and still have a quorum (2) for failover. With 2, losing 1 means no quorum — no automatic failover. Always use an odd number.

### Client connection pattern

Our application connects to Redis through Sentinel, not directly to the master:

```javascript
this.redis = new this.infraUtils.cache("REDIS", this.config.REDIS);
this.redis.connect(callback);
```

The config includes Sentinel addresses:
```javascript
sentinel: [
    { host: '10.4.33.233', port: 26379 },
    { host: '10.4.33.26', port: 26379 },
    { host: '10.4.33.146', port: 26379 }
],
sentinelMasterName: 'cluster'
```

The client library asks Sentinel "who is the current master for `cluster`?" and connects to that address. If failover occurs, the client detects the change and reconnects to the new master.

---

## 6. Redis Cluster — Horizontal Scaling

### Concept

While Sentinel provides high availability for a single master, Redis Cluster provides **horizontal scaling** by distributing data across multiple masters.

### How it works

Redis Cluster divides the key space into **16,384 hash slots**. Each master node owns a subset of slots:

```
Master A: slots 0–5460
Master B: slots 5461–10922
Master C: slots 10923–16383
```

When you write a key, Redis hashes it (CRC16) to determine which slot — and therefore which master — owns it.

### Data distribution

```
SET user:1234 "data"
  → CRC16("user:1234") mod 16384 = 7523
  → Slot 7523 belongs to Master B
  → Request routed to Master B
```

### Hash tags

If you need related keys on the same node (for multi-key operations), use hash tags:

```
SET {user:1234}.profile "..."
SET {user:1234}.session "..."
```

Only the part inside `{}` is hashed, so both keys land on the same node.

### Cluster vs Sentinel

| Feature | Sentinel | Cluster |
|---------|----------|---------|
| Purpose | High availability | Scaling + HA |
| Data split | All data on one master | Sharded across masters |
| Capacity | Limited by one machine's RAM | Combined RAM of all masters |
| Failover | Promotes slave to master | Per-shard failover |
| Multi-key ops | All work (single master) | Only within same slot |
| Complexity | Lower | Higher |

### When to use Cluster

- Data exceeds single machine's RAM
- Write throughput exceeds single machine capacity
- You need both scaling AND high availability

### Our choice: Sentinel over Cluster

We use Sentinel (not Cluster) because:
1. Our Redis dataset fits in single-machine RAM (we cache limited hot data)
2. Most heavy data was migrated to Cassandra
3. Sentinel is operationally simpler
4. Our remaining Redis use cases don't need multi-master write throughput

---

## 7. Caching Patterns

### Cache-Aside (Lazy Loading)

The most common pattern. Application manages the cache explicitly:

```
Read:
1. Check cache → if HIT, return cached data
2. If MISS → read from database
3. Write result to cache (with TTL)
4. Return data

Write:
1. Write to database
2. Invalidate (delete) the cache key
```

**Pros**: Only requested data is cached, cache failures don't break reads
**Cons**: Initial read is slow (cache miss + DB read + cache write), possible stale data

### Write-Through

Every write goes to both cache and database:

```
Write:
1. Write to cache
2. Write to database
3. Return success

Read:
1. Always read from cache (guaranteed fresh)
```

**Pros**: Cache is always current, reads never hit database
**Cons**: Write latency increases, unused data fills cache

### Write-Behind (Write-Back)

Write to cache immediately, asynchronously flush to database:

```
Write:
1. Write to cache → return success immediately
2. Background process flushes cache to database periodically

Read:
1. Always read from cache
```

**Pros**: Fastest writes, database is batched
**Cons**: Risk of data loss if cache crashes before flush, complex to implement correctly

### Our pattern

We use **Cache-Aside** for most flows. For example, in the notification service:
1. Check Redis for pending order items
2. If found, add new item to existing order cache
3. If not found, create new cache entry with TTL
4. When order is complete (or TTL expires), process the cached items

The Airtel publisher uses a **Write-Through** style for state persistence — every state change is immediately written to Redis so a restart can resume from where it left off.

---

## 8. Cache Invalidation Strategies

### "The two hardest problems in computer science..."

> There are only two hard things in Computer Science: cache invalidation and naming things. — Phil Karlton

### TTL-based expiry (Time-based)

Set a TTL on every cache key. After TTL, data is automatically removed and the next read triggers a fresh database fetch.

**Pros**: Simple, automatic cleanup, bounded staleness
**Cons**: Data may be stale until TTL expires, choosing the right TTL is an art

### Event-based invalidation

Invalidate cache when the underlying data changes:

```
User updates bill → DELETE cache key for that bill
Next read → cache miss → fresh data from DB → cache refill
```

**Pros**: Always fresh
**Cons**: Must catch every write path, distributed invalidation is hard

### Versioned keys

Include a version or timestamp in the cache key:

```
bill:v3:12345 → current version
```

When data changes, increment version. Old keys naturally expire via TTL.

### Our approach

We primarily use **TTL-based expiry**:
- Recharge nudge keys: 1-2 day TTL (data is only relevant for a short window)
- Notification order cache: 25-hour TTL (orders must be processed within a day)
- Publisher state: 24-hour TTL (aligned with daily processing cycle)

We also use **explicit deletion** — the notification service deletes the Redis key after successfully processing an order's notification.

---

## 9. Distributed Locking with Redis

### The problem

When multiple instances of a service run in parallel, you sometimes need to ensure only one instance performs a certain operation at a time. For example:
- Only one publisher instance should process a given operator batch
- Only one cron should execute a particular scheduled job

### SETNX-based lock (basic)

```
SET lock:job123 "instance-A" NX EX 30
```

- `NX` — Only set if key does NOT exist (atomic check-and-set)
- `EX 30` — Auto-expire in 30 seconds (prevents deadlock if holder crashes)

If the command returns OK, you acquired the lock. If nil, someone else holds it.

### Releasing the lock safely

You must only release a lock you own. Using a simple DELETE is unsafe (you might delete someone else's lock). Use a Lua script for atomic check-and-delete:

```lua
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
else
    return 0
end
```

### Redlock algorithm

For distributed environments with multiple Redis instances, a single Redis lock isn't sufficient (that Redis instance is a single point of failure). The **Redlock** algorithm acquires locks across N independent Redis instances:

1. Get current timestamp
2. Try to acquire lock on N instances with a short timeout
3. Lock is acquired if successful on majority (N/2 + 1) within the TTL
4. If failed, release lock on all instances

### Caveats

- Clock skew between instances can break Redlock
- Network partitions can cause split-brain (two holders)
- Martin Kleppmann's critique: Redlock is not safe for correctness-critical operations
- For truly safe distributed locking, use ZooKeeper or etcd with consensus protocols

### What we use instead

For our cron job claiming, we use Cassandra LWT (`INSERT IF NOT EXISTS`) instead of Redis locks. This is more durable and doesn't have the single-point-of-failure risk of single-instance Redis locks.

---

## 10. Pub/Sub Messaging

### Concept

Redis Pub/Sub allows publishers to send messages to channels and subscribers to listen on those channels. Messages are delivered in real-time — there's no persistence.

```
Publisher:   PUBLISH channel:notifications "new bill for user 1234"
Subscriber:  SUBSCRIBE channel:notifications
             → receives "new bill for user 1234"
```

### Key characteristics

- **Fire and forget** — Messages are not stored. If no subscriber is listening, the message is lost
- **No acknowledgment** — Publisher doesn't know if anyone received the message
- **No replay** — A subscriber that connects AFTER a message was published will never see it
- **Fan-out** — All subscribers receive every message (not load-balanced)

### When to use Pub/Sub

- Real-time notifications where message loss is acceptable
- Configuration change broadcasts
- Cache invalidation signals across instances

### When NOT to use Pub/Sub

- When messages must not be lost (use Kafka, RabbitMQ, or Redis Streams instead)
- When you need message acknowledgment and retry
- When you need message history or replay

### Our choice: Kafka over Redis Pub/Sub

We use **Kafka** for all inter-service messaging because:
- Messages must persist (bill events can't be lost)
- Consumer groups provide load balancing
- Message replay is needed for recovery
- At-least-once delivery guarantees

Redis Pub/Sub would be inappropriate for our bill processing pipeline where every event must be processed exactly once.

---

## 11. Pipelining and Transactions

### Pipelining

Redis is fast, but network round-trips add latency. With pipelining, you send multiple commands at once without waiting for each response:

```
Without pipeline (3 round trips):
  → SET key1 val1    ← OK
  → SET key2 val2    ← OK
  → SET key3 val3    ← OK

With pipeline (1 round trip):
  → SET key1 val1 | SET key2 val2 | SET key3 val3
  ← OK | OK | OK
```

**10x-100x throughput improvement** for bulk operations.

### Transactions (MULTI/EXEC)

Redis transactions group commands into an atomic block:

```
MULTI                    # Start transaction
SET balance:A 500        # Queued
SET balance:B 1500       # Queued
EXEC                     # Execute all atomically
```

**Key differences from SQL transactions**:
- No rollback — if one command fails, others still execute
- No isolation — other clients can run commands between MULTI and EXEC
- Atomic execution — once EXEC is called, all commands run without interruption
- No conditional logic inside — use WATCH for optimistic locking

### WATCH (optimistic locking)

```
WATCH balance:A          # Watch for changes
val = GET balance:A      # Read current value
MULTI
SET balance:A (val - 100)
EXEC                     # Fails if balance:A was modified since WATCH
```

If another client modified `balance:A` between WATCH and EXEC, the transaction is aborted (returns nil). The client must retry.

### Lua scripting (atomic operations)

For complex atomic operations, Redis supports server-side Lua scripts:

```lua
-- Atomic "check and decrement" for rate limiting
local current = tonumber(redis.call('GET', KEYS[1]) or 0)
if current > 0 then
    redis.call('DECR', KEYS[1])
    return 1  -- allowed
else
    return 0  -- rate limited
end
```

Lua scripts are atomic — no other command can run while the script executes. This is the recommended approach for multi-step atomic operations.

---

## 12. Memory Management and Eviction

### The fundamental constraint

Redis stores everything in RAM. RAM is expensive and finite. When Redis reaches its memory limit, it needs a strategy for what to do.

### maxmemory configuration

```
maxmemory 4gb
maxmemory-policy allkeys-lru
```

### Eviction policies

| Policy | Behavior | Best For |
|--------|----------|---------|
| `noeviction` | Return error on writes when full | When data loss is unacceptable |
| `allkeys-lru` | Evict least recently used key | General-purpose cache |
| `volatile-lru` | Evict LRU among keys WITH a TTL | Mix of cache and persistent data |
| `allkeys-lfu` | Evict least frequently used key | When access frequency varies widely |
| `volatile-lfu` | Evict LFU among keys with TTL | Frequency-based with persistent keys |
| `allkeys-random` | Evict random key | When access is truly uniform |
| `volatile-random` | Evict random key with TTL | Random among expiring keys |
| `volatile-ttl` | Evict keys closest to expiry | When near-expiry data is least valuable |

### LRU vs LFU

**LRU (Least Recently Used)**: Evicts the key that hasn't been accessed for the longest time. Good default, but a key accessed once recently can survive over a frequently accessed key.

**LFU (Least Frequently Used)**: Tracks access frequency. A key accessed 1000 times won't be evicted just because it wasn't accessed in the last minute. Better for workloads with clear "hot" and "cold" keys. Available since Redis 4.0.

### Memory optimization tips

- Use appropriate data types (Hash for small objects is more memory-efficient than individual keys)
- Set TTLs aggressively — don't cache data longer than needed
- Use short key names in high-volume scenarios
- Monitor with `INFO memory` and `MEMORY USAGE key`
- Consider compression for large values (compress in application before SET)

---

## 13. Redis Streams

### Concept

Redis Streams (introduced in 5.0) is a log-like data structure that addresses Pub/Sub's limitations. Think of it as a lightweight, Redis-native alternative to Kafka for simpler use cases.

### Key features

- **Persistent** — Messages are stored and can be replayed
- **Consumer groups** — Load balancing across multiple consumers
- **Acknowledgment** — Messages must be explicitly acknowledged
- **ID-based** — Each entry has a unique ID (timestamp-based)
- **Range queries** — Read entries by ID or time range

### Basic operations

```
XADD stream:bills * operator "Airtel" amount "500"   # Add entry
XLEN stream:bills                                      # Count entries
XRANGE stream:bills - +                                # Read all
XREAD COUNT 10 STREAMS stream:bills 0                  # Read from start

# Consumer group
XGROUP CREATE stream:bills group1 0                    # Create group
XREADGROUP GROUP group1 consumer1 COUNT 10 STREAMS stream:bills >
XACK stream:bills group1 1234567890-0                  # Acknowledge
```

### Streams vs Pub/Sub vs Kafka

| Feature | Pub/Sub | Streams | Kafka |
|---------|---------|---------|-------|
| Persistence | No | Yes (in Redis) | Yes (disk) |
| Consumer groups | No | Yes | Yes |
| Acknowledgment | No | Yes | Yes |
| Replay | No | Yes | Yes |
| Scale | Single instance | Single instance | Distributed |
| Durability | None | RAM + optional disk | Disk + replication |

### When to use Streams

- Lightweight event processing within a single service
- When Kafka is overkill (low volume, same-machine consumers)
- Task queues with acknowledgment

We use Kafka for our messaging needs because of the scale and durability requirements, but Streams is worth knowing for interviews.

---

## 14. Our Architecture — How We Use Redis

### Current Redis usage (what remains)

After migrating the notification deduplication cache to Cassandra, Redis is used for a focused set of use cases:

| Service | Purpose | Key Pattern | TTL |
|---------|---------|-------------|-----|
| **Notification Service** (order-level aggregator) | Cache pending order items for clubbed notifications | `PREFIX:order_id` | 25 hours |
| **Airtel Kafka Publisher** | Persist daily processing state (priority, cursor, counts) across restarts | `airtelPublisher_state_DDMMYYYY` | 24 hours |
| **Recharge Nudge — Recharge Consumer** | Cache recent recharge timestamps for correlation | `RNRC_productId:custId:rechargeNumber` | 2 days |
| **Recharge Nudge — Validation Consumer** | Deduplication flag to prevent duplicate nudges | `RNN_...` | 1 day |

### Redis clusters

| Cluster | Config Key | Environments | Purpose |
|---------|-----------|-------------|---------|
| Main Redis | `REDIS` | All | General caching for remaining use cases |
| Notification Redis | `NOTIFICATION_REDIS` | All | Historical — largely migrated to Cassandra |

### Connection pattern

We access Redis through the `digital-in-util` infrastructure wrapper, not raw Redis clients:

```javascript
// In service constructor
this.redis = new this.infraUtils.cache("REDIS", this.config.REDIS);

// In start()
this.redis.connect(callback);

// Operations
this.redis.getData(callback, { key: redisKey });
this.redis.setData(callback, { key: redisKey, value: data, ttl: ttlMs });
this.redis.updateData(callback, { key: redisKey, value: data });
this.redis.deleteData(callback, { key: redisKey });
```

This abstraction gives us a simplified API: `getData`, `setData`, `updateData`, `deleteData`. Under the hood, it handles Sentinel connection management, serialization, and error handling.

### What we DON'T use Redis for

- No Pub/Sub (we use Kafka)
- No distributed locking (we use Cassandra LWT)
- No session storage (API is stateless)
- No sorted sets or complex data structures (just key-value with JSON blobs)
- No dynamic config storage (we use MySQL for `digital_reminder_config`)

---

## 15. Why We Migrated From Redis to Cassandra

### The notification deduplication story

Our notification dispatch service (`notify.js`) needs to check "have I already sent this notification?" before dispatching. This deduplication cache was originally in Redis.

### Problems with Redis for this use case

**1. Data volume exceeded RAM capacity**

The notification pipeline processes millions of notifications daily. Each notification needs a dedup entry. Even with TTL, the working set grew beyond what was cost-effective in RAM.

**2. Durability concerns**

If Redis crashed or restarted, the dedup cache was lost. This meant:
- Duplicate notifications could be sent during the cold-cache period
- For bill reminders, sending duplicate SMS/push notifications is costly and annoying to users

**3. Single-point-of-failure risk**

Even with Sentinel, failover takes seconds. During that window, the notification service either:
- Blocks (causing backlog in Kafka consumers)
- Proceeds without dedup (risk of duplicates)

**4. Cost at scale**

RAM is ~10x more expensive than SSD storage. Storing millions of dedup entries with 3-hour+ TTL in RAM was expensive.

### Why Cassandra was the right replacement

| Requirement | Redis | Cassandra |
|-------------|-------|-----------|
| Storage cost per GB | High (RAM) | Low (SSD) |
| Data volume | Limited by RAM | Scales horizontally |
| Durability | Volatile (RAM-first) | Durable (replicated to disk) |
| Availability | Sentinel failover (seconds) | No single point of failure |
| TTL support | Native | Native (per-column) |
| Read latency for dedup | Sub-ms | 1-5ms (acceptable for our SLA) |
| Write throughput | Very high | Very high |

### The tradeoff we accepted

We traded **sub-millisecond latency** (Redis) for **1-5ms latency** (Cassandra). For notification deduplication, this is perfectly acceptable — the notification dispatch itself takes much longer than 5ms (API calls, template rendering, etc.).

### What stayed in Redis

Use cases where sub-millisecond latency matters or data volume is small:
- **Order-level notification aggregation** — Small dataset, needs fast read-modify-write cycles
- **Airtel publisher state** — Single key per day, needs atomic state persistence
- **Recharge nudge** — Time-sensitive correlation between recharge and validation events

### The migration approach

The migration was controlled by a dynamic config flag (`isNotificationMigratedToCassandra`). This allowed:
1. Cassandra-first code with feature flag
2. Gradual rollout across notification categories
3. Easy rollback if issues were found
4. No dual-write complexity — just switch the read/write target

---

## 16. Redis vs Cassandra — When to Use Which

### Decision framework

```
Do you need sub-millisecond latency?
  ├── YES → Is data volume < available RAM?
  │         ├── YES → Redis
  │         └── NO → Consider Redis Cluster or rethink data model
  └── NO → Is data volume large (millions+ records)?
            ├── YES → Cassandra
            └── NO → Is durability critical?
                      ├── YES → Cassandra
                      └── NO → Redis (simpler to operate)
```

### Side-by-side comparison

| Dimension | Redis | Cassandra |
|-----------|-------|-----------|
| **Latency** | Sub-millisecond | 1-10ms |
| **Storage** | RAM (expensive) | Disk (cheap) |
| **Capacity** | GBs per instance | TBs per cluster |
| **Durability** | Optional (can lose data) | Always durable (replicated) |
| **Scaling** | Vertical + Cluster | Horizontal (add nodes) |
| **Data model** | Rich structures (sets, lists, sorted sets) | Wide-column (table-based) |
| **TTL** | Per-key | Per-column |
| **Querying** | Key-only (no secondary queries) | By partition key (+clustering) |
| **Best for** | Hot cache, sessions, counters, real-time | Large-scale storage, time-series, write-heavy |
| **Operations** | Simple (single binary) | Complex (multi-node cluster) |
| **Consistency** | Strong (single instance) | Tunable (ONE to ALL) |

### Our hybrid approach

```
Request flow:

User action
  → API server
  → Check Redis (order-level cache, nudge state)
  → Check Cassandra (notification dedup, non-RU bills, notification cache)
  → Check MySQL (bill records, publisher queries, config)
  → Process + respond
```

Each datastore handles the workload it's best suited for. This **polyglot persistence** approach is increasingly common in modern microservices.

---

## 17. Top 25 Interview Questions

### Q1: What is Redis and why is it fast?

Redis is an in-memory key-value data store. It's fast because:
1. All data is in RAM (no disk I/O for reads/writes)
2. Single-threaded event loop (no locking overhead, no context switching)
3. Efficient data structures (hash tables, skip lists) optimized for O(1) operations
4. Non-blocking I/O with epoll/kqueue multiplexing
5. Simple protocol (RESP) with minimal parsing overhead

Typical throughput: 100K+ operations per second on a single instance.

### Q2: What happens when Redis runs out of memory?

Depends on the `maxmemory-policy`:
- `noeviction` — Returns errors on new writes (reads still work)
- `allkeys-lru` — Evicts least recently used key to make room
- `volatile-lru` — Evicts LRU among keys with TTL only
- Other policies: LFU, random, volatile-ttl

If no `maxmemory` is set, Redis grows until the OS kills it (OOM killer). Always set `maxmemory` in production.

### Q3: Explain the difference between RDB and AOF persistence

**RDB**: Point-in-time snapshots at intervals. Compact binary file. Fast restart. Can lose data between snapshots (minutes).

**AOF**: Append every write operation. Larger file. Slower restart (must replay). Minimal data loss (1 second with `everysec` fsync).

Use both in production: AOF for durability, RDB for fast backups and disaster recovery.

### Q4: How does Redis Sentinel ensure high availability?

Sentinel monitors Redis instances. When the master fails:
1. Multiple Sentinels must agree (quorum) that the master is down
2. A Sentinel leader is elected to perform failover
3. The leader promotes the best slave to master
4. Other slaves are reconfigured to replicate from the new master
5. Clients are notified to reconnect to the new master

Failover typically takes 1-3 seconds. Use an odd number of Sentinels (3 or 5) for reliable quorum.

### Q5: What is the difference between Redis Cluster and Redis Sentinel?

**Sentinel**: High availability for a single master. All data on one server. Automatic failover.

**Cluster**: Data sharding across multiple masters (16384 hash slots). Each master handles a portion of data. Built-in HA (each master has its own slaves). Scales both reads and writes horizontally.

Use Sentinel when data fits in one machine. Use Cluster when you need to scale beyond single-machine capacity.

### Q6: How would you implement rate limiting with Redis?

**Fixed window** (simplest):
```
key = "ratelimit:user123:minute:202604131530"
INCR key
EXPIRE key 60  (only on first INCR)
if count > limit → reject
```

**Sliding window** (precise, using sorted set):
```
ZADD ratelimit:user123 timestamp timestamp
ZREMRANGEBYSCORE ratelimit:user123 0 (now - window)
ZCARD ratelimit:user123
if count > limit → reject
```

**Token bucket** (smooth, using Lua):
```
Lua script: refill tokens based on elapsed time, decrement if available
```

### Q7: Explain the CAP theorem in context of Redis

**Single instance**: Redis is CP-ish — strongly consistent (single thread) but not partition-tolerant (single machine failure = downtime).

**Sentinel**: AP-ish — during network partition, the old master and new master might both accept writes (split-brain), leading to data divergence. After partition heals, one master's writes are lost.

**Cluster**: Trades some consistency for availability. During node failure, the cluster may briefly reject requests for affected slots until failover completes.

### Q8: What is cache stampede (thundering herd) and how do you prevent it?

When a popular cache key expires, all concurrent requests simultaneously miss the cache and hit the database, potentially overwhelming it.

**Solutions**:
1. **Mutex/lock**: First request acquires a lock, fetches from DB, fills cache. Others wait.
2. **Stale-while-revalidate**: Serve stale data while one request refreshes the cache in background.
3. **Probabilistic early expiration**: Randomly refresh before TTL expires. `current_time + TTL * beta * ln(random)` — some requests refresh early.
4. **Never expire**: Use background refresh instead of TTL.

### Q9: How does Redis handle concurrency if it's single-threaded?

Redis uses **I/O multiplexing** (epoll on Linux, kqueue on macOS). A single thread manages thousands of client connections. Each command executes atomically because there's only one thread — no locks needed.

Since Redis 6.0, there are **I/O threads** for reading/writing client data (network I/O), but command execution remains single-threaded.

For multi-step atomic operations, use Lua scripts or MULTI/EXEC transactions.

### Q10: What is the difference between MULTI/EXEC and Lua scripts?

**MULTI/EXEC**: Groups commands that execute atomically. But you can't use one command's result to decide the next command (no conditional logic). Commands are pre-queued, then batch-executed.

**Lua scripts**: Full programming language executed atomically on the server. Can use conditionals, loops, and intermediate results. More powerful but harder to debug.

Use MULTI/EXEC for simple atomic batches. Use Lua for complex atomic operations (e.g., compare-and-set, rate limiting with complex logic).

### Q11: How would you implement a distributed lock with Redis?

```
# Acquire
SET lock:resource "owner-id" NX EX 30

# Release (Lua script for safety)
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
end
```

Key principles:
- `NX` ensures only one holder
- `EX` prevents deadlock on holder crash
- Owner ID prevents releasing someone else's lock
- Lua script makes check-and-delete atomic

For multi-instance safety, use Redlock (acquire on N/2+1 independent Redis instances).

### Q12: What are Redis Streams and how do they compare to Kafka?

Streams are a persistent, appendable log data structure in Redis (since 5.0). They support consumer groups, acknowledgment, and message replay.

**vs Kafka**: Streams are simpler, lower latency, but single-machine (limited by Redis instance capacity). Kafka is distributed, handles TB-scale, and has stronger durability guarantees. Use Streams for lightweight intra-service messaging. Use Kafka for mission-critical, high-volume, cross-service messaging.

### Q13: Explain Redis pipelining and when you'd use it

Pipelining sends multiple commands to Redis without waiting for each response. All responses come back in order after all commands are sent. This eliminates network round-trip latency per command.

Use when you need to execute many independent commands (e.g., setting 1000 keys). Don't use when each command depends on the previous command's result.

### Q14: What is the difference between Redis expire and eviction?

**Expire (TTL)**: Explicit per-key timer. Key is deleted when TTL reaches 0. Set by the developer for each key. Predictable.

**Eviction**: Global memory management. When Redis reaches `maxmemory`, it evicts keys based on the eviction policy. Not key-specific — Redis chooses which keys to remove. Emergency measure.

### Q15: How does Redis replication work?

1. Slave connects to master and sends PSYNC command
2. Master starts a background RDB save and buffers new writes
3. Master sends RDB file to slave (full sync)
4. Slave loads RDB file
5. Master sends buffered writes since RDB save started
6. From now on, master streams every write to slave in real-time

If connection breaks briefly, **partial resync** using replication backlog (offset-based) avoids full RDB transfer.

### Q16: What is a hot key problem and how do you solve it?

A **hot key** is accessed so frequently that it becomes a bottleneck — especially in Redis Cluster where one key maps to one node.

Solutions:
1. **Key splitting**: `popular_key:1`, `popular_key:2`, ... — distribute across slots
2. **Local cache**: Cache the hot key in application memory (L1 cache) with short TTL
3. **Read replicas**: For reads, distribute across slaves
4. **Value splitting**: If the value is large, break it into smaller keys

### Q17: Why did you migrate from Redis to Cassandra for notification dedup?

Four reasons:
1. **Data volume**: Millions of dedup entries exceeded cost-effective RAM capacity
2. **Durability**: Redis restart lost the dedup cache, causing duplicate notifications
3. **Availability**: Sentinel failover window risked duplicates
4. **Cost**: RAM is ~10x more expensive than SSD per GB

The 1-5ms latency increase from Cassandra was acceptable because notification dispatch itself takes 50-200ms (API calls, template rendering).

### Q18: What data types would you use for a real-time leaderboard?

**Sorted Set (ZADD/ZRANK)**. Store player:score pairs. Sorted sets maintain ordering by score automatically.

- Add/update score: `ZADD leaderboard 1500 "player1"` — O(log N)
- Get rank: `ZREVRANK leaderboard "player1"` — O(log N)
- Top 10: `ZREVRANGE leaderboard 0 9 WITHSCORES` — O(log N + 10)
- Total players: `ZCARD leaderboard` — O(1)

No other database can do this with comparable latency.

### Q19: How would you handle Redis failover in your application?

1. Use Sentinel or Cluster (never point directly at a Redis instance)
2. Client library handles reconnection automatically
3. Implement retry with exponential backoff for transient failures
4. Design the application to be cache-tolerant — if Redis is down, fall back to database
5. Use circuit breaker pattern — after N failures, stop trying Redis and go directly to DB
6. Monitor Redis health with heartbeats and alerts

### Q20: What is the difference between Memcached and Redis?

| Feature | Memcached | Redis |
|---------|-----------|-------|
| Data types | Only strings | Strings, hashes, lists, sets, sorted sets, streams |
| Persistence | No | RDB + AOF |
| Replication | No | Built-in |
| Pub/Sub | No | Yes |
| Lua scripting | No | Yes |
| Clustering | Client-side sharding | Redis Cluster |
| Multi-threaded | Yes | Single-threaded (I/O threads in 6.0+) |
| Memory efficiency | Slab allocator | jemalloc |

Redis is almost always the better choice unless you need Memcached's multi-threaded performance for simple key-value caching.

### Q21: How do you monitor Redis in production?

Key metrics to watch:
- `used_memory` / `maxmemory` — How close to the limit
- `hit_rate` = `keyspace_hits / (keyspace_hits + keyspace_misses)` — Cache effectiveness
- `connected_clients` — Connection count
- `blocked_clients` — Clients waiting on blocking operations
- `evicted_keys` — Keys removed by eviction policy
- `expired_keys` — Keys removed by TTL
- `instantaneous_ops_per_sec` — Current throughput
- `latency` — Command latency percentiles

Tools: `INFO` command, `SLOWLOG`, Redis Sentinel monitoring, Datadog/Grafana dashboards.

### Q22: Explain the concept of Redis keyspace notifications

Redis can publish events when keys are modified or expired. Clients subscribe to these events:

```
CONFIG SET notify-keyspace-events KEA
SUBSCRIBE __keyevent@0__:expired
```

This publishes a message whenever any key expires. Use cases: cache invalidation callbacks, TTL-based job scheduling, monitoring.

### Q23: What is Redis module system?

Redis modules extend Redis with custom data types and commands (introduced in 4.0). Notable modules:
- **RedisJSON** — Native JSON type with path-based queries
- **RediSearch** — Full-text search with indexing
- **RedisTimeSeries** — Time-series data with downsampling
- **RedisGraph** — Graph database with Cypher queries
- **RedisBloom** — Probabilistic data structures (Bloom, Cuckoo, Count-Min Sketch)

### Q24: How would you design a session store with Redis?

```
Key:    session:<session_id>
Value:  JSON { user_id, roles, last_active, ... }
TTL:    30 minutes (sliding)

On each request:
1. GET session:<id> → user data
2. EXPIRE session:<id> 1800  → reset TTL (sliding window)

On login:  SETEX session:<new_id> 1800 <user_json>
On logout: DEL session:<id>
```

Use Hash instead of String if you need to read/update individual fields without deserializing the entire session.

### Q25: In a microservice architecture, would you use one shared Redis or multiple?

**Separate Redis instances per service/domain** is preferred:

1. **Isolation** — One service's cache spike doesn't evict another service's data
2. **Independent scaling** — Size each Redis to its workload
3. **Security** — Limit blast radius of a compromise
4. **Operational independence** — Restart/upgrade one without affecting others

This is exactly what we do — we have separate Redis clusters for general caching vs notification caching, each with independent Sentinel groups and configurations.

---

## Quick Reference: Redis Command Cheat Sheet

| Category | Commands | Time Complexity |
|----------|----------|-----------------|
| **String** | GET, SET, INCR, DECR, SETEX, MGET, MSET | O(1) |
| **Hash** | HGET, HSET, HGETALL, HDEL, HINCRBY | O(1) per field |
| **List** | LPUSH, RPUSH, LPOP, RPOP, LRANGE, LLEN | O(1) push/pop, O(N) range |
| **Set** | SADD, SREM, SISMEMBER, SMEMBERS, SINTER | O(1) add/check, O(N) members |
| **Sorted Set** | ZADD, ZREM, ZRANK, ZRANGE, ZRANGEBYSCORE | O(log N) most ops |
| **Key** | DEL, EXISTS, EXPIRE, TTL, KEYS, SCAN | O(1) except KEYS O(N) |
| **Transaction** | MULTI, EXEC, WATCH, DISCARD | O(1) + O(commands) |
| **Server** | INFO, DBSIZE, FLUSHDB, SLOWLOG | O(1) |

**Never use KEYS in production** — it blocks the single thread while scanning all keys. Use SCAN instead (cursor-based, non-blocking).

---

*Prepared for interview reference. Based on Redis concepts and real-world usage patterns from the digital-reminder microservice, including the migration story from Redis to Cassandra for notification deduplication.*
