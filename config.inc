; -----------------------------------------------------------------------------
; Module: config.inc
; Project: La Roca Micro-KV
; Responsibility: Global Architectural Constants & Memory Geometry.
;                 Defines the binary-safe slot structure and shard dimensions.
; -----------------------------------------------------------------------------

; --- Dynamic Log Levels ---
%define LOG_NONE  0
%define LOG_ERROR 1
%define LOG_INFO  2
%define LOG_TRACE 3

; 🛡️ PREPROCESSOR GUARD: Prevents redefinition errors when compiling utils.asm
%ifndef UTILS_MODULE
    extern log_event
%endif

; --- Slot Geometry (Fixed-width for O(1) addressing) ---
%define KEY_SIZE        32              ; Max bytes for a key (including null-terminator)
%define VAL_MAX_SIZE    985             ; 🛡️ UPDATED: 985 bytes to accommodate CRC32 padding
%define SLOT_SIZE       1024            ; 1KB per record (Power of 2: 2^10)
                                        ; Optimized for CPU cache line alignment.

; --- Shard Geometry (Multi-shard partitioning) ---
%define SLOTS_PER_SHARD 65536           ; 64K records per shard (2^16)
%define SHARD_SIZE      67108864        ; 64MB per shard file (SLOT_SIZE * SLOTS_PER_SHARD)
                                        ; Total Engine capacity: 27 shards * 64MB ≈ 1.7GB

; --- Write-Ahead Log (WAL) Structure ---
; Hardened Layout: CRC32(4) + OpCode(1) + DataLen(2) + Key(32) + Value(985) = 1024 Bytes
%define WAL_RECORD_SIZE 1024            ; 🛡️ UPDATED: Perfect sector alignment

; --- Memory Offsets (Internal Data Slot) ---
; [KEY(32)] [LEN(2)] [TYPE(1)] [VALUE(985)] [PADDING(4)] = 1024 Bytes
%define OFFSET_LEN      32              ; Offset within slot for Payload Length
%define OFFSET_TYPE     34              ; Offset within slot for Record Status
%define OFFSET_VAL      35              ; Offset within slot for Binary Payload

; --- B+ Tree Geometry (Shared with config_runtime) ---
; A tree entry is [KEY(rt_key_size)] [CHILD/POINTER(8)]; node layout is fixed.
%define BTREE_PAGE_SIZE    262144       ; 256KB Mega-Page per node
%define BTREE_HEADER_SIZE  19           ; Node header: type(1) keys(2) parent(8) next(8)

; -----------------------------------------------------------------------------
; Per-Thread Context (TLS) — accessed via FS segment base.
; Each reader thread sets FS to its own block (clone CLONE_SETTLS / arch_prctl).
; Writer thread does NOT use TLS (handlers are self-contained with own buffers).
; -----------------------------------------------------------------------------
%define TLS_SELF            0          ; qword: pointer to this thread's TLS block itself
%define TLS_CLIENT_FD       8          ; qword: accepted socket fd
%define TLS_KA_FLAG         16         ; byte:  keep-alive detection result
%define TLS_ASYNC_HANDOFF   17         ; byte:  router handed socket to writer
%define TLS_REQUEST_BUF     32         ; 8192 bytes: raw HTTP request
%define TLS_VALIDATED_KEY   8224       ; 256 bytes: extracted key
%define TLS_ASCII_LEN       8480       ; 16 bytes: Content-Length itoa buffer
%define TLS_Q_PREFIX        8496       ; 256 bytes: scan 'prefix' param
%define TLS_Q_STARTKEY      8752       ; 256 bytes: scan 'startkey' param
%define TLS_Q_LIMIT         9008       ; dword: scan 'limit' param
%define TLS_SIZE            9024       ; total per-thread context (16-byte aligned)

; -----------------------------------------------------------------------------
; Global Macros (Overloaded)
; -----------------------------------------------------------------------------

; 1-Argument Version: Expects TRACE "Literal String"
%macro TRACE 1
    section .data
        %%msg db "[TRACE] ", %1, 0x0A
        %%len equ $ - %%msg
    section .text
        push rax
        push rcx
        push rdx
        push rsi
        push rdi
        mov rdi, LOG_TRACE
        lea rsi, [%%msg]
        mov rdx, %%len
        call log_event
        pop rdi
        pop rsi
        pop rdx
        pop rcx
        pop rax
%endmacro

; 2-Argument Version: Expects TRACE msg_pointer, msg_length
%macro TRACE 2
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdi, LOG_TRACE
    lea rsi, [%1]
    mov rdx, %2
    call log_event
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endmacro