# -----------------------------------------------------------------------------
# Project: La Roca Micro-KV
# Toolchain: NASM + LD (Static ELF64)
# Responsibility: Build Orchestration & Test Automation.
# -----------------------------------------------------------------------------

# --- Toolchain Configuration ---
ASM       = nasm
# 🛡️ UPDATED: Removed -DTRACE_ENABLED. Logging is now 100% dynamic!
ASM_FLAGS = -f elf64 -i ./ -i src/include/
LD        = ld

# --- Directory Structure ---
SRC_DIR     = src
ROUTERS_DIR = $(SRC_DIR)/routers
BUILD_DIR   = build
BIN_DIR     = bin

# --- Object Manifest ---
OBJS = $(BUILD_DIR)/main.o \
       $(BUILD_DIR)/config_runtime.o \
       $(BUILD_DIR)/env_parser.o \
       $(BUILD_DIR)/http_parser.o \
       $(BUILD_DIR)/storage.o \
       $(BUILD_DIR)/router.o \
       $(BUILD_DIR)/router_system.o \
       $(BUILD_DIR)/router_keys.o \
       $(BUILD_DIR)/router_keys_get.o \
       $(BUILD_DIR)/router_keys_set.o \
       $(BUILD_DIR)/router_keys_search.o \
       $(BUILD_DIR)/security.o \
       $(BUILD_DIR)/recovery.o \
       $(BUILD_DIR)/utils.o \
       $(BUILD_DIR)/btree.o \
       $(BUILD_DIR)/search_engine.o \
       $(BUILD_DIR)/wal.o \
       $(BUILD_DIR)/base.o \
       $(BUILD_DIR)/set.o \
       $(BUILD_DIR)/get.o \
       $(BUILD_DIR)/del.o \
       $(BUILD_DIR)/scan.o \
       $(BUILD_DIR)/stats.o

# --- Primary Build Targets ---

all: prepare $(BIN_DIR)/micro_rest

prepare:
	@mkdir -p $(BUILD_DIR) $(BIN_DIR)

$(BIN_DIR)/micro_rest: $(OBJS)
	$(LD) $(OBJS) -o $(BIN_DIR)/micro_rest
	@echo "[SUCCESS] Static binary created at $(BIN_DIR)/micro_rest"

# --- Assembly Rules ---

# 1. Root Entry Point
$(BUILD_DIR)/main.o: $(SRC_DIR)/main.asm
	$(ASM) $(ASM_FLAGS) $< -o $@

# 2. Core Modules
$(BUILD_DIR)/config_runtime.o: $(SRC_DIR)/core/config_runtime.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/env_parser.o: $(SRC_DIR)/core/env_parser.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/http_parser.o: $(SRC_DIR)/core/http_parser.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/storage.o: $(SRC_DIR)/core/storage.asm
	$(ASM) $(ASM_FLAGS) $< -o $@

# 3. Router Tier (New Specialized Directory)
$(BUILD_DIR)/router.o: $(ROUTERS_DIR)/router.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/router_system.o: $(ROUTERS_DIR)/router_system.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/router_keys.o: $(ROUTERS_DIR)/router_keys.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/router_keys_get.o: $(ROUTERS_DIR)/router_keys_get.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/router_keys_set.o: $(ROUTERS_DIR)/router_keys_set.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/router_keys_search.o: $(ROUTERS_DIR)/router_keys_search.asm
	$(ASM) $(ASM_FLAGS) $< -o $@

# 4. Security & Utilities
$(BUILD_DIR)/security.o: $(SRC_DIR)/core/security.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/recovery.o: $(SRC_DIR)/core/recovery.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/utils.o: $(SRC_DIR)/core/utils.asm
	$(ASM) $(ASM_FLAGS) $< -o $@

# 5. Data Tier
$(BUILD_DIR)/btree.o: $(SRC_DIR)/data/btree.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/search_engine.o: $(SRC_DIR)/data/search_engine.asm
	$(ASM) $(ASM_FLAGS) $< -o $@
$(BUILD_DIR)/wal.o: $(SRC_DIR)/data/wal.asm
	$(ASM) $(ASM_FLAGS) $< -o $@

# 6. Handlers
$(BUILD_DIR)/%.o: $(SRC_DIR)/handlers/%.asm
	$(ASM) $(ASM_FLAGS) $< -o $@

# --- Automation & Testing ---

test: all
	@chmod +x run_all_tests.sh tests/*.sh
	./run_all_tests.sh

clean:
	@echo "[CLEAN] Removing build artifacts and binaries..."
	rm -rf $(BUILD_DIR) $(BIN_DIR)