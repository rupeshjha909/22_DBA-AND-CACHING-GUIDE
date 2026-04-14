# Aerospike in recharges-bff — Interview Preparation Guide

## Table of Contents

1. [Aerospike Fundamentals — Learn from Zero](#1-aerospike-fundamentals--learn-from-zero)
2. [Why Aerospike over Redis?](#2-why-aerospike-over-redis-interview-answer)
3. [Aerospike vs Redis — Detailed Comparison](#3-aerospike-vs-redis--detailed-comparison)
4. [How Aerospike is Used in recharges-bff](#4-how-aerospike-is-used-in-recharges-bff)
5. [Key Data Model — Namespaces, Sets, Bins](#5-key-data-model--namespaces-sets-bins)
6. [HomeReminder API — Deep Dive](#6-homereminder-api--deep-dive)
7. [FrequentOrders V5 API — Deep Dive](#7-frequentorders-v5-api--deep-dive)
8. [Cache Eviction API](#8-cache-eviction-api)
9. [Agent Detection Flow](#9-agent-detection-flow)
10. [TTL Strategy](#10-ttl-strategy)
11. [Caching Patterns Used](#11-caching-patterns-used)
12. [Architecture Diagram](#12-architecture-diagram)
13. [Common Interview Questions & Answers](#13-common-interview-questions--answers)

---

## 1. Aerospike Fundamentals — Learn from Zero

### 1.1 What is Aerospike?

Think of Aerospike as a **super-fast locker room** for your application's data.

- It's a **NoSQL database** — meaning it doesn't use tables with rows and columns like MySQL/PostgreSQL.
- It's a **key-value store** — you store data by a unique key and retrieve it by the same key (like a HashMap in Java, but distributed across multiple machines).
- It's **distributed** — data is automatically spread across multiple servers (nodes), so if one goes down, your data is still safe.
- It was built specifically for **real-time, high-traffic applications** — think payment apps, ad-tech, gaming, telecom — where you need answers in under 1 millisecond.

**In plain English:** Aerospike is like a library where every book has a unique ID. You walk in, give the ID, and get the book back in under 1 millisecond — even if the library has billions of books spread across thousands of shelves.

### 1.2 How Does Aerospike Store Data? (The Data Model)

Aerospike organizes data in a **4-level hierarchy**. Here's the analogy:

```
┌─────────────────────────────────────────────────────────────────┐
│                        AEROSPIKE CLUSTER                        │
│                  (A group of servers/nodes)                      │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    NAMESPACE                               │  │
│  │          (Like a "database" in MySQL)                      │  │
│  │                                                           │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │                    SET                               │  │  │
│  │  │          (Like a "table" in MySQL)                   │  │  │
│  │  │           ⚠️ Sets are OPTIONAL                       │  │  │
│  │  │                                                     │  │  │
│  │  │  ┌───────────────────────────────────────────────┐  │  │  │
│  │  │  │               RECORD                          │  │  │  │
│  │  │  │        (Like a "row" in MySQL)                │  │  │  │
│  │  │  │  Identified by a unique KEY                   │  │  │  │
│  │  │  │                                               │  │  │  │
│  │  │  │  Contains one or more BINS:                   │  │  │  │
│  │  │  │    bin1: "value1"  (like a column)            │  │  │  │
│  │  │  │    bin2: 42        (like another column)      │  │  │  │
│  │  │  │    bin3: [1,2,3]   (like another column)      │  │  │  │
│  │  │  └───────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

Let's break down each level:

#### NAMESPACE (= Database)

A namespace is the **top-level container** — like a database in MySQL.

- Each namespace has its own **storage configuration** (RAM only, SSD only, or hybrid).
- Each namespace has its own **replication factor** (how many copies of data to keep).
- Each namespace has a **default TTL** (time-to-live — when records auto-expire).

**In our project**, we have two namespaces:
- `smartreminder` — stores customer-facing data (reminders, agent flags, vehicle data)
- `recharges_bff` — stores internal/operational data (request blocking, interstitials)

**MySQL analogy:**
```
MySQL:      CREATE DATABASE smartreminder;
Aerospike:  namespace smartreminder { ... }  (configured in aerospike.conf)
```

#### SET (= Table) — OPTIONAL

A set is a **logical grouping** of records within a namespace — like a table in MySQL.

- Sets are **optional** — you can store records directly in a namespace without a set (set = `null`).
- Sets don't need to be created beforehand — they are **auto-created** when you first write a record to them.
- Sets don't have a fixed schema — different records in the same set can have different bins.

**In our project**, we use sets like:
- `agent` — stores agent flags (is this customerId an agent?)
- `vehicaldetail` — stores car/vehicle information
- `interstitial_data_set` — stores interstitial popup data
- `null` (no set) — for HR, TB, OR keys where we don't need grouping

**MySQL analogy:**
```
MySQL:      CREATE TABLE agent (customer_id VARCHAR, is_agent VARCHAR);
Aerospike:  Just write to set "agent" — it auto-creates!
```

#### RECORD (= Row)

A record is a **single data entry** — like a row in MySQL.

- Every record is identified by a **unique Key** (within its namespace + set).
- A key is constructed from 3 parts: `Key(namespace, set, userKey)`
  - `namespace` — which namespace (required)
  - `set` — which set (can be `null`)
  - `userKey` — the unique identifier (a string, integer, or bytes)

**In our project**, keys look like:
```java
Key key = new Key("smartreminder", null, "HR_1001561216");
//                  namespace      set    userKey
//                  (database)   (null=   (the unique
//                               no set)   identifier)
```

**MySQL analogy:**
```
MySQL:      SELECT * FROM reminders WHERE id = 'HR_1001561216';
Aerospike:  client.get(policy, new Key("smartreminder", null, "HR_1001561216"));
```

#### BIN (= Column)

A bin is a **named field** within a record — like a column in MySQL.

- A record can have **multiple bins** (like a row with multiple columns).
- Bins are **schema-less** — you can add/remove bins freely, no ALTER TABLE needed.
- Each bin has a **name** (string) and a **value** (string, integer, double, bytes, list, map).
- Bins are stored **independently** — you can read/write individual bins without touching others.

**In our project**, bins are used like:
```java
// A record for HR_1001561216 might have:
//   bin "HR"              → serialized ArrayList<SagaRecentResponse>
//   bin "HR_ENCRYPTED_BIN" → true/false (is the HR data encrypted?)

Bin dataBin = new Bin("HR", serializedData);
Bin flagBin = new Bin("HR_ENCRYPTED_BIN", true);
client.put(policy, key, dataBin, flagBin);  // write 2 bins in 1 record
```

**MySQL analogy:**
```
MySQL:      INSERT INTO reminders (id, hr_data, is_encrypted) VALUES ('HR_123', '...', true);
Aerospike:  client.put(policy, key, new Bin("HR", data), new Bin("HR_ENCRYPTED_BIN", true));
```

### 1.3 Complete MySQL-to-Aerospike Mapping

| MySQL Concept | Aerospike Concept | Example in Our Project |
|---------------|-------------------|----------------------|
| Database | **Namespace** | `smartreminder`, `recharges_bff` |
| Table | **Set** | `agent`, `vehicaldetail`, `interstitial_data_set` |
| Row | **Record** | A single cached HR response for one customer |
| Primary Key | **Key** | `Key("smartreminder", null, "HR_1001561216")` |
| Column | **Bin** | `"HR"`, `"HR_ENCRYPTED_BIN"`, `"RU_RECO"` |
| Column value | **Bin value** | Strings, integers, serialized JSON, booleans |
| CREATE TABLE | Not needed | Sets auto-create on first write |
| ALTER TABLE ADD COLUMN | Not needed | Just write a new bin name — schema-less |
| TTL / row expiry | **Record TTL** | `WritePolicy.expiration = 86400` (1 day) |
| Index | **Primary Index** (auto) | Always exists — 64 bytes per key, stored in RAM |
| Secondary Index | **Secondary Index** (optional) | Created via `createIndex()` — not used in our project |

### 1.4 How Aerospike Stores Data Internally (Hybrid Memory)

This is the **key differentiator** that makes Aerospike special:

```
┌──────────────────────────────────────────────────┐
│                     RAM (Memory)                  │
│                                                  │
│   PRIMARY INDEX (always in RAM)                  │
│   ┌──────────────────────────────────────────┐   │
│   │ Key hash → partition → node location     │   │
│   │ ~64 bytes per record                     │   │
│   │                                          │   │
│   │ HR_1001561216 → partition 234 → node 2   │   │
│   │ HR_1001561217 → partition 891 → node 1   │   │
│   │ HR_1001561218 → partition 456 → node 3   │   │
│   │ ... (millions of entries)                │   │
│   └──────────────────────────────────────────┘   │
│                                                  │
│   For 100 million records:                       │
│   100M × 64 bytes = ~6.4 GB RAM                 │
└──────────────────────────────────────────────────┘
                    │
                    │ Index says "data is at offset X on SSD"
                    ▼
┌──────────────────────────────────────────────────┐
│                  SSD (Storage)                    │
│                                                  │
│   ACTUAL DATA (bins and their values)            │
│   ┌──────────────────────────────────────────┐   │
│   │ Record: HR_1001561216                    │   │
│   │   bin "HR" → [{"orderId": 123, ...}]    │   │
│   │   bin "HR_ENCRYPTED_BIN" → false         │   │
│   │   TTL → expires at 2024-03-17 00:00:00   │   │
│   └──────────────────────────────────────────┘   │
│                                                  │
│   For 100 million records × 1KB each:            │
│   = ~100 GB SSD (very cheap!)                    │
└──────────────────────────────────────────────────┘
```

**What this means:**
- **Reading**: Client sends key → index in RAM locates data on SSD → single SSD read → response in < 1ms
- **Cost**: You only need enough RAM for the index (~64 bytes/record), not for all data
- **100 million records**: ~6.4 GB RAM + ~100 GB SSD (vs ~100 GB RAM for Redis)

### 1.5 How a Read Works (Step by Step)

```
Your Java App                    Aerospike Cluster
     │                                │
     │  client.get(key)               │
     │ ──────────────────────────►    │
     │                                │
     │  1. Smart Client hashes        │
     │     the key to find which      │
     │     partition (0-4095) it      │
     │     belongs to                 │
     │                                │
     │  2. Smart Client knows which   │
     │     node owns that partition   │
     │     (learned at connection)    │
     │                                │
     │  3. Request goes DIRECTLY to   │
     │     the correct node           │
     │     (no proxy, no redirect)    │
     │                           ┌────▼────┐
     │                           │  Node 2 │
     │                           │         │
     │                           │ 4. Look │
     │                           │    up   │
     │                           │    index │
     │                           │    in   │
     │                           │    RAM  │
     │                           │         │
     │                           │ 5. Read │
     │                           │    data │
     │                           │    from │
     │                           │    SSD  │
     │                           │         │
     │  6. Return record         │         │
     │ ◄──────────────────────── └─────────┘
     │
     │  Total time: < 1ms
```

**Key insight**: There's **no central coordinator**. The client itself knows the cluster topology and routes requests directly. This is what the **"Smart Client"** means.

### 1.6 How a Write Works (Step by Step)

```
Your Java App                        Aerospike Node
     │                                    │
     │  client.put(writePolicy, key,      │
     │             bin1, bin2)            │
     │ ──────────────────────────────►    │
     │                                    │
     │  1. Smart Client routes to         │
     │     correct node (same as read)    │
     │                                    │
     │                               ┌────▼────────┐
     │                               │             │
     │                               │ 2. Write to │
     │                               │    in-memory │
     │                               │    write    │
     │                               │    buffer   │
     │                               │             │
     │                               │ 3. Update   │
     │                               │    primary  │
     │                               │    index    │
     │                               │    in RAM   │
     │                               │             │
     │                               │ 4. Flush    │
     │                               │    buffer   │
     │                               │    to SSD   │
     │                               │    (async)  │
     │                               │             │
     │                               │ 5. Replicate│
     │                               │    to other │
     │                               │    nodes    │
     │  6. Acknowledge               │             │
     │ ◄──────────────────────────── └─────────────┘
     │
     │  WritePolicy controls:
     │    - expiration (TTL in seconds)
     │    - timeout (max wait time)
     │    - commitLevel (master only vs all replicas)
```

### 1.7 Aerospike Key Concepts Summary

| Concept | What It Is | One-Liner |
|---------|-----------|-----------|
| **Cluster** | Group of Aerospike server nodes | The whole "database farm" |
| **Node** | One server running Aerospike | One machine in the cluster |
| **Namespace** | Top-level data container (like a DB) | Configured in `aerospike.conf`, has storage/replication settings |
| **Set** | Logical group within a namespace (like a table) | Optional, auto-created, no schema |
| **Record** | Single data entry (like a row) | Identified by a unique Key |
| **Key** | Unique identifier for a record | `Key(namespace, set, userKey)` |
| **Bin** | Named field in a record (like a column) | Schema-less, supports multiple data types |
| **TTL** | Time-to-live for a record | Auto-deletes record after N seconds; set per-write |
| **Primary Index** | Hash index of all keys (in RAM) | ~64 bytes per record, enables fast lookups |
| **Partition** | A chunk of data (4096 total) | Records are hash-distributed across partitions |
| **Smart Client** | Client that knows cluster topology | Routes requests directly to the right node |
| **WritePolicy** | Controls how writes behave | TTL, timeout, commit level, etc. |
| **BatchPolicy** | Controls how batch reads behave | Timeout, max concurrent threads, etc. |

### 1.8 CRUD Operations in Java (Quick Reference)

#### Create / Update (PUT)

```java
// Create a key
Key key = new Key("smartreminder", "agent", "12345");

// Create bins (fields)
Bin bin1 = new Bin("name", "Rupesh");
Bin bin2 = new Bin("isAgent", 1);

// Set write policy (TTL, timeout)
WritePolicy policy = new WritePolicy();
policy.expiration = 86400;  // auto-delete after 1 day (in seconds)

// Write to Aerospike
aerospikeClient.put(policy, key, bin1, bin2);
// If key exists → updates (overwrites)
// If key doesn't exist → creates
```

#### Read (GET)

```java
// Single record read
Key key = new Key("smartreminder", null, "HR_1001561216");
Record record = aerospikeClient.get(null, key);

if (record != null) {
    String hrData = (String) record.bins.get("HR");
    Boolean encrypted = (Boolean) record.bins.get("HR_ENCRYPTED_BIN");
}
```

#### Batch Read (GET multiple keys in one call)

```java
Key[] keys = new Key[] {
    new Key("smartreminder", null, "HR_100"),
    new Key("smartreminder", null, "HR_200"),
    new Key("smartreminder", null, "HR_300")
};

Record[] records = aerospikeClient.get(batchPolicy, keys);
// records[0] → data for HR_100 (or null if not found)
// records[1] → data for HR_200
// records[2] → data for HR_300
```

#### Delete

```java
Key key = new Key("smartreminder", null, "HR_1001561216");
boolean existed = aerospikeClient.delete(null, key);
// returns true if the key existed and was deleted
// returns false if the key didn't exist
```

#### Atomic Operations (operate)

```java
// Increment a counter AND get the new value — in ONE atomic operation
Key key = new Key("recharges_bff", "interstitial_data_set", "user_123");
Record record = aerospikeClient.operate(writePolicy, key,
    Operation.add(new Bin("seen_count", 1)),   // increment by 1
    Operation.get()                             // return the new value
);
// This is atomic — no race condition even with concurrent requests
```

### 1.9 Aerospike vs HashMap / ConcurrentHashMap

If you're a Java developer, this comparison helps:

| Feature | Java HashMap | Java ConcurrentHashMap | Aerospike |
|---------|-------------|----------------------|-----------|
| Speed | Fastest (in-process) | Fast (in-process) | < 1ms (network call) |
| Survives app restart? | No | No | Yes (persisted to SSD) |
| Shared across app instances? | No | No | Yes (central cluster) |
| Auto-expiry (TTL)? | No | No | Yes (per-record) |
| Scalable beyond 1 JVM? | No | No | Yes (add more nodes) |
| Data limit | JVM heap | JVM heap | TBs (SSD) |
| Thread-safe? | No | Yes | Yes (server-side) |
| Atomic increment? | No | Yes (compute) | Yes (operate) |

**When to use what:**
- **HashMap** — data needed only within a single request, no sharing
- **ConcurrentHashMap / in-memory singleton** — shared across threads in one JVM, OK to lose on restart
- **Aerospike** — shared across multiple app instances, must survive restarts, large datasets, need TTL

### 1.10 How Aerospike Differs from Other NoSQL Databases

| | Aerospike | Redis | MongoDB | Cassandra | DynamoDB |
|-|-----------|-------|---------|-----------|----------|
| **Type** | Key-Value + Document | Key-Value + Data Structures | Document | Wide-Column | Key-Value + Document |
| **Primary use** | Real-time caching & DB | Caching, pub/sub, queues | General purpose | Write-heavy analytics | Serverless cloud DB |
| **Latency** | < 1ms | < 1ms | 1-10ms | 1-10ms | 1-10ms |
| **Storage** | SSD-optimized | RAM-only (primarily) | Disk | Disk | Managed (AWS) |
| **Scaling** | Auto-rebalance | Manual resharding | Auto-shard | Ring topology | Auto (managed) |
| **Best for** | High-throughput, large-scale caching | Small-scale caching, queues, pub/sub | Flexible queries, aggregation | Time-series, logs | AWS-native apps |

---

## 2. Why Aerospike over Redis? (Interview Answer)

> **"We chose Aerospike over Redis because our BFF service handles millions of Paytm users' recharge reminders and frequent orders. We needed a caching layer that could handle large datasets with per-key TTLs, survive restarts without data loss, and scale horizontally without resharding complexity. Aerospike's hybrid memory architecture lets us keep indexes in RAM for sub-millisecond reads while storing actual cache data on SSDs, giving us massive capacity at a fraction of Redis's memory cost. Its built-in cluster management and automatic rebalancing also simplified our ops compared to Redis Cluster."**

Key reasons specific to this project:

| Reason | Explanation |
|--------|-------------|
| **Cost at scale** | Millions of `HR_<customerId>` and `OR_<customerId>` keys. Storing all in Redis RAM would be very expensive. Aerospike stores data on SSD with RAM-speed indexes. |
| **Persistence built-in** | We cache Saga responses (downstream recharge/bill data). Losing cache on restart means thundering herd to Saga service. Aerospike persists to SSD natively. |
| **Per-key TTL** | Different cache entries have different TTLs (end-of-day for thin banners, multi-day for smart reminders, 1 year for agent flags). Aerospike handles per-record expiration efficiently. |
| **Batch operations** | We use `getBatchData()` for interstitial data — fetching multiple keys in a single round trip. Aerospike's batch reads are optimized at the server level. |
| **Automatic cluster management** | Aerospike uses a shared-nothing architecture with automatic partition rebalancing. No need for sentinel/cluster proxy like Redis. |
| **Predictable latency under load** | Aerospike's log-structured storage and defragmentation ensure consistent sub-ms reads even at high write volumes. |

---

## 3. Aerospike vs Redis — Detailed Comparison

### 3.1 Architecture

| Aspect | Aerospike | Redis |
|--------|-----------|-------|
| **Storage engine** | Hybrid — indexes in RAM, data on SSD or RAM | Primarily in-memory, optional RDB/AOF persistence |
| **Data model** | Key → Record (with multiple Bins/fields) | Key → Value (strings, hashes, lists, sets, sorted sets) |
| **Clustering** | Built-in, automatic partition rebalancing via Smart Client | Redis Cluster with hash slots, manual resharding |
| **Replication** | Synchronous + asynchronous replication modes | Asynchronous replication (data loss risk on failover) |
| **Consistency** | Strong consistency mode available (AP or CP configurable) | Eventual consistency (async replication) |

### 3.2 Performance

| Aspect | Aerospike | Redis |
|--------|-----------|-------|
| **Read latency** | < 1ms (SSD), < 0.5ms (RAM) | < 0.5ms (all in RAM) |
| **Write latency** | < 1ms | < 0.5ms |
| **Throughput** | Millions of TPS per node | ~100K TPS per node (single-threaded core) |
| **Threading** | Multi-threaded (uses all CPU cores) | Single-threaded command processing (Redis 7 has I/O threads) |
| **Large datasets** | Excellent — SSD-optimized, handles TBs | Limited by RAM; Redis on Flash exists but is less mature |

### 3.3 Cost & Operations

| Aspect | Aerospike | Redis |
|--------|-----------|-------|
| **Memory cost** | Low — only indexes (~64 bytes/record) in RAM; data on SSD | High — all data must fit in RAM |
| **10 million keys, 1KB each** | ~640 MB RAM + 10 GB SSD | ~10 GB RAM |
| **100 million keys, 1KB each** | ~6.4 GB RAM + 100 GB SSD | ~100 GB RAM (need cluster) |
| **Persistence** | Native, zero-config | Requires RDB snapshots or AOF (adds latency/disk I/O) |
| **TTL management** | Per-record, efficient background eviction | Per-key, lazy + periodic eviction |
| **Cluster ops** | Auto-rebalance on add/remove nodes | Manual slot migration, risk of downtime |

### 3.4 When to Choose What

| Choose Aerospike When | Choose Redis When |
|----------------------|-------------------|
| Dataset > available RAM | Dataset fits comfortably in RAM |
| Need persistence with sub-ms latency | Need rich data structures (sorted sets, streams, pub/sub) |
| Millions of TPS required | Need Lua scripting or complex transactions |
| Cost-sensitive at scale | Need pub/sub messaging |
| Automatic cluster management needed | Simpler operational model preferred |
| Strong consistency required | Caching small datasets with simple get/set |

### 3.5 Key Differentiators for Interviews

**Hybrid Memory Architecture (HMA)**
- Aerospike keeps a **primary index in RAM** (~64 bytes per record) and stores actual data on **SSDs**.
- This means you get **RAM-like read performance** at **SSD cost**.
- Redis stores everything in RAM — 10x-50x more expensive for large datasets.

**Smart Client**
- Aerospike client knows the partition map and routes requests **directly to the correct node**.
- No proxy layer needed. Reduces latency by eliminating an extra network hop.
- Redis Cluster requires clients to handle MOVED/ASK redirections or use a proxy.

**Cross-Datacenter Replication (XDR)**
- Aerospike has built-in **XDR** for geo-replication across data centers.
- Redis requires third-party tools or Redis Enterprise for similar functionality.

---

## 4. How Aerospike is Used in recharges-bff

### 4.1 Configuration

**Two Aerospike clusters are configured** (though V2 is currently a placeholder):

```
aerospike:           # Primary cluster
  host: 10.4.41.167
  port: 3000

aerospike-v2:        # Secondary cluster (placeholder)
  host: 10.4.41.167
  port: 3000
```

**Spring Bean setup** (`AerospikeConfiguration.java`):
- `AerospikeClient` bean with `failIfNotConnected = false` (graceful degradation)
- `AerospikeCacheManager` using namespace `"smartreminder"` for Spring Cache abstraction

**Local development** uses Docker (Aerospike 6.4.0.10 on port 3000).

### 4.2 Wrapper/Client Classes

| Class | Purpose |
|-------|---------|
| `AerospikeGenericWrapper` | Generic CRUD — `putData()`, `getData()`, `getBatchData()` with metrics |
| `AgentAeroSpikeClientWrapper` | Agent detection — `putAgentCustomerId()`, `isAgent()`, vehicle details |
| `EvictCacheServiceImpl` | Cache eviction — `evictCache()`, `evictOverrideCache()`, `upsertCache()` |
| `AerospikeInterstitialRepository` | Interstitial-specific batch reads |
| `AerospikeV2GenericWrapper` | Placeholder for V2 cluster (methods commented out) |

### 4.3 Services That Use Aerospike

| Service | What it caches |
|---------|---------------|
| `FavouriteManagerImpl` | Home Reminder (HR) responses, Thin Banner (TB) responses, personalisation overrides |
| `EvictCacheServiceImpl` | Cache eviction for HR, OR, TB keys |
| `RequestBlockServiceImpl` | Request blocking/throttling data |
| `RechargeVerifyServiceImpl` | Async verify flags (7-day TTL) |
| `PlanMappingService` | Plan mapping locks (~59 min TTL) |
| `FavouriteServiceImpl` | Favourite orders data |
| `FastagRequestHandler` | FASTag VRN (vehicle registration) cache |
| `CarDetailService` | Car details and images for FASTag |
| `FuzzySearchService` | Fuzzy color matching results |
| `CleverTapServiceImpl` | CleverTap segment data (1 hour TTL) |
| `InterstitialUtils` | Atomic counters for interstitial impression tracking |

---

## 5. Key Data Model — Namespaces, Sets, Bins

### 5.1 Namespace: `smartreminder`

This is the primary namespace used across most features.

| Key Pattern | Set | Bin(s) | Data | TTL |
|-------------|-----|--------|------|-----|
| `HR_<customerId>` | `null` | `HR`, `HR_ENCRYPTED_BIN` | `ArrayList<SagaRecentResponse>` (serialized/encrypted) | End of day OR multi-day (configurable) |
| `TB_<customerId>` | `null` | `RU_RECO` | `HomeReminderResponse` (thin banner) | End of current day |
| `OR_<customerId>` | `null` | Various | Override/order response data | Varies |
| `<customerId>` | `agent` | `SMARTREMINDER_AGENT_BIN` | Agent flag (`"1"`) | 1 year |
| `<variantId>` | `vehicaldetail` | Vehicle bins | Car detail data | Configurable |
| `<makeId_modelId>` | `carImages` | Image URL map | Car image URLs by color | Configurable |
| `<key>` | `fuzzyColor` | Color match results | Fuzzy matched color strings | Configurable (days) |
| `<key>` | `fastagVrn` | VRN data | FASTag vehicle registration | Configurable |
| `<key>` | `segmentSet` | Segment data | CleverTap segment info | 3600 seconds (1 hour) |
| `<key>` | `orderCountSet` | Count bins | Order counts (upsert API) | From request TTL |

### 5.2 Namespace: `recharges_bff`

| Key Pattern | Set | Bin(s) | Data | TTL |
|-------------|-----|--------|------|-----|
| `<key>` | `request_block_data_set` | Block data | Request blocking info | `(blockCacheTtl + 1) * 86400` |
| `<key>` | `interstitial_data_set` | Interstitial bins + counter | Interstitial config + seen count | End of month/day/cool-off |
| `<key>` | `plan_mapping` | Lock data | Plan mapping lock | 3540 seconds (~59 min) |
| `<productId>` | `asyncVerifyFlags` | Flag data | Async verify flags | 7 days |

---

## 6. HomeReminder API — Deep Dive

### 6.1 API Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/favourite/v1/homepage/reminders` | Fetch home reminder widgets (legacy list) |
| POST | `/favourite/v1/homepage/reminders` | Fetch home reminder widgets (v3 with RU Reco) |

### 6.2 Request Flow

```
Frontend
  │
  ▼
FavouritesController.getHomeRemainder()  (GET)
FavouritesController.getHomeRemainderV2() (POST)
  │
  ├─ JWT validation (homeReminderProperties.secretKey)
  │
  ▼
FavouriteManagerImpl.getHomeReminderResponse()       (GET)
FavouriteManagerImpl.getHomeReminderResponseV3()     (POST)
  │
  ├─ 1. Check if user is AGENT ──► AgentAeroSpikeClientWrapper.isAgent()
  │     └─ Aerospike GET: Key(smartreminder, "agent", customerId)
  │     └─ If agent → return empty (agents don't see reminders)
  │
  ├─ 2. Read HR cache ──► Aerospike GET: Key(smartreminder, null, "HR_<customerId>")
  │     └─ Cache HIT  → deserialize ArrayList<SagaRecentResponse>
  │     └─ Cache MISS → call Saga downstream ↓
  │
  ├─ 3. Saga call (on cache miss)
  │     └─ sagaClientManager.getFrequentOrdersFromSaga()
  │     └─ On success → write to Aerospike (read-through cache pattern)
  │        Key(smartreminder, null, "HR_<customerId>"), Bin("HR", serialized data)
  │
  ├─ 4. Filter, sort, enrich
  │     └─ recoWidgetService.prepareFavResponse()
  │     └─ createResponse()
  │
  ├─ 5. Convert to HomeReminderResponse list
  │     └─ convertToHRResponseForMultipleViewIds()
  │
  └─ 6. (POST only) Thin Banner cache
        └─ Aerospike GET: Key(smartreminder, null, "TB_<customerId>")
        └─ Cache MISS → build thin banner → write to Aerospike
           Key(smartreminder, null, "TB_<customerId>"), Bin("RU_RECO", data)
```

### 6.3 Aerospike Interactions in HomeReminder

| Operation | Key | Bin | Direction | TTL |
|-----------|-----|-----|-----------|-----|
| Agent check | `smartreminder/agent/<customerId>` | `SMARTREMINDER_AGENT_BIN` | READ | 1 year (written elsewhere) |
| HR cache read | `smartreminder/null/HR_<customerId>` | `HR` | READ | — |
| HR cache write (on miss) | `smartreminder/null/HR_<customerId>` | `HR` (+optional encrypted bin) | WRITE | End-of-day (empty result) or multi-day (from config) |
| Thin banner read | `smartreminder/null/TB_<customerId>` | `RU_RECO` | READ | — |
| Thin banner write (on miss) | `smartreminder/null/TB_<customerId>` | `RU_RECO` | WRITE | End of current day |

### 6.4 Encryption Support

The HR cache supports **encrypted storage** controlled by feature flags:
- If encryption rollout is enabled for the customer, the Saga response is **encrypted** before writing to bin `HR` and a boolean flag is set in `HR_ENCRYPTED_BIN`.
- On read, if the encrypted flag is present, the data is **decrypted** before deserialization.

### 6.5 Why Cache HR Data?

- **Saga service** is a shared downstream that multiple Paytm services call. Caching reduces load.
- Home screen reminders are **read-heavy** (every app open) but data changes infrequently (bills cycle monthly).
- **End-of-day TTL** ensures fresh data each day while avoiding repeated Saga calls within the same day.
- **Empty result caching** (`"[]"`) prevents repeated calls for users with no reminders.

---

## 7. FrequentOrders V5 API — Deep Dive

### 7.1 API Endpoint

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/favourite/{channelId}/v5/frequentOrders` | Get frequent/recent orders with card skins |

### 7.2 Request Flow

```
Frontend
  │
  ▼
FavouritesController.getFrequentOrdersV5()
  │
  ├─ Extract customerId from headers
  ├─ Set apiVersion = "v5" in params
  │
  ▼
FavouriteManagerImpl.getFrequentOrdersByCustomerIdV2()
  │
  ├─ 1. Parallel async calls:
  │     ├─ prepareCallForRecentsFromSaga() ──► Saga "recents" API
  │     ├─ prepareDataForRecentGet()       ──► Favourite Orders service
  │     └─ callForSMSCards()               ──► SMS cards
  │
  ├─ 2. combineRecents()
  │     └─ Wait on Saga + favourite futures
  │     └─ Merge, CLP sort, handle ambiguous product IDs
  │
  ├─ 3. Saved Cards (V5 specific)
  │     └─ sagaManager.getSavedCardsFromSagaV2()
  │     └─ V5 + config → isCardSkinRequired = true on Saga request
  │
  ├─ 4. Merge saved cards + SMS cards + dedup
  │     └─ recentGenerator.mergeSavedCardsWithCoft()
  │     └─ mergeSMSCards()
  │
  └─ 5. createResponse(frequentOrderArrayList, isApiV5Version=true)
        └─ redirectToPlansCheck() — V5-only: populateChangeUserPlansOperator for Mobile
```

### 7.3 V5 vs V3 Differences

| Aspect | V3 | V5 |
|--------|-----|-----|
| Card skin support | No | Yes — `isCardSkinRequired` sent to Saga |
| User plans for Mobile | No | Yes — `populateChangeUserPlansOperator()` adds change-plan CTA |
| Downstream Saga request | Basic recents | Recents + card skin data |
| Same service method | `getFrequentOrdersByCustomerIdV2()` | Same (branched by `apiVersion` flag) |

### 7.4 Aerospike Usage in V5

**The V5 GET frequent-orders path does NOT directly use Aerospike in this BFF.**

The data flow is entirely through HTTP calls to downstream services (Saga, Favourite Orders service). Caching for frequent orders happens at the **downstream service level**, not in this BFF.

However, the V5 response data that comes from Saga **is** the same data that gets cached in the `HR_` keys for the HomeReminder API. The two APIs share the same underlying data source (Saga), but have different caching strategies:

| API | Caches in Aerospike? | Reason |
|-----|---------------------|--------|
| HomeReminder (HR) | Yes — `HR_<customerId>` | Called on every app open (very high frequency), data changes slowly |
| FrequentOrders V5 | No (in this BFF) | Called less frequently, needs real-time accuracy for card skins/saved cards |

---

## 8. Cache Eviction API

### 8.1 Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/evictcache` | Delete HR, OR, and TB cache keys for a customer |
| POST | `/evictOrCache` | Delete override cache keys only |

### 8.2 How Eviction Works

When you call `/evictcache` with `cacheKey: ["HR_1001561216"]`:

1. Parses the key — extracts `1001561216` from `HR_1001561216`
2. Deletes **three keys** from Aerospike:
   - `Key(smartreminder, null, "HR_1001561216")` — the original key as-is
   - `Key(smartreminder, null, "OR_1001561216")` — the OR (order response) key
   - `Key(smartreminder, null, "TB_1001561216")` — the TB (thin banner) key

```
POST /evictcache
{
    "cacheKey": ["HR_1001561216"]
}

Response:
{
    "statusCode": 200,
    "displayMessage": "All keys are evicted successfully"
}
```

### 8.3 When Is Eviction Used?

- After a user completes a recharge/bill payment (stale reminder data)
- Manual ops intervention when a user reports stale data
- After downstream data corrections
- During debugging to force fresh data fetch

---

## 9. Agent Detection Flow

"Agents" are customer service representatives who should not see personal reminders.

```
AgentAeroSpikeClientWrapper.isAgent(customerId)
  │
  ├─ Key: smartreminder / "agent" / <customerId>
  ├─ Read bin: SMARTREMINDER_AGENT_BIN_NAME
  └─ If value == "1" → user is an agent → skip HomeReminder data

AgentAeroSpikeClientWrapper.putAgentCustomerId(customerId)
  │
  ├─ Key: smartreminder / "agent" / <customerId>
  ├─ Bin: SMARTREMINDER_AGENT_BIN_NAME = "1"
  └─ TTL: 1 year (365 * 24 * 60 * 60 seconds)
```

---

## 10. TTL Strategy

| Data | TTL | Rationale |
|------|-----|-----------|
| HR cache (non-empty) | Multi-day (configurable via `RecentUtils.getSmartReminderTTL()`) | Bills change monthly; refresh every few days |
| HR cache (empty result) | End of current day (`86400 - secondsSinceMidnight`) | User might add a recharge; check again tomorrow |
| Thin banner (TB) | End of current day | Banner is a daily UI widget |
| Agent flag | 1 year | Agent status rarely changes |
| CleverTap segments | 1 hour (3600s) | Segment membership changes frequently |
| Request block data | `(blockCacheTtl + 1) days` | Block duration + 1 day buffer |
| Plan mapping lock | ~59 minutes (3540s) | Short-lived lock for plan sync |
| Async verify flags | 7 days | Verification state valid for a week |
| FASTag VRN | Configurable | Vehicle data changes rarely |
| Interstitial counters | End of month / end of day / cool-off | Impression caps reset on period boundaries |

**Key insight for interviews:** TTL is always set **per-write** on the `WritePolicy`, not as a global namespace default. This gives fine-grained control over different data types sharing the same namespace.

---

## 11. Caching Patterns Used

### 11.1 Read-Through (Cache-Aside)

Used for **HomeReminder (HR)** data:

```
1. Read from Aerospike (HR_<customerId>)
2. If HIT → return cached data
3. If MISS → call Saga downstream
4. Write response to Aerospike with TTL
5. Return response
```

**Special behavior:** If Saga returns empty, BFF still caches `"[]"` with end-of-day TTL to avoid repeated calls for users with no reminders.

### 11.2 Write-Through (on Eviction)

The `/evictcache` API performs **explicit invalidation** — it deletes the key so the next read triggers a fresh fetch.

### 11.3 Atomic Counters

Used for **interstitial impression tracking**:

```java
aerospikeClient.operate(writePolicy, key,
    Operation.add(new Bin(INTERSTITIAL_SEEN_COUNT_BIN, 1)),
    Operation.get()
);
```

Aerospike's `operate()` performs atomic increment + get in a single server-side operation — no race conditions.

### 11.4 Batch Reads

Used for **interstitial data** — fetch multiple user records in a single round trip:

```java
Record[] records = aerospikeClient.get(batchPolicy, keys);
```

---

## 12. Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                         Frontend (App)                           │
└───────┬──────────────────────┬───────────────────────┬───────────┘
        │                      │                       │
  GET /homepage/         GET /v5/frequent       POST /evictcache
    reminders              Orders
        │                      │                       │
┌───────▼──────────────────────▼───────────────────────▼───────────┐
│                      recharges-bff                               │
│                                                                  │
│  ┌─────────────┐  ┌─────────────────┐  ┌──────────────────────┐ │
│  │ Favourites  │  │  Favourites     │  │  EvictCache          │ │
│  │ Controller  │  │  Controller     │  │  Controller          │ │
│  │ (HR GET/    │  │  (V5 GET)       │  │  (POST)              │ │
│  │  POST)      │  │                 │  │                      │ │
│  └──────┬──────┘  └────────┬────────┘  └──────────┬───────────┘ │
│         │                  │                      │             │
│  ┌──────▼──────────────────▼──────────────────────▼───────────┐ │
│  │                FavouriteManagerImpl                         │ │
│  │         (+ EvictCacheServiceImpl for eviction)             │ │
│  └──────┬─────────────┬────────────────────┬──────────────────┘ │
│         │             │                    │                    │
│    ┌────▼────┐  ┌─────▼─────┐   ┌─────────▼──────────┐        │
│    │Aerospike│  │   Saga    │   │ Favourite Orders    │        │
│    │ Cache   │  │  Client   │   │     Client          │        │
│    │(HR/TB/  │  │           │   │                     │        │
│    │ Agent)  │  │           │   │                     │        │
│    └────┬────┘  └─────┬─────┘   └─────────┬──────────┘        │
└─────────┼─────────────┼───────────────────┼────────────────────┘
          │             │                   │
   ┌──────▼──────┐ ┌────▼─────┐  ┌──────────▼──────────┐
   │  Aerospike  │ │  Saga    │  │ Favourite Orders    │
   │  Cluster    │ │  Service │  │     Service         │
   │ (port 3000) │ │          │  │                     │
   └─────────────┘ └──────────┘  └─────────────────────┘
```

---

## 13. Common Interview Questions & Answers

### Q1: "What is Aerospike and why did you use it?"

> Aerospike is a distributed key-value NoSQL database with a hybrid memory architecture — indexes in RAM, data on SSD. We used it in our BFF service to cache downstream API responses (like bill reminders from Saga service) to reduce latency and load on downstream systems. It was chosen over Redis because our cache size scales with the user base (millions of keys), and storing all that in RAM would be prohibitively expensive. Aerospike's SSD-optimized storage gave us sub-millisecond reads at a fraction of the cost.

### Q2: "How is data organized in Aerospike?"

> Aerospike uses a hierarchy: **Namespace** (like a database) → **Set** (like a table, optional) → **Record** (identified by a Key, containing multiple Bins/columns). In our service, we have two namespaces — `smartreminder` for user-facing cache data (reminders, agent flags, vehicle details) and `recharges_bff` for internal operational data (request blocking, interstitial tracking). Each record has multiple bins; for example, the HR record has an `HR` bin for the serialized response and an `HR_ENCRYPTED_BIN` flag for encryption status.

### Q3: "Explain the caching strategy for HomeReminder."

> We use a **read-through (cache-aside)** pattern. When the app requests home reminders:
> 1. We first check Aerospike for `HR_<customerId>`
> 2. On cache hit, we return the cached Saga response
> 3. On cache miss, we call the Saga downstream service, cache the response with a configurable multi-day TTL, and return it
> 4. Even empty results are cached with an end-of-day TTL to prevent thundering herd
> 5. When a user completes a payment, we explicitly evict their cache via the `/evictcache` API
>
> This works well because bill reminders change infrequently (monthly billing cycles) but are read on every app open.

### Q4: "What's the difference between `smartreminder` and `recharges_bff` namespaces?"

> `smartreminder` holds user-facing data with longer TTLs — home reminders, thin banners, agent flags, vehicle details, order overrides. It's the "hot" customer-centric cache.
>
> `recharges_bff` holds operational/internal data — request blocking (rate limiting), interstitial impression counters, plan mapping locks, async verify flags. This data is more transient and service-internal.

### Q5: "How do you handle cache invalidation?"

> Three mechanisms:
> 1. **TTL-based expiration** — most records auto-expire (end-of-day, multi-day, 1 hour, etc.)
> 2. **Explicit eviction** — the `/evictcache` API deletes specific customer keys (HR, OR, TB) when data changes
> 3. **Atomic operations** — interstitial counters use `operate()` for atomic increment, avoiding stale-read issues

### Q6: "What happens if Aerospike is down?"

> The service is designed for **graceful degradation**:
> - `failIfNotConnected = false` in `ClientPolicy` — the app starts even if Aerospike is unavailable
> - Every Aerospike call is wrapped in try-catch — on failure, the service falls through to the downstream call (Saga, etc.)
> - Metrics (`hr_error_in_get_cache`, `aerospike_error`, etc.) track failures for alerting
> - The BFF never throws an error to the frontend due to a cache failure; it just becomes slower (direct downstream calls)

### Q7: "Why not use Spring `@Cacheable` with Aerospike?"

> Although we have `AerospikeCacheManager` configured, we use the raw `AerospikeClient` directly because:
> - We need **per-key TTLs** (different data types have different expiration logic)
> - We need **multi-bin records** (a single key can have `HR` bin + `HR_ENCRYPTED_BIN`)
> - We need **batch operations** (`getBatchData` for interstitial)
> - We need **atomic operations** (`operate()` for counters)
> - `@Cacheable` is too simplistic for these use cases

### Q8: "How do you handle the 'thundering herd' problem?"

> Two strategies:
> 1. **Empty result caching** — if Saga returns no data, we cache `"[]"` until end-of-day. This prevents millions of "no-data" users from hammering Saga.
> 2. **Plan mapping locks** — for plan sync operations, we use Aerospike as a distributed lock with ~59-minute TTL to prevent concurrent processing of the same plan mapping.

### Q9: "What monitoring do you have for Aerospike?"

> We track:
> - **Latency:** `aerospike_put`, `aerospike_get`, `aerospike_batch_get` timing via `metricsAgent.recordExecutionTimeOfEvent()`
> - **Errors:** `hr_error_in_save_cache`, `hr_error_in_get_cache`, `block_req_error_in_save_cache`, `aerospike_error` counters
> - **Cache misses:** `hr_not_found_in_cache`, `block_req_not_found_in_cache`
> - **Business metrics:** `hr_response_count` for reminder widget counts
> All metrics are exposed on the Prometheus endpoint (port 8130).

### Q10: "How does the evict cache API work internally?"

> When we receive `{"cacheKey": ["HR_1001561216"]}`:
> 1. Parse the key — extract the numeric customer ID (`1001561216`) from the suffix
> 2. Construct and delete **three** Aerospike keys:
>    - `HR_1001561216` (the reminder cache)
>    - `OR_1001561216` (the order response cache)
>    - `TB_1001561216` (the thin banner cache)
> 3. This ensures all related caches for that customer are invalidated atomically
> 4. The next HR/TB request for this customer will trigger a fresh Saga call

---

## Bonus: Key Code Snippets to Reference in Interviews

### Aerospike Write with Per-Record TTL

```java
WritePolicy policy = new WritePolicy(aerospikeClient.writePolicyDefault);
policy.expiration = expireTimeInSec;  // per-record TTL
policy.setTimeout(timeoutInMs);
aerospikeClient.put(policy, key, bins);
```

### Atomic Counter (Interstitial)

```java
aerospikeClient.operate(writePolicy, key,
    Operation.add(new Bin(INTERSTITIAL_SEEN_COUNT_BIN, 1)),
    Operation.get()
);
```

### Batch Read (Multiple Keys in One Call)

```java
Key[] keys = keyNames.stream()
    .map(keyName -> new Key(namespace, setName, keyName))
    .toArray(Key[]::new);
BatchPolicy batchPolicy = new BatchPolicy(aerospikeClient.batchPolicyDefault);
Record[] records = aerospikeClient.get(batchPolicy, keys);
```

### Graceful Degradation Pattern

```java
ClientPolicy clientPolicy = new ClientPolicy();
clientPolicy.failIfNotConnected = false;  // don't crash if Aerospike is down
```
