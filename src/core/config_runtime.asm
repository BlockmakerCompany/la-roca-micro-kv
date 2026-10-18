; -----------------------------------------------------------------------------
; Module: src/core/config_runtime.asm
; Project: La Roca Micro-KV
; Responsibility: Dynamic Configuration Store & Initialization Logic.
; -----------------------------------------------------------------------------
%include "config.inc"

; External dependencies
extern parse_env_vars
extern log_msg

section .data
    ; Default hardcoded values (Fallback)
    def_port            dq 8080
    def_key_size        dq 32
    def_val_max_size    dq 985      ; 🛡️ FIXED! Adjusted to fit perfectly within 1024 bytes (WAL/Shard)

    err_key_size        db "[FATAL] ROCK_KEY_SIZE must be 1..32 (WAL stores a fixed 32-byte key).", 0x0A
    err_key_size_l      equ $ - err_key_size
    err_val_size        db "[FATAL] rt_val_max_size exceeds the WAL value area (985 bytes).", 0x0A
    err_val_size_l      equ $ - err_val_size
    err_node_keys       db "[FATAL] rt_node_max_keys exceeds the 16-bit node header.", 0x0A
    err_node_keys_l     equ $ - err_node_keys

    shard_zero_path     db "db/shard_0.db", 0

section .bss
    global rt_port, rt_key_size, rt_val_max_size, rt_slot_size
    global rt_slots_per_shard, rt_shard_size
    global rt_offset_len, rt_offset_type, rt_offset_val
    global rt_entry_size, rt_node_max_keys

    rt_port             resq 1
    rt_key_size         resq 1
    rt_val_max_size     resq 1
    rt_slot_size        resq 1
    rt_slots_per_shard  resq 1
    rt_shard_size       resq 1

    rt_offset_len       resq 1
    rt_offset_type      resq 1
    rt_offset_val       resq 1

    rt_entry_size       resq 1      ; B+ Tree entry = key_size + 8-byte pointer
    rt_node_max_keys    resq 1      ; (page_size - header_size) / entry_size

section .text
    global init_runtime_config
    global recalc_offsets

; -----------------------------------------------------------------------------
; init_runtime_config
; -----------------------------------------------------------------------------
init_runtime_config:
    push rbp
    mov rbp, rsp
    push rdx                    ; Save envp pointer

    ; 1. Load Defaults
    call _load_defaults
    call recalc_offsets

    ; 2. Check if Database already exists
    mov rax, 2                  ; sys_open
    lea rdi, [shard_zero_path]
    mov rsi, 0                  ; O_RDONLY
    syscall

    test rax, rax
    js _no_existing_db

    ; 3. Existing DB - Force geometry from Shard 0
    mov rdi, rax                ; FD
    call _sync_with_shard

    mov rax, 3                  ; sys_close
    syscall
    jmp _init_exit

_no_existing_db:
    pop rdx                     ; Restore envp
    push rdx
    test rdx, rdx
    jz _init_exit
    call parse_env_vars
    call recalc_offsets         ; Recalculate after Env Vars

_init_exit:
    pop rdx
    leave
    ret

; -----------------------------------------------------------------------------
; recalc_offsets: Calculates slot internal map based on rt_key_size
; -----------------------------------------------------------------------------
recalc_offsets:
    ; --- 🛡️ GEOMETRY VALIDATION (before any division or layout math) ---
    ; The WAL stores a fixed 32-byte key; key_size > 32 would truncate the key
    ; in the WAL and make recovery insert spurious entries, so refuse to start.
    ; key_size == 0 would make rt_entry_size == 8 and the div below is still
    ; safe, but the layout math is meaningless — require >= 1 explicitly.
    mov rax, [rt_key_size]
    test rax, rax
    jz .fatal_key_size
    cmp rax, 32
    ja .fatal_key_size

    ; rt_val_max_size is the WAL value area (985 bytes). It is not env-tunable,
    ; but guard it so a future change can't silently overflow wal_buf/tmp_val.
    mov rax, [rt_val_max_size]
    cmp rax, 985
    ja .fatal_val_size

    mov rax, [rt_key_size]
    mov [rt_offset_len], rax     ; Len starts after Key
    add rax, 2
    mov [rt_offset_type], rax    ; Type starts after Len
    add rax, 1
    mov [rt_offset_val], rax     ; Val starts after Type

    ; Calculate minimum required slot_size = current_offsets + val_max_size
    mov rbx, rax
    add rbx, [rt_val_max_size]

    ; --- RULE OF AUTHORITY (PADDING PRESERVATION) ---
    ; If current rt_slot_size is less than min required, update it.
    ; If it's larger (user requested padding like 2048), keep the user's value.
    cmp [rt_slot_size], rbx
    jae .done_recalc             ; Jump if above or equal (keep current)
    mov [rt_slot_size], rbx      ; Otherwise, expand to minimum

.done_recalc:
    ; --- B+ TREE ENTRY GEOMETRY (dynamic key width) ---
    ; entry = key_size + 8 (child/slot pointer). node_max_keys is recomputed
    ; so the leaf split logic stays correct for any key geometry.
    mov rax, [rt_key_size]
    add rax, 8
    mov [rt_entry_size], rax

    mov rax, BTREE_PAGE_SIZE
    sub rax, BTREE_HEADER_SIZE
    xor rdx, rdx
    div qword [rt_entry_size]
    cmp rax, 65535
    ja .fatal_node_keys         ; node header stores key count as a 16-bit word
    mov [rt_node_max_keys], rax
    ret

.fatal_key_size:
    lea rsi, [err_key_size]
    mov rdx, err_key_size_l
    call log_msg
    mov rax, 60                 ; sys_exit
    mov rdi, 1
    syscall

.fatal_val_size:
    lea rsi, [err_val_size]
    mov rdx, err_val_size_l
    call log_msg
    mov rax, 60
    mov rdi, 1
    syscall

.fatal_node_keys:
    lea rsi, [err_node_keys]
    mov rdx, err_node_keys_l
    call log_msg
    mov rax, 60
    mov rdi, 1
    syscall

; --- Private: Load Defaults ---
_load_defaults:
    mov rax, [def_port]
    mov [rt_port], rax
    mov rax, [def_key_size]
    mov [rt_key_size], rax
    mov rax, [def_val_max_size]
    mov [rt_val_max_size], rax

    ; --- VITAL PATCH FOR CRUD OPERATIONS ---
    ; Assigning a high initial capacity.
    ; Later, the engine (storage.asm or env_parser) will recalculate it exactly
    ; based on the actual SLOT_SIZE.
    mov rax, 60000
    mov [rt_slots_per_shard], rax
    ret

; --- Private: Sync with Shard Header ---
_sync_with_shard:
    sub rsp, 256
    mov rsi, rsp
    mov rdx, 256
    mov rax, 0                  ; sys_read
    syscall

    ; Offset 8: SLOT_SIZE
    mov rax, [rsp + 8]
    test rax, rax
    jz _sync_done
    mov [rt_slot_size], rax

    ; Offset 32: KEY_SIZE
    mov rax, [rsp + 32]
    test rax, rax
    jz _sync_recalc
    mov [rt_key_size], rax

_sync_recalc:
    call recalc_offsets

_sync_done:
    add rsp, 256
    ret