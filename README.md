# 💎 La Roca Micro-KV

**The 10KB Database: Pure Metal. Zero Compromise.**

[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-20KB-blue?logo=docker&logoColor=white)](https://hub.docker.com/r/blockmaker/la-roca-kv)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Binary Size](https://img.shields.io/badge/Binary%20Size-10KB-blue)
![Language](https://img.shields.io/badge/Language-Assembly%20x86__64-red)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey)
![Company](https://img.shields.io/badge/Backed%20By-BlockMaker%20S.R.L.-black)

La Roca is a high-performance, transactional Key-Value store written in **pure x86_64 Assembly**.
Built with zero dependencies and targeting the Linux Kernel directly via syscalls,
it achieves extreme efficiency and atomic resilience in a tiny binary footprint.

## 🚀 Quick Start (Docker)
Run "La Roca" in seconds without installing any dependencies:

```bash
docker run -d -p 8080:8080 --name la-roca blockmaker/la-roca-kv:latest
```

---

### 🛠️ Technical Pillars
* **Pure Assembly:** No libc, no frameworks. Just registers and syscalls.
* **Hardware Integrity:** CRC32 validation using native CPU instructions for data safety.
* **Atomic Persistence:** Write-Ahead Logging (WAL) architecture designed to survive `SIGKILL`.
* **Zero-Copy Sharding:** Deterministic multi-shard partitioning for O(1) addressing.
* **Micro-Footprint:** Static binary weight of ~10KB.

---

## 📑 Table of Contents

- [📊 Performance Metrics](#-performance-metrics)
- [📡 API Definition (The Contract)](#-api-definition-the-contract)
- [🧠 Architecture](#-architecture)
- [🛠️ Project Structure](#-project-structure)
- [📂 Memory Layout & Shard Internals](#-memory-layout--shard-internals)
- [🛡️ Write-Ahead Logging (WAL) & Crash Recovery](#-write-ahead-logging-wal--crash-recovery)
- [🔒 Network Hardening](#-network-hardening)
- [🏗️ Horizontal Scaling (Cluster Mode)](#-horizontal-scaling-cluster-mode)
- [🚀 Usage & Persistence](#-usage--persistence)
- [🧪 Testing & Validation](#-testing--validation)
- [📝 Runtime & Logging Configuration](#-runtime--logging-configuration)
- [🤝 Contact & Collaboration](#-contact--collaboration)

---

## 📊 Performance Metrics

| Feature | Standard Microservice (Go/Node) | **Asm Micro-KV (Sharded)** |
| :--- | :--- | :--- |
| **Total Capacity** | Variable | **~1.7 GB** ($27 \times 64\text{MB}$ shards) |
| **Max Key Count** | Variable | **1,769,445 slots** ($27 \times 65,535$) |
| **Binary Size** | 10 MB - 50 MB | **~10.1 KB** |
| **Startup Time** | 100ms - 1s | **< 5ms** (Mapping 1.7GB + WAL Replay) |
| **I/O Isolation** | Low | **High** (Deterministic partitioning) |

> **Note on Throughput:** Formal Requests-Per-Second (RPS) metrics are not listed here. Because this engine is a Zero-Copy, `libc`-free application, local load testing often saturates the OS loopback network interface before maxing out the CPU. The engine operates at the maximum speed the Kernel can handle TCP interrupts and `sys_write` syscalls.

## 🏎️ The "Loopback Saturation" Phenomenon

If you attempt to run high-concurrency benchmarks (like `ab` or `wrk`) on a local machine, you will likely notice that the CPU usage of **La Roca** stays below 15% while the benchmark tool struggles to maintain throughput.

**This is not a bottleneck in the engine; it is a bottleneck in the Linux Kernel.**

Because this engine is built with a **Zero-Copy, libc-free architecture**, it operates at a speed that exceeds the standard overhead of the OS network stack. In local testing, the performance limit is usually dictated by:

* **TCP/IP Interrupts**: The rate at which the Kernel can process incoming packets on the `lo` (loopback) interface.
* **Context Switching**: The overhead of the Kernel moving from User Space to Kernel Space for thousands of `sys_read` and `sys_write` calls per second.
* **The Performance Paradox**: In most environments, **La Roca** is faster than the infrastructure used to test it. To see its true limits, testing across a 10Gbps dedicated fiber link between dos isolated nodes is required.

### ⚙️ Compile-Time Configuration (`config.inc`)

The engine's capacity, memory footprint, and payload limits are completely modular. Because we use Assembly macros, there is **zero runtime overhead** for these configurations. You can tailor the engine to your exact hardware limits by modifying the `src/config.inc` file before building the container.

```nasm
; --- src/config.inc ---
%define KEY_SIZE        32              ; Max bytes for a key (including null-terminator)
%define VAL_MAX_SIZE    989             ; Max bytes for the binary payload
%define SLOT_SIZE       1024            ; Total bytes per record (1KB)
%define SLOTS_PER_SHARD 65536           ; Total records per shard
%define SHARD_SIZE      67108864        ; 64MB per shard (SLOT_SIZE * SLOTS_PER_SHARD)
%define WAL_RECORD_SIZE 1027            ; Bytes per WAL entry: OP(1) + LEN(2) + KEY(32) + VAL(992)
```

#### 🛠️ How to Modify and Scale
If you need to store larger payloads (e.g., 4KB JSON documents) or support billions of keys, simply adjust the math in the config file:

1. Edit the `config.inc` file. Ensure that `SLOT_SIZE` can comfortably accommodate `KEY_SIZE + VAL_MAX_SIZE + Metadata`.
2. Rebuild the Docker image so the Assembler (`nasm`) can recalculate all hardcoded offsets directly into the machine code:
   ```bash
   docker-compose build
   ```

> ⚠️ **CRITICAL WARNING:** If you change the `SLOT_SIZE` or `SHARD_SIZE` after running the engine, you **must delete** your existing `.db` and `wal.log` files. The new binary will calculate memory offsets differently, and reading an old database schema will result in a Segmentation Fault.

---

## 📡 API Definition (The Contract)

The service implements a structured REST interface. By isolating data operations under the `/keys` namespace, the engine avoids collisions between user data and system management endpoints. It is completely **Binary-Safe**, allowing for the storage of raw buffers, images, or encrypted blobs without corruption.

---

### 🛠️ System Endpoints (Management)
Used for orchestration, health monitoring, and telemetry.

* **`GET /live`**
    * **Description**: Liveness probe for Docker/K8s.
    * **Response**: `200 OK` ("Alive")
* **`GET /ready`**
    * **Description**: Readiness probe. Confirms all shards and the WAL are memory-mapped.
    * **Response**: `200 OK` ("Ready")
* **`GET /stats`**
    * **Description**: Returns global telemetry, including total keys and active geometry.
    * **Response**: `200 OK` (JSON fragment)

---

### 📦 Key-Value Operations (Data)
All data mutations and lookups are served under the `/keys/` prefix.

* **`GET /keys/{key}`**
    * **Description**: Retrieves a value using Binary Search ($O(\log N)$) directly from RAM.
    * **Success**: `200 OK` (Exact binary payload with dynamic `Content-Length`).
    * **Error**: `404 Not Found` if the key does not exist.

* **`POST /keys/{key}`**
    * **Description**: Stores or updates a value.
    * **Headers**: Requires `Content-Length` for precise binary ingestion.
    * **Body**: Raw data (up to `ROCK_SLOT_SIZE` minus metadata).
    * **Success**: `200 OK` ("Stored").
    * **Error**: `400 Bad Request` if the key exceeds `ROCK_KEY_SIZE`.

* **`DELETE /keys/{key}`**
    * **Description**: Removes a key and collapses the shard to maintain index integrity.
    * **Success**: `200 OK` ("Deleted").

---

### 🔍 Advanced Querying (Range Scan)

* **`GET /keys?prefix={S}&limit={X}&startkey={K}`**
    * **Description**: High-performance range scan within a specific shard.
    * **Performance**: Complexity of $O(\log N + K)$.

| Parameter | Default | Max | Description |
| :--- | :--- | :--- | :--- |
| **`prefix`** | (Required) | `ROCK_KEY_SIZE` | Target keys starting with this string. Determines the shard. |
| **`limit`** | **50** | **500** | Maximum number of results to return. |
| **`startkey`** | (Prefix) | `ROCK_KEY_SIZE` | Begin scan at first key $\ge$ than this value (Pagination). |

---

### Quick Start Examples (CURL)

```bash
# 1. Store a user session (Automatically sends Content-Length)
curl -X POST http://localhost:8080/keys/user123 -d '{"session": "active", "id": 99}'

# 2. Check global database statistics
curl http://localhost:8080/stats

# 3. Retrieve the session (Zero-Copy read from RAM)
curl -i http://localhost:8080/keys/user123

# 4. Delete the session
curl -i -X DELETE http://localhost:8080/keys/user123

# 5. Store a raw binary file (Binary-Safe storage)
curl -X POST http://localhost:8080/keys/favicon -H "Content-Type: application/octet-stream" --data-binary @favicon.ico

# 6. List the first 50 keys starting with 'user_'
curl "http://localhost:8080/keys/?prefix=user_&limit=50"

# 7. Deep Pagination: Get next 50 keys starting after 'user_100'
curl "http://localhost:8080/keys/?prefix=user_&limit=50&startkey=user_100"

# 8. Check global database statistics
curl http://localhost:8080/stats
```

---

## 🏗️ Architecture

* **The Core**: A raw x86_64 binary running on a `scratch` Docker image.
* **Storage**: Uses `sys_mmap` (ID 9) to link a physical file to the process's memory space.
* **Security**: Runs as a non-privileged user (`UID 1000`) defined in the Dockerfile.
* **Sidecar Documentation**: A Swagger UI instance serving the `openapi.yaml` contract.

### 🧠 Logic Under the Hood

The engine is engineered for deterministic performance and zero-overhead execution by operating directly on the Linux kernel ABI.



#### 🏗️ Distributed Memory Architecture (Sharding)
Instead of a single monolithic file, the engine implements a **Deterministic Sharding** system to scale storage while maintaining $O(\log N)$ search efficiency.

* **Header (Slot 0)**: The first 256 bytes are reserved for metadata.
    * **Offset 0-7**: `TotalKeyCount` (64-bit unsigned integer).
    * **Offset 8-255**: Reserved for future use (e.g., versioning, checksums).
* **Data Slots (0-65534)**: Fixed **1024-byte** blocks.
    * **Key Field**: 32 bytes (null-padded).
    * **Length Field**: 2 bytes (`uint16` storing the exact payload size).
    * **Type Field**: 1 byte (Status flag, e.g., active/deleted).
    * **Value Field**: 989 bytes of raw binary data.
* **Addressing Formula**:
  $$Address(index) = BaseAddress + 256 + (index \times 1024)$$

---

#### 🔍 Search & Indexing
By partitioning the data, the **Binary Search** algorithm operates only on the relevant 64MB segment.

* **Algorithm**: Binary Search within the targeted shard.
* **Efficiency**: Any key among the 65,535 possible slots per shard is found or rejected in a maximum of **16 comparisons**.
* **Memory Locality**: Sharding improves CPU cache hits by keeping relevant key-groups within the same memory-mapped page.

---

#### 🛠️ Data Lifecycle (CRUD)

1. **Insertion (POST)**:
- Finds the correct alphabetical position via binary search.
- If a new slot is needed, it uses the `std` (Set Direction Flag) and `rep movsq` instructions to shift existing data blocks down, creating an atomic-like "hole" for the new entry.
- Increments the `TotalKeyCount` in the header and appends the operation to the WAL.

2. **Retrieval (GET)**:
- Sanitizes the URI and isolates the key.
- Executes the binary search against the data slots (skipping the header).
- Reads the exact binary length from the 2-byte Length prefix to construct the `Content-Length` header, enabling Binary-Safe transfers.

3. **Deletion (DELETE)**:
- Locates the key.
- "Collapses" the gap by shifting all subsequent blocks up by 1024 bytes.
- Decrements the `TotalKeyCount` and logs the deletion to the WAL.

---

#### 🚀 Performance Features
* **Zero-Copy**: Data moves directly from the network buffer to the memory map using CPU string instructions.
* **No Heap**: The engine uses zero dynamic memory allocation (`malloc`). All operations use the stack or pre-allocated `.bss` segments.
* **Minimal Context Switches**: By bypassing `libc` and standard I/O libraries, the execution path from the network socket to the disk-backed RAM is the shortest possible on x86_64.
* **Hardware-Level Comparisons**: Uses the `repe cmpsb` instruction for high-speed string matching during routing and searching.

---



### 📂 Database File Internals (Multi-Shard)

The engine manages an internal array of pointers (`db_ptrs`) pointing to 27 independent memory-mapped segments.

| File Path | Key Range | Offset Calculation |
| :--- | :--- | :--- |
| `db/a.db` | Keys starting with `A` or `a` | `db_ptrs[0]` |
| `db/m.db` | Keys starting with `M` or `m` | `db_ptrs[12]` |
| `db/z.db` | Keys starting with `Z` or `z` | `db_ptrs[25]` |
| `db/misc.db`| Numbers (`0-9`), `_`, `-`, etc. | `db_ptrs[26]` |

Each shard is a binary file of exactly 67,108,864 bytes (64MB). Below is the memory map for any given shard:

| Offset (Hex) | Offset (Dec) | Size | Content | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0x00000` | 0 | 8 B | **TotalKeyCount** | `uint64` (Little Endian) tracking active records. |
| `0x00008` | 8 | 248 B | **Reserved** | Padding for future metadata expansion. |
| `0x00100` | 256 | 1024 B | **Slot 0** | The first alphabetically sorted record. |
| `0x00500` | 1280 | 1024 B | **Slot 1** | Start of the second key-value pair. |
| ... | ... | ... | ... | ... |
| `0x3FFF700` | 67,106,560 | 1024 B | **Slot 65534** | Final available slot before the 64MB boundary. |

#### 🧮 Address Calculation
The engine resolves any record's position in $O(1)$ using the following formula:

$$Address(index) = BaseAddress + 256 + (index \times 1024)$$

---

### 🛠️ Binary Inspection Tools

Data is deterministically partitioned. To verify integrity, inspect the specific shard corresponding to the key's first letter.

**1. Check the Key Counter for a specific shard (e.g., 'U' shard):**
```bash
# How many keys start with 'u'?
od -An -N8 -t d8 db/u.db
```

**2. Inspect a Specific Slot:**
To view the second actual data record (skipping the 256-byte metadata header and the first 1KB slot), use `xxd`:
```bash
xxd -s 1280 -l 1024 db/misc.db
```

**3. Monitor File State:**
Since we use a fixed-size allocation model, the database file sizes never fluctuate. This prevents filesystem fragmentation and ensures predictable performance:
```bash
ls -lh db/a.db
# Output should always be exactly 64.0M
```

---

### 🛡️ Write-Ahead Logging (WAL) & ACID Durability

By default, the Linux Kernel uses a "write-back" cache strategy for memory-mapped files, which means physical commits to the SSD/HDD might be delayed. To guarantee **ACID-like Durability** and survive sudden power losses, the engine implements a synchronous **Write-Ahead Log (WAL)**.

Every mutation is serialized to a persistent log (`wal.log`) *before* the memory-mapped B-Tree is modified in RAM.

### 📂 Database File Internals (Multi-Shard)

The engine manages an internal array of pointers (`db_ptrs`) pointing to 27 independent memory-mapped segments. Each shard is a binary file of exactly **67,108,864 bytes (64MB)**.



| Offset (Hex) | Offset (Dec) | Size | Content | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0x00000` | 0 | 8 B | **TotalKeyCount** | `uint64` (Little Endian) tracking active records. |
| `0x00008` | 8 | 248 B | **Reserved** | Padding for future metadata expansion. |
| `0x00100` | 256 | 1024 B | **Slot 0** | The first alphabetically sorted record. |
| `0x00500` | 1280 | 1024 B | **Slot 1** | Start of the second key-value pair. |
| ... | ... | ... | ... | ... |
| `0x3FFF700` | 67,107,840 | 1024 B | **Slot 65535** | Final available slot before the 64MB boundary. |

#### 🧮 Address Calculation
The engine resolves any record's position in $O(1)$ using the following formula:

$$Address(index) = BaseAddress + 256 + (index \times 1024)$$

#### 🛠️ Technical Implementation & Hardware Commit
The engine invokes the `sys_fdatasync` (ID 75) syscall immediately after every log entry append:

* **Syscall**: `sys_fdatasync` (RAX: 75)
* **Behavior**: This forces the CPU to block until the storage controller acknowledges that the data is physically committed to the non-volatile medium. The HTTP `200 OK` response is only sent to the client once the data is "on the metal."


---

## 🛠️ Project Structure

The project is organized into modular assembly components, following the "Separation of Concerns" principle to maintain clarity in a zero-dependency environment.

```text
.
├── src/
│   ├── main.asm            # Entry point, Signal handling & Event Loop
│   ├── config.inc          # Global constants (Shard sizes, Offsets)
│   ├── core/
│   │   ├── router.asm      # URI Validation & Handler dispatching
│   │   ├── recovery.asm    # WAL Replay & State restoration logic
│   │   └── utils.asm       # Logging system & Environment parsing
│   ├── data/
│   │   ├── btree.asm       # Binary Search & Memory-map indexing
│   │   ├── storage.asm     # Shard initialization & mmap management
│   │   └── wal.asm         # Write-Ahead Log append logic (fdatasync)
│   └── handlers/
│       ├── get.asm         # GET: Zero-copy retrieval
│       ├── set.asm         # POST: Data insertion & WAL logging
│       ├── del.asm         # DELETE: Gap collapse & Persistence
│       └── stats.asm       # STATS: Cross-shard key aggregation
├── tests/
│   ├── test_engine.sh      # Core integration suite (14 tests)
│   └── test_recovery.sh    # Crash-test & WAL persistence suite
├── Dockerfile              # Multi-stage: Alpine (NASM/LD) -> Scratch
├── docker-compose.yaml     # Service orchestration & Volume mapping
└── openapi.yaml            # API Specification (Swagger UI)
```

### 🏗️ Build & Deployment Components

* **The Core**: A raw x86_64 binary compiled with `nasm` and linked with `ld`, running on a `scratch` Docker image.
* **Storage**: Self-managed files using `sys_mmap` (ID 9) to bridge physical disk shards with process memory.
* **Security**: The binary drops all unnecessary privileges, running as `UID 1000`.
* **Sidecar Documentation**: A Swagger UI instance providing a visual interface for the `openapi.yaml` contract.

---

## 🛡️ Write-Ahead Logging (WAL) & Crash Recovery

By default, the Linux Kernel uses a "write-back" cache strategy for memory-mapped files. This means that while a `POST` is reflected in RAM instantly, the physical commit to the disk might be delayed by the Kernel's I/O scheduler.

To bridge this gap and provide **ACID-like Durability**, "La Roca" implements a synchronous Write-Ahead Log.



### ⚙️ The Hardware-Commit Guarantee
Every time a mutation (`SET` or `DELETE`) occurs, the engine performs a two-step persistence dance:

1. **Serialized Append**: The operation is formatted into a 1024-byte block and appended to `db/wal.log`.
2. **Physical Sync**: The engine invokes the `sys_fdatasync` (ID 75) syscall.
    * **RAX**: 75
    * **RDI**: `wal_fd`
    * **Effect**: The CPU blocks until the storage controller confirms that the bytes have physically touched the non-volatile medium (SSD/HDD).

Only after the hardware acknowledges the write, the engine proceeds to update the B-Tree in RAM and sends the `200 OK` to the client.

---

### 🧪 Crash Recovery (The "Resurrection" Loop)
When the engine starts, before opening the network socket or accepting a single connection, the `recover_from_wal` module takes control of the process.

#### The Algorithm:
1. **Rewind**: Uses `sys_lseek` (ID 8) to move the `wal_fd` pointer to the absolute beginning of the log.
2. **Sequential Scan**:
    - Reads exactly **1024 bytes** into a temporary stack buffer.
    - If `sys_read` returns `0`, it's the end of the log (Success).
    - If `sys_read` returns `< 1024`, it detects a **partial write** (a crash happened exactly during a log append). It halts recovery to protect shard integrity.
3. **Deterministic Replay**:
    - Parses the **Opcode** (Byte 0).
    - Resolves the target shard using the **Key** (Bytes 3-34).
    - Re-executes the operation (`btree_insert` or `btree_delete`) directly into the memory-mapped shards.
4. **Consistency Achieved**: Once the EOF is reached, the in-memory shards are an exact mirror of the last confirmed state before the crash.

## 💎 The Integrity Guard (WAL Lifecycle)

Data safety is not optional. **La Roca** implements a hardware-accelerated integrity cycle that ensures your data is never "liar's data" (corrupted state).

### 🔄 The Write-Ahead Flow
Every mutation follows a strict, blocking path to guarantee durability:

1.  **Payload Ingestion**: Raw binary data enters the `request_buf`.
2.  **Buffer Alignment**: The data is formatted into a fixed 1KB block.
3.  **Hardware Signature**: The engine invokes the **SSE4.2 `CRC32` instruction**, generating a checksum of the entire 1024-byte block.
4.  **Synchronous Commit**: The record is appended to `wal.log` using the `O_DSYNC` flag, forcing the storage controller to confirm the write before the CPU proceeds.
5.  **Memory-Map Mutation**: Only after the disk confirms the write, the B-Tree in RAM is updated.

### 🧬 The Resurrection Logic (CRC32 Validation)
During the recovery phase at startup, the engine operates as a "Purity Filter":

```text
[ WAL.LOG ] -> [ Read 1KB Block ] -> [ Calculate Hardware CRC32 ]
                                               |
                                               v
             [ Corrupted? ] <--- [ Compare with Stored Hash ]
                  |                            |
                  | (YES: Mismatch)            | (NO: Integrity OK)
                  v                            v
           [ HALT RECOVERY ]          [ Replay to B-Tree ]
           [ Log Error     ]          [ Continue Scan    ]
           
---

### 🏁 The "Immortal Data" Test
You can verify this architecture by running the dedicated recovery suite:

```bash
# This script writes data, SIGKILLs the container, and verifies its resurrection.
./tests/test_recovery.sh
```

> **Performance Note:** While `sys_fdatasync` introduces disk I/O latency, it ensures that your data is safe from power failures. In our assembly implementation, this is the only point where the engine "slows down" to wait for hardware.

---

## 🔒 Network Hardening

Operating at the System Call level requires manual implementation of security boundaries. "La Roca" is designed with a "Zero-Trust" approach to network input.

### 🛡️ Buffer Overflow & Injection Protection
Since we don't use `libc` functions like `scanf` or `gets`, we have granular control over every byte entering the CPU.

1. **Strict Input Limits**: The `sys_read` (ID 0) syscall is hard-coded to read a maximum of **2047 bytes** into a 2048-byte buffer. This leaves exactly one byte for a guaranteed safety exit.
2. **Manual Null-Termination Guard**: Immediately after the network read, the engine manually injects a `0x00` (NULL) byte at `buffer[bytes_read]`.
3. **Safe Parsing**: All string operations (routing, key extraction) use the `lodsb` instruction, which is programmed to halt execution or trigger an error if a NULL byte is encountered unexpectedly, preventing "Over-read" attacks.

---

### 🚦 Fail-Fast Routing
The router doesn't "guess" or try to fix malformed requests. If a request doesn't perfectly match the expected pattern, the engine terminates the connection immediately.

* **Length-Aware Keys**: Any key extracted from a URI that exceeds 31 bytes (plus null terminator) is rejected with a `400 Bad Request` before any database shard is even opened.
* **Header Sanitization**: The engine only parses the `Content-Length` header. All other headers are ignored and discarded to prevent "Header Smuggling" or slow-loris style attacks.

---

### 👤 Non-Privileged Execution
The Docker container is configured to drop all kernel capabilities and run as a specific non-root user.

* **User ID**: 1000 (`asmuser`).
* **Environment**: The `scratch` image contains no shell (`/bin/sh`), no libraries, and no external binaries. Even if an attacker achieved Remote Code Execution (RCE), there are no tools or environment available to pivot or escalate privileges.

---

## 🏗️ Horizontal Scaling (Cluster Mode)

"La Roca" is designed around the **Shared-Nothing Architecture** principle. Each instance has absolute ownership of its own RAM and its physical `db/` directory. By avoiding cross-node synchronization, we eliminate network overhead and locking contention.



### 🎡 Consistent Hashing
To scale to millions of concurrent requests, routing is delegated to a high-performance proxy (like **Envoy** or **HAProxy**) using **Consistent Hashing** based on the Request URI.

1. The proxy hashes the key (e.g., `/user_99`).
2. It maps that hash to a specific node in the cluster.
3. All requests for `/user_99` (GET, POST, DELETE) *always* land on the same node.

### 🚀 Deployment Example (Envoy + Docker)
You can spin up a 3-node cluster where each node is an independent 10KB Assembly binary.

**docker-compose.yaml**
```yaml
services:
  envoy:
    image: envoyproxy/envoy:v1.27.0
    volumes:
      - ./envoy.yaml:/etc/envoy/envoy.yaml
    ports:
      - "80:8080"

  node-1:
    image: micro-kv-asm:1.0.0
    volumes: ["./data/n1:/app/db"]

  node-2:
    image: micro-kv-asm:1.0.0
    volumes: ["./data/n2:/app/db"]
```

**envoy.yaml (Snippet)**
To route based on the key, we use the `RING_HASH` policy:
```yaml
clusters:
- name: kv_cluster
  lb_policy: RING_HASH
  load_assignment:
    cluster_name: kv_cluster
    endpoints:
    - lb_endpoints:
      - endpoint: { address: { socket_address: { address: node-1, port_value: 8080 }}}
      - endpoint: { address: { socket_address: { address: node-2, port_value: 8080 }}}
  common_lb_config:
    ring_hash_lb_config:
      minimum_ring_size: 1024
```

> **Why this works:** Since our engine is so lightweight, you can run hundreds of nodes on a single machine, each pinned to a specific CPU core, achieving near-hardware-limit performance across the entire keyspace.

### ☸️ Kubernetes Deployment (Helm)

For production-grade environments, we provide a **Zero-Bloat Helm Chart** designed to orchestrate a high-performance cluster in seconds. This isn't just a deployment script; it's a pre-configured architecture that leverages **Envoy Proxy** to handle distributed state.

#### Quick Start
```bash
# Clone the repository
git clone https://github.com/blockmaker/la-roca-micro-kv.git
cd la-roca-micro-kv

# Deploy the full cluster (Core + Envoy Proxy)
helm install la-roca ./charts/la-roca
```

#### The "Caged" Architecture
The chart automatically configures a **Headless Service** and an **Envoy Front-Proxy** with the following features:

* **Consistent Ring Hashing:** Envoy is pre-configured to route requests based on the `x-key` header. This ensures that even as you scale, a specific key always hits the same Assembly-native shard.
* **Resource Pinning:** Each pod is "caged" with the exact CPU/RAM limits validated in our [Benchmarks](./BENCHMARKS.md), ensuring deterministic micro-latency.
* **Automatic Discovery:** Envoy dynamically updates its hash ring as Kubernetes scales the La Roca pods up or down.

> **Engineering Tip:** To achieve the performance levels seen in our reports (2,300+ req/s), ensure your Kubernetes nodes have enough headroom to avoid the orchestrator's CPU throttling.

---



## 🚀 Usage & Persistence

Running "La Roca" is straightforward, but because it operates directly on the Linux Kernel ABI as a non-privileged user, specific attention must be paid to volume permissions.

### 📋 Prerequisites
* **Docker & Docker Compose**
* **Linux Kernel 4.x+** (Standard for most modern distros/WSL2)

---

### 🏁 Getting Started

1. **Clone and Build**:
   ```bash
   # Build the 10KB binary and initialize the environment
   docker-compose up --build -d
   ```

2. **Verify Initialization**:
   The engine will automatically create 27 shards of 64MB each in the mapped directory.
   ```bash
   # Check if shards are present
   ls -lh ./db
   ```

3. **Smoke Test**:
   ```bash
   # Check overall statistics (should return 0 initially)
   curl http://localhost:8080/stats
   ```

---

### 💾 Data Persistence (Docker Volumes)

By default, the database shards reside inside the container's volatile layer. For production or durability tests, you **must** use a persistent volume.



#### Option 1: Named Volumes (Recommended)
Docker manages the storage and ensures the internal `asmuser` (UID 1000) has correct access.
```yaml
# In your docker-compose.yml
services:
  api:
    volumes:
      - kv_data:/app/db

volumes:
  kv_data:
```

#### Option 2: Bind Mounts (Direct File Inspection)
Use this if you want to run `xxd` or `hexdump` on the `.db` files from your host machine.

> ⚠️ **PERMISSION GUARDRAIL**: The Assembly binary runs as **UID 1000**. If your host folder is owned by `root`, the engine will trigger a `FATAL` error on startup.

**The Fix:**
```bash
mkdir -p ./db
sudo chown -R 1000:1000 ./db
```

---

### 🛠️ Troubleshooting Common Issues

| Symptom | Cause | Resolution |
| :--- | :--- | :--- |
| **Container exits immediately** | Permission Denied. | Check `docker logs`. Run `chown -R 1000:1000` on your DB folder. |
| **`400 Bad Request`** | URI/Key format. | Ensure keys are < 32 chars and don't contain special characters not handled by the router. |
| **`507 Insufficient Storage`** | Shard is full. | A single letter-shard has reached 65,535 records. Delete old keys or expand `SLOTS_PER_SHARD` in `config.inc`. |
| **Empty `/stats` after restart** | No volume mounted. | Your data was stored in the container's RAM/volatile layer. Map a volume to `/app/db`. |

> **Note**: Swagger UI may trigger a CORS error when testing from a browser because the engine prioritizes a minimal network footprint. Use `curl` or Postman for reliable testing.

---

## 🧠 Technical Deep Dive

This service doesn't use `libc`. It implements the **TCP/IP stack interaction** using direct Linux System Calls:

* **`sys_socket` (41)**: Creates the network endpoint.
* **`sys_bind` (49)**: Attaches the service to port 8080.
* **`sys_listen` (50)**: Prepares the socket to receive incoming connections.
* **`sys_accept` (43)**: Accepts and handles incoming HTTP requests.
* **`repe cmpsb`**: A hardware-level instruction used to compare the requested URI against `/live` or `/ready` with maximum efficiency.

The entire application runs in a **Scratch** Docker image, meaning there is no operating system, no shell, and no libraries—just the 10.1 KB binary executing directly on the container's kernel.

---

## 📂 Memory Layout & Shard Internals

"La Roca" handles data with surgical precision. Every byte in the 27 database shards is deterministically placed, allowing for $O(1)$ addressing without any overhead or metadata parsing during search operations.



### 🏗️ Shard Structure (64MB Files)
Each shard file (`db/a.db` through `db/misc.db`) is pre-allocated to exactly 67,108,864 bytes.

| Offset (Hex) | Size | Name | Description |
| :--- | :--- | :--- | :--- |
| `0x00000` | 8 B | **TotalKeyCount** | Atomic `uint64` (Little Endian) counter. |
| `0x00008` | 248 B | **Header Padding** | Reserved for future metadata (versioning, flags). |
| `0x00100` | 1024 B | **Slot 0** | The first data record. |
| `0x00500` | 1024 B | **Slot 1** | The second data record. |
| `...` | `...` | `...` | `...` |
| `0x3FFF700` | 1024 B | **Slot 65534** | Final slot before the 64MB boundary. |

---

### 📦 Data Slot Format (The 1KB Block)
Every key-value pair occupies exactly **1024 bytes (1KB)**. This alignment ensures that records never straddle memory pages or disk sectors unnecessarily.

| Offset (Inside Slot) | Size | Content | Technical Detail |
| :--- | :--- | :--- | :--- |
| `+0` | 32 B | **Key** | Raw ASCII/Binary key (null-padded). |
| `+32` | 2 B | **Length** | `uint16` storing the exact payload size (0-989). |
| `+34` | 1 B | **Status/Type** | `0x01` for Active, `0x00` for Empty/Deleted. |
| `+35` | 989 B | **Value** | Raw binary payload (Binary-Safe). |

**Addressing Formula:**
To find the start of any record by its index:
$$Address(index) = BaseAddress + 256 + (index \times 1024)$$

---

### 📜 WAL Record Format (Write-Ahead Log)
The `wal.log` file is a sequential stream of atomic records. To maintain maximum I/O performance and sector alignment, each log entry is also exactly **1024 bytes**.

| Offset | Size | Field | Description |
| :--- | :--- | :--- | :--- |
| `0x00` | 1 B | **Opcode** | `0x01` (SET/UPDATE) or `0x02` (DELETE). |
| `0x01` | 2 B | **DataLen** | Exact length of the following value. |
| `0x03` | 32 B | **Key** | The key involved in the operation. |
| `0x23` | 989 B | **Value** | The raw payload (ignored during DELETE). |

> **Recovery Note:** During startup, the engine reads these 1KB blocks sequentially. If a read returns less than 1024 bytes, the engine assumes a partial write occurred during a crash and halts recovery to prevent corrupting the shards.


---


## 💾 Data Persistence (Docker Volumes)

By default, the 27 database shards reside inside the container's volatile write layer. To ensure your data survives a `docker-compose down` or a container update, you must mount a persistent volume to the `/app/db` directory.



### Option 1: Named Volumes (Recommended)
This is the most robust way to handle persistence. Docker manages the underlying storage and ensures the `asmuser` (UID 1000) has the correct permissions automatically.

**Update your `docker-compose.yaml`:**
```yaml
services:
  kvs-api:
    build: .
    ports:
      - "8080:8080"
    volumes:
      - kv_shards:/app/db

volumes:
  kv_shards:
```

---

### Option 2: Bind Mounts (For Direct Inspection)
If you want to access the .db files directly from your host machine (e.g., to run hexdump or xxd without entering the container), use a bind mount.

**Update your `docker-compose.yaml`:**
```yaml
services:
  kvs-api:
    volumes:
      - ./my_local_db:/app/db
```
[!CAUTION]

Permission Guardrail: Because the Assembly binary runs as UID 1000, your local host folder must be accessible by that specific UID. If you see a 500 Internal Error or sys_open failure, run the following on your host machine:

```bash
mkdir -p my_local_db
sudo chown -R 1000:1000 my_local_db
```


---

### 🔍 Troubleshooting

Since the engine operates directly on the Linux Kernel ABI, errors are usually related to memory permissions, file descriptors, or strict protocol adherence.

| Issue | Potential Cause | Technical Explanation & Resolution |
| :--- | :--- | :--- |
| **`500 Internal Error`** | Permission Denied in `/db`. | The Assembly binary runs as `UID 1000`. If the `/db` folder was created by `root`, `sys_open` will fail. **Fix**: `chown -R 1000:1000 db/`. |
| **`400 Bad Request`** | Key length or format. | Keys must be between 1 and 31 characters. The engine uses a fixed 32-byte buffer for keys (including the null terminator). |
| **`404 Not Found`** | Key missing or wrong shard. | Ensure the key exists. Remember that `User123` and `user123` might land in different shards if the router is case-sensitive. |
| **`507 DB Full`** | Shard capacity reached. | A single shard has hit the 65,535 slot limit. Even if other shards are empty, this specific letter-range is full. **Fix**: Delete unused keys or expand slot size in `storage.asm`. |
| **`Binary output` warning** | Raw data in terminal. | `curl` detects null bytes or non-printable characters in the value. **Fix**: Use `curl -v` or pipe to `cat -v` to see raw content safely. |
| **Empty `/stats` (0)** | Database reset. | Without a Docker Volume, the `/db` directory is volatile. **Fix**: Add `volumes: - ./db:/app/db` to your `docker-compose.yaml`. |
| **Segmentation Fault** | Mmap corruption. | Usually happens if the `kv.db` file is manually edited/truncated while the engine is running. **Fix**: Restart the container to re-map the memory segments. |

---

#### 🛠️ Debugging with `strace`
To see exactly what the Kernel is doing when a request fails, you can trace the system calls:

```bash
# Trace file and network operations in the container
docker-compose exec api strace -p 1 -e openat,mmap,msync,write
```

---

### 🏁 The "Immortal Data" Test

You can verify the durability of the engine by simulating a catastrophic failure:

1. **Store a value**:
   ```bash
   curl -X POST http://localhost:8080/vault -d "gold_bars"
   ```
2. **Simulate a Crash:** Kill the process violently (bypassing clean shutdowns):
   ```bash
   docker-compose kill -s SIGKILL api
   # OR: pkill -9 micro_rest
   ```

2. **Resurrect:** Restart the container/process.
Verify Persistence:
   ```bash
   curl http://localhost:8080/vault
   # Output: gold_bars (Recovered from WAL)
   ```

---
## 🧪 Testing & Validation

The project includes a comprehensive, multi-layered automated testing infrastructure designed to guarantee memory safety, protocol compliance, and ACID-like durability.

### 🚀 Master Test Runner
The most efficient way to audit the engine is through the master orchestrator. This script executes all specialized suites in a fail-fast pipeline.

```bash
# Execute all mandatory suites
./run_all_tests.sh

# Execute all suites + K6 high-pressure stress test
./run_all_tests.sh --stress
```

---

### 1. Functional Integration Suite (CRUD & B-Tree)
Verifies the core database logic: binary-safe storage, lexicographical sorting, and range scans via the `/keys` namespace.

```bash
# Ensure the container is running first
docker-compose up -d

# Run the functional suite
./tests/test_engine.sh
```

### 2. Security & Hardening (Protocol Boundary)
Validates the "Iron-Clad" architecture by attempting to break the engine using malformed HTTP requests and buffer flooding.

```bash
# Run security and protocol audits
./tests/test_security.sh
```
*Tests: Missing Content-Length (411), Oversized Payloads (413), 1KB Header Scan Limits.*

### 3. The "Immortal Data" Crash Test (WAL Recovery)
This test proves the Write-Ahead Log (WAL) architecture. It spins up an isolated container, writes data, **violently kills the process** (simulating power loss), and resurrects the engine to prove data is replayed from disk into the memory-mapped B-Tree.

```bash
./tests/test_recovery.sh
```

### 4. Config & Persistence
Ensures that runtime geometry (Key/Value sizes) and environment variables are correctly persisted and reflected across shards.

```bash
./tests/test_config_persistence.sh
```

---

### ⚡ Stress Testing & Benchmarking
To measure the raw power of the **Zero-Copy / No-LibC** architecture, we use direct Linux Kernel syscalls.

#### Modern Observability (K6)
```bash
k6 run tests/stress_test.js
```

#### Raw Throughput (Apache Bench)
```bash
# Send 100,000 requests with 100 concurrent connections
ab -c 100 -n 100000 http://localhost:8080/live
```
*Note: Because the engine bypasses `libc` and uses a zero-allocation event loop, you will likely saturate your local network loopback interface before maxing out the CPU.*
---

## ⚙️ Runtime & Geometry Configuration

"La Roca" features a surgical environment parser built entirely in Assembly that scans the **Linux Process Stack** (`envp`) at boot time. This allows for total geometric flexibility without the overhead of external libraries or configuration files.

### 🌍 Environment Variables

Configure these variables in your `docker-compose.yaml` or `.env` file to tune the engine's footprint:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LOG_LEVEL` | `error` | `trace` (all), `error` (404/500 only), `none` (max performance). |
| `ROCK_PORT` | `8080` | The TCP port the engine binds to. |
| `ROCK_KEY_SIZE` | `32` | **Key Geometry**: Max byte-size for keys. Supports UUIDs, URLs, etc. |
| `ROCK_SLOT_SIZE` | `1024` | **Total Slot Geometry**: Total size per record (Key + 3 bytes metadata + Value). |

### 🛡️ The "Disk Authority" Hierarchy

To prevent fatal memory misalignment, "La Roca" enforces a strict hierarchy of authority. Once a Shard is initialized, its geometry is **permanently etched** into the file header.

1.  **Disk Header (Primary)**: If a shard exists, the engine reads `SLOT_SIZE` and `KEY_SIZE` from the disk and **ignores** environment variables.
2.  **Environment Variables**: These are only used to "format" new shards during the first boot.
3.  **Hardcoded Defaults**: Fallback values from `config.inc`.

> [!IMPORTANT]  
> If you set a `ROCK_SLOT_SIZE` that is smaller than the required space for the key and metadata, the engine will automatically expand the slot to the **minimum viable size** to prevent buffer overflows.

---

### 📊 Real-time Telemetry (`/stats`)

The engine provides a high-performance telemetry endpoint. It aggregates atomic counters from all 27 shards and reports the active dynamic geometry.

**Request:**
```bash
curl http://localhost:8080/stats
```

**Response:**
```json
{
"engine": "La Roca Micro-KV",
"status": "online",
"port": 8080,
"slot_size_bytes": 1024,
"shard_capacity": 65536,
"total_shards": 27,
"key_size_bytes": 32,
"total_keys": 59
}
```

---

### 🛠️ Technical Implementation

Unlike standard applications, this service implements:
1.  **Dynamic Memory Mapping**: Offsets for Length, Type, and Value are calculated at runtime: `Value_Offset = Key_Size + 3`.
2.  **Stack Scanning**: Manual iteration of the `envp` block to resolve variables before the socket even opens.
3.  **Zero-Allocation JSON**: The `/stats` response is constructed via a custom `itoa` (Integer to ASCII) engine that streams directly to the socket buffer.
4.  **Disk Locking**: Geometry metadata is locked in the first 256 bytes (Header) of each Shard file.
### 🕵️ How to View Logs

To monitor the internal routing and storage decisions in real-time:

```bash
docker-compose logs -f kvs-api
```

---

## 🤝 Contact & Collaboration

This project is a testament to the power of low-level engineering and the "Zero-Dependency" philosophy. If you are interested in high-performance systems, operating system internals, or just want to discuss why Assembly is still relevant in the era of Cloud Native, let's connect!

**Fernando E. Mancuso** *Head of Engineering at Blockmaker S.R.L.*

* **LinkedIn**: [Fernando Ezequiel Mancuso](https://www.linkedin.com/in/fernando-ezequiel-mancuso-54a2737/)
* **Email**: [fernando.mancuso@blockmaker.net](mailto:fernando.mancuso@blockmaker.net)
* **GitHub**: [@fermancuso-blockmaker](https://github.com/fermancuso-blockmaker)

---

> "The best way to understand how a computer works is to stop asking the operating system for permission and start giving it orders."



## 🏢 Backed by BlockMaker S.R.L.

**La Roca Micro-KV** was engineered from scratch by the engineering team at **BlockMaker S.R.L.**, led by **Fernando Ezequiel Mancuso** (Head of Engineering).

At BlockMaker, we believe in deep tech, zero-dependency architectures, and pushing the absolute limits of hardware efficiency. We are actively encouraging the global engineering community to fork, benchmark, and contribute to this project.

If you love low-level systems engineering and uncompromising performance, feel free to reach out at [fernando.mancuso@blockmaker.net](mailto:fernando.mancuso@blockmaker.net).
