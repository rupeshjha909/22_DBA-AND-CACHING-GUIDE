# Elasticsearch in digital_reminder_rule_engine — Interview Preparation Guide

## Table of Contents

1. [Elasticsearch Fundamentals — Learn from Zero](#1-elasticsearch-fundamentals--learn-from-zero)
2. [Why Elasticsearch (and Percolator) over the Alternatives?](#2-why-elasticsearch-and-percolator-over-the-alternatives-interview-answer)
3. [Elasticsearch vs Other Stores — Detailed Comparison](#3-elasticsearch-vs-other-stores--detailed-comparison)
4. [How Elasticsearch is Used in this Repo](#4-how-elasticsearch-is-used-in-this-repo)
5. [Data Model — Indices, Documents, Fields, Mappings](#5-data-model--indices-documents-fields-mappings)
6. [The Percolator Pattern — The Core Idea](#6-the-percolator-pattern--the-core-idea)
7. [Client Configuration — Deep Dive](#7-client-configuration--deep-dive)
8. [The Percolator Query Service — Deep Dive](#8-the-percolator-query-service--deep-dive)
9. [Reading the Response — `_percolator_document_slot` & Rule Limiting](#9-reading-the-response--_percolator_document_slot--rule-limiting)
10. [Resilience — Failover, Circuit Breaker, Retry, Metrics](#10-resilience--failover-circuit-breaker-retry-metrics)
11. [TTL / Index Lifecycle Strategy](#11-ttl--index-lifecycle-strategy)
12. [Local Setup & Operating the Indices](#12-local-setup--operating-the-indices)
13. [Architecture Diagram](#13-architecture-diagram)
14. [Common Interview Questions & Answers](#14-common-interview-questions--answers)
15. [Bonus — Key Code Snippets to Reference](#15-bonus--key-code-snippets-to-reference)

---

## 1. Elasticsearch Fundamentals — Learn from Zero

### 1.1 What is Elasticsearch?

Think of Elasticsearch as a **librarian who has already read every book** in the library.

- It's a **NoSQL document database** — it stores JSON documents, not rows and columns.
- It's a **search and analytics engine** — built on Apache Lucene, optimized to answer *"which
  documents match this query?"* in milliseconds, even across billions of documents.
- It's **distributed** — data is split into *shards* spread across multiple servers (*nodes*),
  with replicas for high availability.
- It uses an **inverted index** — instead of scanning every document, it pre-builds a map of
  `term → list of documents that contain it`, so lookups are near-instant.

**In plain English:** A normal database is a filing cabinet — to find something, you open drawers
and read folders. Elasticsearch is a librarian who already memorized which page of which book
mentions every word, so the moment you ask, the answer comes back.

### 1.2 How Elasticsearch Stores Data (The Data Model)

Elasticsearch has a clean hierarchy. Here's the analogy to a relational database:

```
┌──────────────────────────────────────────────────────────────────┐
│                       ELASTICSEARCH CLUSTER                       │
│                   (a group of servers / nodes)                    │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                          INDEX                              │  │
│  │                  (like a "table" in MySQL)                  │  │
│  │             e.g. "automatic", "dropoff", "rent"             │  │
│  │                                                            │  │
│  │   Has a MAPPING (the schema: field name -> field type)     │  │
│  │   Is split into SHARDS (+ REPLICAS) for scale & HA         │  │
│  │                                                            │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │                      DOCUMENT                         │  │  │
│  │  │                (like a "row" in MySQL)                │  │  │
│  │  │            A JSON object with an _id                  │  │  │
│  │  │                                                      │  │  │
│  │  │   Contains FIELDS (like columns):                    │  │  │
│  │  │     "query":      { ...a stored ES query... }        │  │  │
│  │  │     "priority":   10                                 │  │  │
│  │  │     "ruleStatus": 1                                  │  │  │
│  │  │     "metaData":   { ...action config... }            │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

#### INDEX (= Table)

The top-level container for documents that share a **mapping** (schema).

- Each index has a **mapping** that declares field names and their types.
- Each index is split into **shards** (Lucene indices) for horizontal scale, plus **replicas**
  for HA and read throughput.

**In this repo** we use **three indices**, one per reminder service:
`automatic`, `dropoff`, `rent`. Each stores reminder **rules**.

#### DOCUMENT (= Row)

A single JSON object, identified by an `_id`.

**In this repo**, one document = one **reminder rule** (`ESRuleEngine`), e.g.
*"if service=mobile and amount>100, send a push using template 4567."*

#### FIELD (= Column)

A named key inside a document, with a declared **type** in the mapping.

**In this repo**, the key fields are `query`, `priority`, `ruleStatus`, `metaData`.

#### MAPPING (= Schema/DDL)

The mapping declares each field's type: `text`, `keyword`, `integer`, `object`, and the special
`percolator` type. The mapping is what makes ES behave correctly — get it wrong and queries
silently mismatch.

### 1.3 Complete MySQL-to-Elasticsearch Mapping

| MySQL Concept | Elasticsearch Concept | Example in this repo |
|---------------|-----------------------|----------------------|
| Database/Schema | **Cluster / Index namespace** | the ES cluster behind `reminder-esclient1/2` |
| Table | **Index** | `automatic`, `dropoff`, `rent` |
| Row | **Document** | one reminder rule (`ESRuleEngine`) |
| Primary Key | **`_id`** | `rule-mobile-due-001` |
| Column | **Field** | `query`, `priority`, `ruleStatus`, `metaData` |
| Column type | **Field type (mapping)** | `percolator`, `integer`, `keyword`, `object` |
| `WHERE` clause | **Query DSL** | `bool/must/term/range` |
| Index (B-tree) | **Inverted index** | built automatically per field |
| `SELECT ... ORDER BY` | **search + sort** | sort by `priority asc` |

### 1.4 Normal Search vs. Percolation (read this twice)

This is the single most important concept for this repo.

**Normal search flow** (what most people think ES does):

```
You STORE documents (events, products, logs...).
You SEND a query.
ES returns the DOCUMENTS that match the query.
```

**Percolator flow** (what THIS repo does — the reverse):

```
You STORE queries (the business rules).
You SEND documents (incoming events).
ES returns the QUERIES (rules) that match the documents.
```

> Memorize this inversion. Everything in this codebase is built on it: business rules are stored
> *as queries*, and incoming payment/recharge events are matched against them.

### 1.5 Field types you'll meet here

| Type | Meaning | Used for |
|------|---------|----------|
| `text` | analyzed/tokenized full-text | (not central here) |
| `keyword` | exact-match string | IDs, enums (`service`, `operator`) |
| `integer` / `long` | numeric, sortable, range-queryable | `priority`, `ruleStatus`, `category_id` |
| `object` | nested JSON; `enabled:false` = store but don't index | `metaData` |
| **`percolator`** | **stores a *query* so it can be matched against incoming docs** | **`query`** ← the crux |

### 1.6 How a Percolate Query Works (Step by Step)

```
Your Java App                          Elasticsearch
     │                                      │
     │  search(percolate query)             │
     │ ───────────────────────────────────► │
     │   index = "automatic"                │
     │   field = "query"                    │
     │   documents = [event0, event1, ...]  │
     │                                      │
     │                              1. For each stored rule (a
     │                                 percolator query), ES checks:
     │                                 "does this rule match any of
     │                                  the incoming event docs?"
     │                                      │
     │                              2. Collect matching rules as HITS,
     │                                 each tagged with which event
     │                                 indexes it matched
     │                                 (_percolator_document_slot)
     │                                      │
     │                              3. Sort hits by "priority" asc
     │                                      │
     │  SearchResponse<ESRuleEngine>        │
     │ ◄─────────────────────────────────── │
     │   hits = matched rules               │
     │   each hit.source() = the rule       │
     │   each hit.fields()  = slots         │
     │
     │  Total time: a few ms (recorded as ES_QUERY_LATENCY_TAG)
```

### 1.7 Elasticsearch Key Concepts Summary

| Concept | What it is | One-liner |
|---------|-----------|-----------|
| **Cluster** | Group of ES nodes | the whole search farm |
| **Node** | One ES server | one machine |
| **Index** | Document collection w/ a mapping | like a table (`automatic`/`dropoff`/`rent`) |
| **Shard** | A partition of an index (a Lucene index) | enables horizontal scale |
| **Replica** | A copy of a shard | HA + read throughput |
| **Document** | A JSON object with an `_id` | like a row (a reminder rule) |
| **Field** | A named key with a type | like a column |
| **Mapping** | The index schema | field name → type |
| **Inverted index** | term → docs containing it | why search is fast |
| **Query DSL** | JSON description of a match | like a `WHERE` clause |
| **Percolator** | A field type storing *queries* | match docs against stored queries |
| **Hit** | A returned document + metadata | one result row |
| **`_percolator_document_slot`** | which input docs a rule matched | per-hit array of indexes |

### 1.8 The ES Java Client Layers (what this repo uses)

The modern **Elasticsearch Java API Client (7.x, `co.elastic.clients`)** is built in three layers,
all wired up in `ElasticSearchConfig`:

```
RestClient  (Apache HttpClient — hosts, timeouts, failover, node selection)
   └─ wrapped by → RestClientTransport  (+ JSON mapper for (de)serialization)
        └─ wrapped by → ElasticsearchClient  (typed, fluent API your code calls)
```

> **Important:** although `spring-boot-starter-data-elasticsearch` is on the classpath, this repo
> does **NOT** use Spring Data repositories or `ElasticsearchRestTemplate`. It uses the typed
> `ElasticsearchClient` directly, because percolation needs a hand-built query that the repository
> abstraction can't express cleanly. (More in Q&A.)

---

## 2. Why Elasticsearch (and Percolator) over the Alternatives? (Interview Answer)

> **"We use Elasticsearch as a *rule engine*, not a search engine. Business teams configure
> hundreds of reminder rules — 'if service=mobile and amount>X, send a push with template Y'. The
> naive approach is to store those rules in a database and evaluate them one by one in application
> code for every incoming event, which is O(rules × events) and couples rule logic into deploys.
> Instead, we store each rule as an Elasticsearch *percolator query*. When a batch of payment
> events arrives over Kafka, we send the events to ES in a single percolate call and ES tells us
> exactly which rules match — leveraging its inverted index to do the matching efficiently inside
> the engine. Rules can be added, edited, enabled, or disabled by re-indexing a document, with no
> code change or redeploy. That's the core reason: ES turns 'evaluate N business rules per event'
> into one optimized query, and makes the rules data-driven."**

Reasons specific to this project:

| Reason | Explanation |
|--------|-------------|
| **Rules as data, not code** | Rules are stored documents; toggling/adding rules needs no deploy. |
| **One query instead of N** | One `percolate` call matches a batch of events against *all* stored rules. |
| **Inverted index efficiency** | ES uses Lucene's index to avoid brute-force rule-by-rule scanning. |
| **Priority ordering built-in** | Matched rules come back sorted by `priority`, so precedence is handled by ES. |
| **Batching** | A batch of event payloads is percolated together; `_percolator_document_slot` maps results back to each event. |
| **Operational maturity** | Dual-node failover, replicas, and well-understood scaling. |

---

## 3. Elasticsearch vs Other Stores — Detailed Comparison

### 3.1 Percolator vs. evaluating rules in application code

| Aspect | Rules-in-code (if/else, DB rows) | ES Percolator (this repo) |
|--------|----------------------------------|---------------------------|
| Complexity per event | O(rules) — loop every rule | One percolate call; ES does the matching |
| Changing a rule | Code change + deploy, or custom DB engine | Re-index one document |
| Enable/disable a rule | Code/flag + deploy | Set `ruleStatus`, re-index |
| Priority/precedence | Hand-rolled sorting | `sort: priority asc` in the query |
| Batch matching | Manual nested loops | `documents: [...]` in one call |
| Risk | Logic drift across services | Single source of truth in ES |

### 3.2 Elasticsearch vs. relational DB (MySQL)

| Aspect | MySQL | Elasticsearch |
|--------|-------|---------------|
| Data model | Rows & columns, fixed schema | JSON docs, flexible mapping |
| Strength | Transactions, joins, strong consistency | Full-text search, scoring, **percolation**, analytics |
| Match direction | Query → rows | Both: query → docs, **or docs → queries (percolator)** |
| Scale-out | Harder (sharding bolt-on) | Native sharding + replicas |
| Use here | Not used for rule matching | Stores rules as percolator queries |

### 3.3 Elasticsearch vs. Aerospike/Redis (key-value caches)

| Aspect | Aerospike / Redis | Elasticsearch |
|--------|-------------------|---------------|
| Access pattern | Get/put by exact key | Match by *query* over many fields |
| Best for | Caching, counters, sub-ms KV lookups | Search, ranking, rule matching |
| "Match documents to stored queries"? | No | **Yes — percolator** |
| Why this repo picked ES | — | The whole problem *is* matching events to rules |

> Takeaway for interviews: ES was chosen here not for "search" in the Google sense, but because
> the percolator capability is a perfect fit for a data-driven rule engine. No KV store or plain
> RDB gives you "which of my stored queries match this document?" out of the box.

---

## 4. How Elasticsearch is Used in this Repo

### 4.1 The big picture

This service (Digital Reminder Rule Engine) consumes payment/recharge/bill events from Kafka and
decides which reminder notifications (SMS / push / WhatsApp / email / chat) to fire. The decision
logic — the **rules** — lives in Elasticsearch as **percolator queries**.

### 4.2 Three indices, one per service

| Index | Processor that queries it | `service` value | Purpose |
|-------|---------------------------|-----------------|---------|
| `automatic` | `AutomaticPayloadProcessor` | `"automatic"` | Automatic recharge/bill reminders |
| `dropoff`   | `DropOffPayloadProcessor`  | `"dropoff"`   | Drop-off (abandoned journey) reminders |
| `rent`      | `RentPayloadProcessor`     | `"rent"`      | Rent payment reminders |

> The `service` string **is** the index name. One service → one index → one processor.

### 4.3 Key classes

| Class | Purpose |
|-------|---------|
| `config/ElasticSearchConfig.java` | Builds & owns the `ElasticsearchClient`; dual-node failover, timeouts, lifecycle |
| `services/ElasticSearchService.java` | The **only** place that builds & runs the percolator query |
| `services/AutomaticPayloadProcessor.java` | Calls the service, interprets matched rules, builds notifications |
| `services/DropOffPayloadProcessor.java` | Same pattern, `dropoff` index |
| `services/RentPayloadProcessor.java` | Same pattern, `rent` index |
| `dtos/ESRuleEngine.java` | Shape of a stored rule document |
| `dtos/MetaData.java` | Per-rule action config returned with each matched rule |

### 4.4 Dependency

`pom.xml`:

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-data-elasticsearch</artifactId>
</dependency>
```

Spring Boot 2.7.0 manages the version → **Elasticsearch Java API Client 7.x** (`co.elastic.clients.*`).
Local/dev ES image: **7.17.18** (see Docker section).

---

## 5. Data Model — Indices, Documents, Fields, Mappings

### 5.1 The stored-rule document — `ESRuleEngine`

`dtos/ESRuleEngine.java`:

```java
@JsonIgnoreProperties(ignoreUnknown = true)
public class ESRuleEngine {
  private Map<String, Object> query;  // the percolator query (a real ES query as JSON)
  private Integer priority;           // ordering across matched rules (lower = first here)
  private MetaData metaData;          // what to DO when this rule matches
  private Integer ruleStatus;         // 1 = active; anything else = ignore
  // getters / setters
}
```

A concrete stored rule document in ES:

```json
{
  "query": {
    "bool": {
      "must": [
        { "term":  { "service":     "mobile" } },
        { "term":  { "category_id": 17 } },
        { "range": { "amount": { "gt": 100 } } }
      ]
    }
  },
  "priority": 10,
  "ruleStatus": 1,
  "metaData": {
    "actionAndTemplateId": { "push": 4567, "sms": 4568 },
    "templateIdAndTemplateName": { "4567": "mobile_due_push" },
    "actionAnddeeplink": { "push": "paytmmp://recharge?operator=[operator]&amount=[amount]" },
    "actionAndShortUrl": { "sms": true },
    "actionAndStatus":   { "email": true },
    "realTimeNotify": false
  }
}
```

> `query` lives in a field of **type `percolator`** — that's what allows percolation.
> `@JsonIgnoreProperties(ignoreUnknown = true)` means rules in ES may carry extra fields this
> version of the code doesn't know about, and deserialization won't break.

### 5.2 The action config — `MetaData`

`dtos/MetaData.java`:

```java
@JsonIgnoreProperties(ignoreUnknown = true)
public class MetaData {
  private Map<String, Integer> actionAndTemplateId;        // "push" -> 4567
  private Map<Integer, String> templateIdAndTemplateName;  // 4567   -> "mobile_due_push"
  private Map<String, String>  actionAnddeeplink;          // "push" -> "paytmmp://..."
  private Map<String, Boolean> actionAndShortUrl;          // "sms"  -> shorten the URL?
  private Map<String, Boolean> actionAndStatus;            // "email"-> skip this action?
  private Map<String, Object>  inputFields;                // extra fields merged into payload
  private Map<String, UtmDto>  templateIdAndUtm;           // template -> UTM params
  private Map<String, Integer> cohortTemplateConfig;       // cohort overrides
  private boolean realTimeNotify;                          // send now vs. schedule in BR window
}
```

`MetaData` is the bridge between *"a rule matched"* and *"here's exactly what notification to build
and on which channel."*

### 5.3 The index mapping (required for percolation)

A representative mapping for `automatic` (same shape for `dropoff`, `rent`):

```json
PUT /automatic
{
  "settings": { "number_of_shards": 1, "number_of_replicas": 1 },
  "mappings": {
    "properties": {
      "query":      { "type": "percolator" },          // REQUIRED for percolation
      "priority":   { "type": "integer" },
      "ruleStatus": { "type": "integer" },
      "metaData":   { "type": "object", "enabled": false }, // store but don't index

      "service":     { "type": "keyword" },            // fields the RULES query on
      "category_id": { "type": "integer" },
      "amount":      { "type": "double" },
      "operator":    { "type": "keyword" }
    }
  }
}
```

Why this matters:

- **`query` must be `percolator`.** Otherwise you can't store rules-as-queries.
- The fields the rules reference (`service`, `category_id`, `amount`, …) must be mapped with the
  **right types**, because at percolate time ES validates the *incoming event* against the *stored
  query* using these definitions. A mapping mismatch (`text` vs `keyword`) is the #1 cause of
  *"my rule didn't match."*
- `metaData` is `enabled:false` — we never query *on* metadata, we only read it back from hits, so
  there's no point indexing it.

---

## 6. The Percolator Pattern — The Core Idea

### 6.1 Why this repo needs it

Business teams define rules like *"if service=mobile and amount>100, send a push using template
4567."* If we stored *events* and queried per rule, we'd run N queries per event. Instead we store
the **rules as percolator queries once**, and run **one** percolate call per batch of events. ES
does the matching internally and returns the matching rules.

### 6.2 The lifecycle of a rule

```
1. Ops/rule tooling indexes a rule document into "automatic" (query field = percolator type).
2. Event arrives on Kafka -> AutomaticPayloadProcessor builds a List<Map<String,Object>> payloads.
3. ElasticSearchService percolates payloads against "automatic", sorted by priority asc.
4. ES returns matched rules (hits). Each hit:
     - hit.source()  -> the ESRuleEngine rule (with metaData)
     - hit.fields()  -> "_percolator_document_slot" = which payloads it matched
5. Processor keeps only ruleStatus==1 rules, caps rules-per-payload, reads metaData, and
   fires notifications (SMS/push/WhatsApp/email/chat) via Cassandra + Kafka producers.
```

### 6.3 Rules are filtered for `ruleStatus` in code, not in the query

The percolate query does **not** filter on `ruleStatus`. Instead, application code keeps only
`ruleStatus == 1`. This makes enabling/disabling a rule a cheap re-index (no query change), at the
cost of ES still evaluating inactive rules. (Trade-off discussed in Q&A.)

---

## 7. Client Configuration — Deep Dive

`src/main/java/com/paytm/reminders/config/ElasticSearchConfig.java`.

### 7.1 Bean, properties, lifecycle

```java
@Configuration
@EnableElasticsearchRepositories
public class ElasticSearchConfig {

  @Value("${elasticsearch.host.client1.dns:localhost}") private String esClientDns1;
  @Value("${elasticsearch.host.client2.dns:localhost}") private String esClientDns2;
  @Value("${elasticsearch.port:9092}")                  private int    esPort;

  private ElasticsearchClient elasticsearchClient;
  private RestClient restClient;

  @Autowired private ApplicationMetricsPublisher applicationMetricsPublisher;

  // Guards against two threads building the client at once.
  private AtomicBoolean buildingClient = new AtomicBoolean(false);

  @PostConstruct
  public void initClient() {           // eagerly build the client at startup
    buildESClient();
  }
```

### 7.2 Building the low-level `RestClient` (failover + timeouts)

```java
restClient =
    RestClient.builder(
            new HttpHost(InetAddress.getByName(esClientDns1), esPort),
            new HttpHost(InetAddress.getByName(esClientDns2), esPort))   // two nodes -> failover
        .setNodeSelector(NodeSelector.SKIP_DEDICATED_MASTERS)            // query data nodes only
        .setRequestConfigCallback(requestConfigBuilder ->
            requestConfigBuilder
                .setConnectTimeout(5000)            // ms to open a TCP connection
                .setSocketTimeout(5000)             // ms to wait for data on the socket
                .setConnectionRequestTimeout(5000)) // ms to lease a pooled connection
        .setFailureListener(new RestClient.FailureListener() {
          @Override public void onFailure(Node node) {
            // log + emit ES_CLIENT_DISCONNECTED_TAG + re-point client at configured nodes
          }
        })
        .build();
```

- **Two `HttpHost`s** → round-robin + automatic failover.
- **`SKIP_DEDICATED_MASTERS`** → never send data queries to master-only nodes (they coordinate the
  cluster; they shouldn't serve queries). The repo comment says exactly this.
- **All three timeouts = 5000 ms** → fail fast so a sick node can't wedge a Kafka worker thread.
- **`FailureListener.onFailure(Node)`** → on a node error, logs it, increments
  `ES_CLIENT_DISCONNECTED_TAG`, and re-points `restClient.setNodes(...)` so a recovered node
  rejoins rotation.

### 7.3 Wrapping into transport + typed client

```java
// Transport = RestClient + the JSON (de)serializer (uses the app's custom ObjectMapper).
ElasticsearchTransport transport =
    new RestClientTransport(restClient, new JacksonJsonpMapper(ObjectMapperUtil.getObjectMapper()));

// The fluent, type-safe client your code calls.
elasticsearchClient = new ElasticsearchClient(transport);
```

The **custom `ObjectMapper`** ensures ES JSON (de)serialization uses the same Jackson rules as the
rest of the app (unknown-property tolerance, null handling), which is why `ESRuleEngine`/`MetaData`
carry `@JsonIgnoreProperties(ignoreUnknown = true)`.

### 7.4 Thread-safe access & shutdown

```java
public ElasticsearchClient client() {
  if (elasticsearchClient != null) { buildingClient.set(false); return elasticsearchClient; }
  buildESClient();
  if (buildingClient.get()) throw new ElasticSearchConnectException("Building New ES Client.");
  return elasticsearchClient;
}

public boolean isClientBuilding() {
  return buildingClient.get() || elasticsearchClient == null;
}

@PreDestroy
public void closeESClient() {
  if (elasticsearchClient != null) elasticsearchClient._transport().close(); // release sockets
}
```

- `buildESClient()` is `synchronized` and short-circuits if the client exists → exactly one client.
- `isClientBuilding()` lets callers **back off** during warm-up (see §8.3).
- `@PreDestroy` closes the transport cleanly on redeploy (no socket leak).

### 7.5 Environment configuration

| Profile | `client1.dns` | `client2.dns` | port |
|---------|---------------|---------------|------|
| development | `localhost` | `localhost` | 9200 |
| staging | `10.4.41.190` | `10.4.41.190` | 9200 |
| production | `reminder-esclient1.prod.paytmdgt.io` | `reminder-esclient2.prod.paytmdgt.io` | 9200 |
| test | `localhost` | `localhost` | 9200 |

```properties
# application-production.properties
elasticsearch.host.client1.dns=reminder-esclient1.prod.paytmdgt.io
elasticsearch.host.client2.dns=reminder-esclient2.prod.paytmdgt.io
elasticsearch.port=9200
```

> The two hosts differ only in production — that's where separate data nodes exist. Lower
> environments point both entries at the same box.

---

## 8. The Percolator Query Service — Deep Dive

All percolation lives in one method: `ElasticSearchService.getPercolatorQueryResponse`.

### 8.1 The method

`src/main/java/com/paytm/reminders/services/ElasticSearchService.java`:

```java
public <T> SearchResponse<ESRuleEngine> getPercolatorQueryResponse(
    String indexName, List<T> documentList, String sortKey, String sortOrder) {
  try {
    // 1) Wrap each incoming event into JsonData (the client's generic JSON holder).
    List<JsonData> jsonDataList = new LinkedList<>();
    documentList.forEach(document -> jsonDataList.add(JsonData.of(document)));

    // 2) Build the search request via the fluent (lambda) builder API.
    SearchRequest searchRequest =
        SearchRequest.of(search ->
            search
                .index(indexName)                       // automatic / dropoff / rent
                .query(query ->
                    query.percolate(percolate ->
                        percolate
                            .field("query")             // the percolator field in the index
                            .documents(jsonDataList)))  // events to match against ALL rules
                .sort(sort ->
                    sort.field(fieldSort ->
                        fieldSort
                            .field(sortKey != null ? sortKey : "_id")
                            .order(StringUtils.equalsIgnoreCase(sortOrder, "desc")
                                ? SortOrder.Desc : SortOrder.Asc))));

    // 3) Execute, timing the call for metrics.
    long startTime = System.currentTimeMillis();
    SearchResponse<ESRuleEngine> searchResponse =
        getElasticSearchClient().search(searchRequest, ESRuleEngine.class);

    applicationMetricsPublisher.recordExecutionTime(
        ApplicationMetricsPublisher.ES_QUERY_LATENCY_TAG,
        System.currentTimeMillis() - startTime, "esQuery:percolator", "index:" + indexName);

    return searchResponse;
  } catch (ElasticSearchConnectException | UnknownHostException
      | ConnectException | ResponseException e) {                 // connectivity / known ES errors
    LOGGER.error("ElasticSearch error occurred while running percolator Query:: ", e);
    applicationMetricsPublisher.incrementCounter(
        ApplicationMetricsPublisher.ES_QUERY_ERROR_TAG, "esQuery:percolator", "index:" + indexName);
    throw new ElasticSearchConnectException(
        "Error while querying ES percolator:: " + e.getLocalizedMessage());
  } catch (Exception e) {                                          // truly unexpected
    LOGGER.error("ElasticSearch Percolator Query gave an error:: ", e);
    applicationMetricsPublisher.incrementCounter(
        ApplicationMetricsPublisher.ES_QUERY_ERROR_TAG, "esQuery:percolator", "index:" + indexName);
    throw new RuntimeException("Error while querying ES percolator:: " + e.getLocalizedMessage());
  }
}
```

### 8.2 What this produces — the raw ES request

```json
POST /automatic/_search
{
  "query": {
    "percolate": {
      "field": "query",
      "documents": [
        { "service": "mobile", "category_id": 17, "amount": 250, "...": "..." },
        { "service": "dth",    "category_id": 6,  "amount": 300, "...": "..." }
      ]
    }
  },
  "sort": [ { "priority": { "order": "asc" } } ]
}
```

Reading the builder: the Java API Client uses **lambda builders** — `SearchRequest.of(s -> s.index(...)...)`.
Each `x ->` hands you a builder you configure and return. It maps 1:1 to the JSON above.

- **`JsonData.of(document)`** wraps each `Map<String,Object>` event into the generic JSON type the
  client serializes into the `documents` array. The method is generic (`<T>`), but all three
  processors pass `List<Map<String, Object>>`.
- **`search(request, ESRuleEngine.class)`** tells the client to deserialize each hit's `_source`
  into an `ESRuleEngine`. That's why `ESRuleEngine`'s fields must align with the stored document.

### 8.3 How callers invoke it (the warm-up + degradation guard)

From `AutomaticPayloadProcessor.processData` (same shape in `DropOff`/`Rent`):

```java
SearchResponse<ESRuleEngine> searchResponse = null;

while (true) {
  if (!elasticSearchService.isESClientBuilding()) {               // client ready?
    try {
      searchResponse = elasticSearchService.getPercolatorQueryResponse(
          service, payloads, "priority", "asc");                  // matched rules sorted by priority asc
    } catch (ElasticSearchConnectException e) {
      LOGGER.error("Error Occured while querying ES:: ", e);
      // GRACEFUL DEGRADATION: re-publish each payload to Kafka for later retry
      payloads.forEach(payload ->
          automaticsKafkaProducerService.sendMessageToKafkaTopic(
              KafkaConstants.AUTOMATIC_TOPIC, String.valueOf(payload.hashCode()), payload, null));
    }
    break;
  }
  LOGGER.warn("ElasticSearch connection is not built yet...");
  Thread.sleep(5000);                                             // WARM-UP BACKOFF, re-check
}

if (searchResponse != null) {
  processDocuments(searchResponse.hits(), payloads, service);
}
```

Two reliability behaviors:

1. **Warm-up backoff** — if the client is still building, sleep 5s and re-check rather than throw.
2. **Graceful degradation** — if ES is unreachable, payloads go **back to Kafka** so no event is
   lost; they're reprocessed once ES recovers.

---

## 9. Reading the Response — `_percolator_document_slot` & Rule Limiting

This is the subtlest part of the whole flow.

### 9.1 The slot problem

We sent a **batch** of N events in one percolate call. When a rule matches, we must know *which of
those N events* it matched. ES answers with a special per-hit field:
**`_percolator_document_slot`** — an array of zero-based indexes into the `documents` array we sent.

Example: we sent `[p0, p1, p2]`. A rule that matched `p0` and `p2` returns
`"_percolator_document_slot": [0, 2]`.

### 9.2 Mapping rules back to events

`AutomaticPayloadProcessor.createIndexAndRulesMap`:

```java
void createIndexAndRulesMap(
    List<Map<String, Object>> payloads, Hit<ESRuleEngine> hit,
    Map<Integer, List<ESRuleEngine>> indexAndRulesMap, long counter) {

  if (hit == null || hit.source() == null) return;

  ESRuleEngine esRuleEngine = hit.source();

  // Honor ACTIVE rules only. ruleStatus must be exactly 1.
  if (esRuleEngine.getRuleStatus() == null || !esRuleEngine.getRuleStatus().equals(1)) return;

  // Pull matched-document indexes from the percolator response field.
  Map<String, JsonData> fields = hit.fields();
  JsonArray matchedDocumentIndexes = fields.get("_percolator_document_slot").toJson().asJsonArray();

  if (CollectionUtils.isNotEmpty(matchedDocumentIndexes)) {
    for (int i = 0; i < matchedDocumentIndexes.size(); i++) {
      int payloadIndex = matchedDocumentIndexes.getJsonNumber(i).intValueExact();

      List<ESRuleEngine> esRules = indexAndRulesMap.getOrDefault(payloadIndex, new LinkedList<>());
      if (esRules.size() == counter) return;          // per-payload rule cap reached -> stop
      esRules.add(esRuleEngine);
      indexAndRulesMap.put(payloadIndex, esRules);
    }
  }
}
```

This builds `indexAndRulesMap : payloadIndex -> [rules that matched that payload]`.

### 9.3 Why sorting by `priority asc` + the cap = "top K rules per event"

The query sorts hits by `priority` ascending, so `hitsMetadata.hits()` is iterated in precedence
order. Combined with the `counter` cap: the highest-precedence rules are added first, and once a
payload hits its cap, further (lower-precedence) rules for it are skipped.

```java
// AutomaticPayloadProcessor.processDocuments (cap selection)
if (MapUtils.isNotEmpty(dynamicConfigDto.getServiceAndRuleConfigMap())
    && dynamicConfigDto.getServiceAndRuleConfigMap().containsKey(service)) {
  long counter = dynamicConfigDto.getServiceAndRuleConfigMap().get(service);
  counter = counter <= 0 ? hitsMetadata.total().value() : counter;   // 0 (or less) => "no limit"
  createIndexVsRulesMap(hitsMetadata, payloads, indexAndRulesMap, counter);
} else {
  createIndexVsRulesMap(hitsMetadata, payloads, indexAndRulesMap, 1); // DEFAULT: 1 rule/payload
}
```

- Default cap = **1 rule per payload**.
- A configured `serviceAndRuleConfigMap[service]` overrides it; `0` (≤0) means **no limit**
  (`hitsMetadata.total().value()`).

### 9.4 Acting on matched rules

```java
void processDocumentsBasedOnRules(
    List<Map<String, Object>> payloads, Map<Integer, List<ESRuleEngine>> indexAndRulesMap) {
  indexAndRulesMap.forEach((index, rules) ->
      rules.forEach(rule -> {
        MetaData metaData = rule.getMetaData();
        if (metaData != null) {
          processMetaData(rule, payloads.get(index), metaData);   // build & send notifications
        } else {
          applicationMetricsPublisher.incrementCounter(ApplicationMetricsPublisher.META_NOT_FOUND_ERROR_TAG);
        }
      }));
}
```

From here `processMetaData` reads `MetaData` to construct SMS/push/WhatsApp/email/chat payloads,
resolves deeplinks/UTM/short-URLs, writes the notification to Cassandra, and publishes to Kafka.
That's downstream of ES, but it's *why* the response shape matters: each matched rule carries its
own action config.

### 9.5 The `Hit` / `HitsMetadata` types (quick reference)

| Call | Returns | Meaning |
|------|---------|---------|
| `searchResponse.hits()` | `HitsMetadata<ESRuleEngine>` | wrapper over the hits |
| `hitsMetadata.hits()` | `List<Hit<ESRuleEngine>>` | one element per **matched rule** |
| `hitsMetadata.total().value()` | `long` | total matched-rule count |
| `hit.source()` | `ESRuleEngine` | the rule (typed) |
| `hit.fields()` | `Map<String, JsonData>` | extra fields incl. `_percolator_document_slot` |

---

## 10. Resilience — Failover, Circuit Breaker, Retry, Metrics

Five mechanisms work together:

### 10.1 Dual-node failover (client level)
Two `HttpHost`s + `NodeSelector.SKIP_DEDICATED_MASTERS` + a `FailureListener` that re-points the
client when a node drops. (See §7.2.)

### 10.2 Fast timeouts
All three timeouts are 5000 ms so a sick node can't wedge a worker thread.

### 10.3 Circuit breaker + retry (Resilience4j)

`application.properties`:

```properties
resilience4j.circuitbreaker.instances.elasticsearch.base-config=default
resilience4j.retry.instances.elasticsearch.base-config=default
```

A named instance `elasticsearch` exists for both. When ES errors breach thresholds, the breaker
opens and fails fast (instead of piling requests onto a struggling cluster); retry covers blips.

### 10.4 Graceful degradation to Kafka
On `ElasticSearchConnectException`, payloads are re-published to their topic
(`KafkaConstants.AUTOMATIC_TOPIC`, etc.) so events survive an ES outage.

### 10.5 Metrics on every call

```java
// success -> latency (tagged by index)
applicationMetricsPublisher.recordExecutionTime(
    ApplicationMetricsPublisher.ES_QUERY_LATENCY_TAG,
    System.currentTimeMillis() - startTime, "esQuery:percolator", "index:" + indexName);

// failure -> error counter
applicationMetricsPublisher.incrementCounter(
    ApplicationMetricsPublisher.ES_QUERY_ERROR_TAG, "esQuery:percolator", "index:" + indexName);

// node disconnect (in the FailureListener)
applicationMetricsPublisher.incrementCounter(ApplicationMetricsPublisher.ES_CLIENT_DISCONNECTED_TAG);
```

Tags `esQuery:percolator` and `index:<name>` let dashboards break latency/error down per index.

### 10.6 Exception strategy
- **Connectivity/known ES errors** (`ElasticSearchConnectException`, `UnknownHostException`,
  `ConnectException`, `ResponseException`) → rethrown as `ElasticSearchConnectException`; callers
  degrade to Kafka.
- **Anything else** → rethrown as `RuntimeException` (a truly unexpected failure isn't treated as
  "ES is down").

---

## 11. TTL / Index Lifecycle Strategy

Unlike a cache (Aerospike/Redis), ES rule documents here are **not** TTL-expiring data — they are
long-lived configuration. The "lifecycle" concerns are different:

| Concern | Strategy |
|---------|----------|
| Rule enable/disable | `ruleStatus` flag filtered in app code (`==1`); no re-index of the query needed |
| Rule precedence | `priority` field, sorted ascending at query time |
| Adding/removing rules | Index/delete a document in `automatic`/`dropoff`/`rent` (out-of-band tooling) |
| Replicas | `number_of_replicas` per index for HA/read throughput (1 in prod-style mapping; 0 acceptable for single-node dev) |
| Shards | `number_of_shards` set at index creation (1 is plenty — rule counts are small) |
| Version alignment | Keep client (7.x) and server (7.17.18) on the same major; percolator + `_percolator_document_slot` are stable within 7.x |

> **Interview-worthy nuance:** ES here is a *system of configuration*, not a cache. There is no
> per-document TTL on rules. Freshness comes from re-indexing rules, and "soft delete" is the
> `ruleStatus` flag — not document deletion.

---

## 12. Local Setup & Operating the Indices

### 12.1 Local Elasticsearch via Docker Compose

`docker-compose.yml`:

```yaml
elasticsearch:
  image: docker.elastic.co/elasticsearch/elasticsearch:7.17.18
  container_name: drre-elasticsearch
  ports:
    - "9200:9200"   # REST API
    - "9300:9300"   # transport (node-to-node)
  environment:
    discovery.type: single-node          # no clustering locally
    xpack.security.enabled: "false"      # no auth locally
    ES_JAVA_OPTS: "-Xms256m -Xmx512m"    # small heap for dev
  volumes:
    - es-data:/usr/share/elasticsearch/data
```

Bring it up with the project's Make targets (per `CLAUDE.md`):

```bash
make infra-up      # starts MySQL, Cassandra, ES, Kafka
make infra-down    # stops them
make infra-reset   # stops + wipes all data (fresh indices)
```

### 12.2 Verify it's alive

```bash
curl http://localhost:9200                 # cluster info
curl http://localhost:9200/_cluster/health # green / yellow / red
curl http://localhost:9200/_cat/indices?v  # list indices
```

> A local single-node cluster shows **yellow** (replicas can't be allocated with one node). That's
> expected for dev.

### 12.3 Create the three rule indices locally

```bash
for idx in automatic dropoff rent; do
  curl -X PUT "http://localhost:9200/$idx" -H 'Content-Type: application/json' -d '{
    "mappings": { "properties": {
      "query":      { "type": "percolator" },
      "priority":   { "type": "integer" },
      "ruleStatus": { "type": "integer" },
      "service":     { "type": "keyword" },
      "category_id": { "type": "integer" },
      "amount":      { "type": "double" }
    }}
  }'
done
```

### 12.4 Add a test rule and percolate against it

```bash
# 1) register a rule
curl -X POST "http://localhost:9200/automatic/_doc/test-rule-1?refresh" \
  -H 'Content-Type: application/json' -d '{
    "query": { "term": { "service": "mobile" } },
    "priority": 1, "ruleStatus": 1,
    "metaData": { "actionAndTemplateId": { "push": 4567 } }
  }'

# 2) percolate an event through it
curl -X POST "http://localhost:9200/automatic/_search?pretty" \
  -H 'Content-Type: application/json' -d '{
    "query": { "percolate": { "field": "query",
      "documents": [ { "service": "mobile", "amount": 250 } ] } },
    "sort": [ { "priority": { "order": "asc" } } ]
  }'
```

The response contains the rule as a hit, with `_percolator_document_slot: [0]`.

### 12.5 Testing ES code (mock the client — no real ES)

Per `CLAUDE.md`, tests must not require real external services. The repo has:

- `ElasticSearchServiceTest` — mocks `ElasticsearchClient`; covers valid percolator queries with
  `asc`/`desc`/invalid sort, null/empty inputs, each caught exception type → assert
  `ElasticSearchConnectException` is rethrown, latency recorded on success, error counter on
  failure.
- `ElasticSearchConfigTest` — `buildingClient` state transitions, client init/reset, transport
  cleanup on `@PreDestroy`, exception handling during `close()`.

```java
@Mock private ElasticSearchConfig elasticSearchConfig;
@Mock private ElasticsearchClient elasticsearchClient;
@Mock private ApplicationMetricsPublisher applicationMetricsPublisher;
@InjectMocks private ElasticSearchService elasticSearchService;

@Test
void percolatorQuery_success_recordsLatency() throws Exception {
  when(elasticSearchConfig.client()).thenReturn(elasticsearchClient);
  when(elasticsearchClient.search(any(SearchRequest.class), eq(ESRuleEngine.class)))
      .thenReturn(mockSearchResponse);

  SearchResponse<ESRuleEngine> resp = elasticSearchService.getPercolatorQueryResponse(
      "automatic", List.of(Map.of("service", "mobile")), "priority", "asc");

  assertNotNull(resp);
  verify(applicationMetricsPublisher).recordExecutionTime(
      eq(ApplicationMetricsPublisher.ES_QUERY_LATENCY_TAG), anyLong(), any(), any());
}
```

Run with `make test` (unit + JaCoCo) or `make verify` (full gate: tests + coverage + Checkstyle +
SpotBugs + Spotless).

---

## 13. Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                     Kafka (payment / recharge / bill events)      │
└───────────────┬───────────────────┬───────────────────┬──────────┘
                │                   │                   │
          automatic topic      dropoff topic        rent topic
                │                   │                   │
┌───────────────▼───────────────────▼───────────────────▼──────────┐
│                    digital_reminder_rule_engine                   │
│                                                                  │
│  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐  │
│  │ Automatic        │ │ DropOff          │ │ Rent             │  │
│  │ PayloadProcessor │ │ PayloadProcessor │ │ PayloadProcessor │  │
│  └────────┬─────────┘ └────────┬─────────┘ └────────┬─────────┘  │
│           │                    │                    │            │
│           └──────────┬─────────┴──────────┬─────────┘            │
│                      ▼                     ▼                      │
│           ┌─────────────────────────────────────────┐            │
│           │          ElasticSearchService            │            │
│           │   getPercolatorQueryResponse(            │            │
│           │     index, payloads, "priority", "asc")  │            │
│           └────────────────────┬────────────────────┘            │
│                                │ uses                             │
│           ┌────────────────────▼────────────────────┐            │
│           │          ElasticSearchConfig             │            │
│           │   ElasticsearchClient (7.x typed)        │            │
│           │   dual-node failover, 5s timeouts        │            │
│           └────────────────────┬────────────────────┘            │
└────────────────────────────────┼─────────────────────────────────┘
                                 │ percolate(field="query", documents=[...])
                ┌────────────────▼────────────────┐
                │       Elasticsearch cluster      │
                │  indices: automatic/dropoff/rent │
                │  rules stored as percolator      │
                │  queries; sorted by priority     │
                └────────────────┬─────────────────┘
                                 │ matched rules (hits + _percolator_document_slot)
                                 ▼
                  ESRuleEngine.metaData -> build & dispatch
                  SMS / Push / WhatsApp / Email / Chat
                  (Cassandra + Kafka producers)
```

---

## 14. Common Interview Questions & Answers

### Q1: "What is Elasticsearch and why did you use it here?"
> Elasticsearch is a distributed, JSON document store built on Lucene, optimized for search and
> analytics via an inverted index. In this service we use it as a **rule engine**, not a search
> engine. Business reminder rules are stored as Elasticsearch **percolator queries**. When payment
> events arrive on Kafka, we percolate a batch of events against the stored rules in a single call
> and ES returns which rules match. This makes rules data-driven (no deploy to change them) and
> turns "evaluate N rules per event" into one optimized query.

### Q2: "What is a percolator query? How is it different from normal search?"
> Normal search: you store documents and send a query; ES returns matching documents. Percolation
> is the **reverse**: you store *queries* (in a field of type `percolator`), then send *documents*,
> and ES returns the stored queries that match those documents. We register each business rule as a
> percolator query, and percolate incoming event payloads to find matching rules.

### Q3: "How is data organized in Elasticsearch in this repo?"
> Three **indices** — `automatic`, `dropoff`, `rent` — one per reminder service. Each **document**
> is one rule (`ESRuleEngine`) with fields: `query` (the percolator query), `priority` (sort
> order), `ruleStatus` (1 = active), and `metaData` (the action config — templates, deeplinks, UTM,
> channel flags). The `query` field is mapped as type `percolator`; the fields the rules filter on
> (`service`, `category_id`, `amount`, …) are mapped with their proper types.

### Q4: "Walk me through the end-to-end flow for one event."
> A payload processor (e.g. `AutomaticPayloadProcessor`) receives a batch of events as
> `List<Map<String,Object>>`. It calls `ElasticSearchService.getPercolatorQueryResponse(service,
> payloads, "priority", "asc")`, which builds a `percolate` query on the `query` field with the
> events as `documents`, sorted by `priority` ascending. ES returns matched rules as hits. For each
> hit we keep only `ruleStatus==1` rules, read `_percolator_document_slot` to learn which events
> the rule matched, cap rules-per-payload, then use the rule's `metaData` to build and dispatch
> SMS/push/WhatsApp/email/chat notifications via Cassandra and Kafka.

### Q5: "What is `_percolator_document_slot` and why do you need it?"
> Because we percolate a **batch** of events in one call, when a rule matches we need to know
> *which* events it matched. ES returns `_percolator_document_slot` on each hit — an array of
> zero-based indexes into the `documents` array we sent. We use it to map each matched rule back to
> the specific payload(s) it applies to (`indexAndRulesMap: payloadIndex -> [rules]`).

### Q6: "How do you control which rules fire and in what order?"
> Two levers. **Order:** the query sorts hits by `priority` ascending, so higher-precedence rules
> come first. **Count:** a per-service `counter` caps how many rules can fire per payload (default
> 1; `serviceAndRuleConfigMap` can override; `0` means no limit). Sorting + capping together
> implement "fire the top K rules per event."

### Q7: "How do you enable/disable a rule without a deploy?"
> Each rule has a `ruleStatus` field. We filter `ruleStatus == 1` in application code, not in the
> percolate query. So toggling a rule on/off is just re-indexing the document — no code change. The
> trade-off is that ES still evaluates inactive rules; if inactive rules ever dominate, we'd move
> the filter into the percolate query.

### Q8: "Why use the raw `ElasticsearchClient` instead of Spring Data repositories?"
> Percolation isn't CRUD. It needs a hand-built `percolate` query with a `documents` array plus
> post-processing of `_percolator_document_slot`. The typed `ElasticsearchClient` expresses that
> cleanly with its fluent builders. Spring Data's `@Document`/repository abstraction is great for
> derived queries on POJOs but can't express percolation naturally, so `@EnableElasticsearchRepositories`
> is present but no repository interfaces exist.

### Q9: "What happens if Elasticsearch is down or still starting up?"
> Two safeguards. **Warm-up:** callers check `isESClientBuilding()` and sleep 5s in a loop until
> the client is ready, rather than throwing. **Outage:** if the percolate call throws
> `ElasticSearchConnectException`, every payload is re-published to its Kafka topic so no event is
> lost; it's reprocessed once ES recovers. On top of that, the client has dual-node failover, 5s
> timeouts, and a Resilience4j circuit breaker + retry on the `elasticsearch` instance.

### Q10: "How is the client configured for reliability?"
> `ElasticSearchConfig` builds a `RestClient` with **two hosts** for failover, `NodeSelector
> .SKIP_DEDICATED_MASTERS` so we only query data nodes, and three 5000 ms timeouts (connect,
> socket, connection-request) to fail fast. A `FailureListener` logs node drops, emits
> `ES_CLIENT_DISCONNECTED_TAG`, and re-points the client at the configured nodes. The `RestClient`
> is wrapped in a `RestClientTransport` with a custom Jackson mapper, then in the typed
> `ElasticsearchClient`. It's built once in `@PostConstruct` (synchronized, guarded by an
> `AtomicBoolean`) and closed in `@PreDestroy`.

### Q11: "What monitoring do you have for ES?"
> Per-call metrics tagged by index: `ES_QUERY_LATENCY_TAG` (query time on success),
> `ES_QUERY_ERROR_TAG` (error count on failure), and `ES_CLIENT_DISCONNECTED_TAG` (node
> disconnects from the failure listener). Tags `esQuery:percolator` and `index:<name>` let
> dashboards break it down per index.

### Q12: "What's the most common bug with percolators and how do you avoid it?"
> Field-type **mapping mismatches**. If a rule does `{ "term": { "service": "mobile" } }` but
> `service` is mapped as analyzed `text` instead of `keyword`, matching behaves unexpectedly and
> the rule silently doesn't match. The fix: keep the mapping of percolated fields aligned with how
> rules query them, and add new filter fields to the mapping *before* shipping rules that use them.

### Q13: "Could you add aggregations, pagination, or bulk writes here?"
> The repo doesn't currently use them. Aggregations would go into the `SearchRequest` builder in
> `ElasticSearchService` if we wanted rule-match analytics. Pagination (scroll/`search_after`) isn't
> needed because the result set is the number of matching rules, which is small. Bulk indexing isn't
> done by this service — rules are loaded out-of-band by rule-management tooling; this service only
> **reads** (percolates).

### Q14: "Index vs shard vs replica — quick definitions?"
> An **index** is a collection of documents sharing a mapping (like a table). A **shard** is a
> partition of an index (a Lucene index) enabling horizontal scale. A **replica** is a copy of a
> shard for HA and read throughput. Here rule counts are small, so 1 shard is plenty; replicas are
> set per environment (1 in a prod-style mapping; 0 is fine for single-node dev, which is why local
> health shows yellow).

---

## 15. Bonus — Key Code Snippets to Reference

### Build & run a percolator query (typed client, fluent builder)

```java
SearchRequest searchRequest = SearchRequest.of(search -> search
    .index(indexName)                                   // automatic / dropoff / rent
    .query(q -> q.percolate(p -> p
        .field("query")                                 // percolator field
        .documents(jsonDataList)))                      // events as JsonData
    .sort(s -> s.field(f -> f
        .field(sortKey != null ? sortKey : "_id")
        .order(StringUtils.equalsIgnoreCase(sortOrder, "desc") ? SortOrder.Desc : SortOrder.Asc))));

SearchResponse<ESRuleEngine> resp =
    getElasticSearchClient().search(searchRequest, ESRuleEngine.class);
```

### Wrap incoming events as JsonData

```java
List<JsonData> jsonDataList = new LinkedList<>();
documentList.forEach(document -> jsonDataList.add(JsonData.of(document)));
```

### Read matched-event slots from a hit

```java
ESRuleEngine rule = hit.source();
if (rule.getRuleStatus() != null && rule.getRuleStatus().equals(1)) {
  JsonArray slots = hit.fields().get("_percolator_document_slot").toJson().asJsonArray();
  for (int i = 0; i < slots.size(); i++) {
    int payloadIndex = slots.getJsonNumber(i).intValueExact();   // index into the events we sent
    // map rule -> payloads.get(payloadIndex)
  }
}
```

### Dual-node client with failover & fast timeouts

```java
RestClient restClient = RestClient.builder(
        new HttpHost(InetAddress.getByName(esClientDns1), esPort),
        new HttpHost(InetAddress.getByName(esClientDns2), esPort))
    .setNodeSelector(NodeSelector.SKIP_DEDICATED_MASTERS)
    .setRequestConfigCallback(b -> b
        .setConnectTimeout(5000).setSocketTimeout(5000).setConnectionRequestTimeout(5000))
    .setFailureListener(failureListener)
    .build();

ElasticsearchClient client = new ElasticsearchClient(
    new RestClientTransport(restClient, new JacksonJsonpMapper(ObjectMapperUtil.getObjectMapper())));
```

### Graceful degradation on ES failure (re-queue to Kafka)

```java
try {
  searchResponse = elasticSearchService.getPercolatorQueryResponse(service, payloads, "priority", "asc");
} catch (ElasticSearchConnectException e) {
  payloads.forEach(payload -> automaticsKafkaProducerService.sendMessageToKafkaTopic(
      KafkaConstants.AUTOMATIC_TOPIC, String.valueOf(payload.hashCode()), payload, null));
}
```

### Raw percolate request (for curl / debugging)

```json
POST /automatic/_search
{
  "query": { "percolate": { "field": "query",
    "documents": [ { "service": "mobile", "category_id": 17, "amount": 250 } ] } },
  "sort": [ { "priority": { "order": "asc" } } ]
}
```

---

### One-paragraph summary

This service stores reminder **rules as Elasticsearch percolator queries** across three indices
(`automatic`, `dropoff`, `rent`). When events arrive on Kafka, `ElasticSearchService
.getPercolatorQueryResponse` percolates a batch of event documents against the stored rules in one
call, sorted by `priority asc`. Each matched hit is a rule whose `_percolator_document_slot` tells
which events it matched; the per-service processors keep active (`ruleStatus == 1`) rules, map them
back to events (capped per `serviceAndRuleConfigMap`), and use each rule's `MetaData` to build and
dispatch notifications. Reliability comes from dual-node failover, 5s timeouts, a Resilience4j
circuit breaker/retry, graceful re-queueing to Kafka on ES failure, and per-index latency/error
metrics. ES here is a **data-driven rule engine**, not a search box — which is exactly what the
percolator feature is for.
