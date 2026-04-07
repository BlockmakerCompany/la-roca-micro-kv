; -----------------------------------------------------------------------------
; Module: src/core/storage.asm
; Project: La Roca Micro-KV
; Responsibility: Storage Orchestration & Deterministic Sharding.
;                 Manages 27 independent shards (64MB each) using sys_mmap.
;                 Enforces Disk Authority (Slot Size & Key Size) over Env Vars.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- External Variables for Dynamic Geometry ---
extern rt_key_size
extern rt_slot_size
extern rt_slots_per_shard
extern recalc_offsets           ; From config_runtime.asm
extern btree_init

section .data
    db_dir       db "db", 0
    db_misc_name db "db/misc.db", 0
    db_size      equ 67108864    ; Hardcoded 64MB
    MS_SYNC      equ 4           ; MS_SYNC flag for sys_msync

    msg_init     db "Storage: Initializing 27 shards (64MB each)...", 0
    msg_init_l   equ $ - msg_init
    err_shard    db "Storage: FATAL - Failed to initialize shard system.", 0
    err_shard_l  equ $ - err_shard

section .bss
    global db_ptrs
    db_ptrs      resq 27
    shard_name   resb 64

section .text
    global init_storage
    global flush_shard
    global get_shard_ptr

; -----------------------------------------------------------------------------
; get_shard_ptr: Resolves the shard base address based on the key.
; -----------------------------------------------------------------------------
get_shard_ptr:
    movzx rax, byte [rsi]
    cmp al, 'A'
    jl .not_upper
    cmp al, 'Z'
    jg .not_upper
    add al, 32
.not_upper:
    sub al, 'a'
    cmp al, 25
    jbe .valid_alpha
    mov rax, 26
    jmp .load_ptr
.valid_alpha:
    movzx rax, al
.load_ptr:
    shl rax, 3
    lea rcx, [db_ptrs]
    mov rdx, [rcx + rax]
    ret

; -----------------------------------------------------------------------------
; flush_shard: Synchronizes memory pages with the physical disk.
; -----------------------------------------------------------------------------
flush_shard:
    mov rax, 26                 ; sys_msync
    mov rsi, db_size
    mov rdx, MS_SYNC
    syscall
    ret

; -----------------------------------------------------------------------------
; init_storage: Bootstraps shards and enforces Disk Authority Hierarchy.
; -----------------------------------------------------------------------------
init_storage:
    push r12
    push r13

    ; --- Log initialization dynamically ---
    mov rdi, LOG_INFO
    lea rsi, [msg_init]
    mov rdx, msg_init_l
    call log_event

    ; Create 'db/' directory
    mov rax, 83                 ; sys_mkdir
    lea rdi, [db_dir]
    mov rsi, 0755o
    syscall

    xor r12, r12
.shard_loop:
    cmp r12, 27
    je .done

    call build_shard_name

    ; Open/Create File
    mov rax, 2
    lea rdi, [shard_name]
    mov rsi, 66                 ; O_RDWR | O_CREAT
    mov rdx, 0644o
    syscall
    test rax, rax
    js .fail
    mov r13, rax

    ; Space Pre-allocation
    mov rax, 77
    mov rdi, r13
    mov rsi, db_size
    syscall

    ; Memory Mapping
    mov rax, 9
    xor rdi, rdi
    mov rsi, db_size
    mov rdx, 3
    mov r10, 1
    mov r8, r13
    xor r9, r9
    syscall
    cmp rax, -1
    je .fail

    lea rcx, [db_ptrs]
    mov [rcx + r12*8], rax

    ; =========================================================================
    ; 🛡️ DISK AUTHORITY LOCK (Slot & Key Geometry)
    ; Header Layout:
    ;   [0-7]   : Total Keys (QWORD)
    ;   [8-15]  : Slot Size (QWORD)
    ;   [32-39] : Key Size (QWORD)
    ; =========================================================================
    mov rbx, rax                ; RBX = Shard Base Pointer

    ; Read Slot Size (Offset 8)
    ; A shard can have 0 keys but still be initialized with a geometry!
    mov r15, qword [rbx + 8]

    test r15, r15
    jnz .existing_db            ; If Slot Size > 0, disk is initialized!

    ; Path A: Truly New/Empty DB. Write current Runtime Config to Disk Header.
    mov r15, [rt_slot_size]
    mov qword [rbx + 8], r15
    mov r15, [rt_key_size]
    mov qword [rbx + 32], r15

    ; =========================================================================
    ; 🌳 B+ TREE INIT (Per-Shard Geometry)
    ; Offset 16 = Root Pointer
    ; Offset 24 = Next Free Pointer (Allocator)
    ; =========================================================================
    mov qword [rbx + 16], 0     ; 0 significa que aún no hay nodo raíz
    mov qword [rbx + 24], 256   ; La memoria libre arranca justo después del Header

    ; Llamar a inicializar el árbol para ESTE shard específico
    mov rdi, rbx                ; RDI = Puntero base (mmap) del Shard actual
    call btree_init             ; Crea el nodo raíz de 4KB y actualiza los offsets
    jmp .cleanup_fd

.existing_db:
    ; Path B: Existing DB. Sync Runtime Config with Disk Values.
    mov [rt_slot_size], r15     ; Force Slot Size from Disk (r15 already has it)

    mov r15, qword [rbx + 32]   ; Load Key Size from Disk
    test r15, r15
    jz .recalc_cap              ; Safety fallback
    mov [rt_key_size], r15

    ; Force internal offset recalculation to match Disk Authority
    call recalc_offsets

.recalc_cap:
    ; Update capacity: rt_slots_per_shard = (64MB - 256) / rt_slot_size
    mov rax, db_size
    sub rax, 256
    xor rdx, rdx
    mov rbx, [rt_slot_size]
    div rbx
    mov [rt_slots_per_shard], rax
    ; =========================================================================

.cleanup_fd:
    mov rax, 3
    mov rdi, r13
    syscall

    inc r12
    jmp .shard_loop

.done:
    pop r13
    pop r12
    ret

.fail:
    ; --- Log the fatal error dynamically before dying ---
    mov rdi, LOG_ERROR
    lea rsi, [err_shard]
    mov rdx, err_shard_l
    call log_event

    mov rax, 60                 ; sys_exit
    mov rdi, 1
    syscall

; -----------------------------------------------------------------------------
; build_shard_name: Constructs path strings "db/a.db"..."db/misc.db"
; -----------------------------------------------------------------------------
build_shard_name:
    push rax
    push rdi
    push rsi
    lea rdi, [shard_name]
    cmp r12, 26
    je .copy_misc
    mov byte [rdi], 'd'
    mov byte [rdi+1], 'b'
    mov byte [rdi+2], '/'
    add rdi, 3
    mov al, 'a'
    add al, r12b
    stosb
    mov dword [rdi], 0x0062642E
    jmp .exit
.copy_misc:
    lea rsi, [db_misc_name]
    mov rcx, 12
    rep movsb
.exit:
    pop rsi
    pop rdi
    pop rax
    ret