; -----------------------------------------------------------------------------
; Module: src/main.asm
; Project: La Roca Micro-KV
; Responsibility: Orchestrates dynamic initialization and the main event loop.
;                 Implements synchronous I/O, HTTP Keep-Alive, and spawns
;                 the secondary Writer Thread for concurrent operations.
; -----------------------------------------------------------------------------
%include "config.inc"

%define NUM_READERS     4           ; reader threads (parent + 3 children)
%define READER_STACK    65536       ; stack size per child reader thread

; --- External Engine Modules ---
extern init_runtime_config
extern rt_port
extern init_storage
extern parse_log_level
extern log_msg
extern route_request
extern recover_from_wal
extern writer_entry_point   ; <--- Import the Writer Thread from worker.asm

section .data
    ; sockaddr_in structure for IPv4
    sockaddr     db 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

    msg_start    db "[INFO] Micro-KV Engine started and listening", 0x0A
    len_start    equ $ - msg_start

    wal_path     db "db/wal.log", 0
    msg_wal      db "[INFO] WAL: Recovery complete. Integrity verified.", 0x0A
    len_wal      equ $ - msg_wal

    ; Telemetry strings
    msg_debug_read db "[DEBUG] Bytes read: ", 0
    len_debug_read equ $ - msg_debug_read
    msg_debug_hex  db " | Peek: ", 0
    len_debug_hex  equ $ - msg_debug_hex
    msg_newline    db 0x0A, 0

    act_ignore   dq 1, 0, 0, 0  ; SIG_IGN for SIGPIPE

    ; struct timeval { time_t tv_sec; suseconds_t tv_usec; }
    tv_timeout   dq 0, 10000        ; 10 milliseconds timeout for Keep-Alive sockets
    keep_alive_str db "keep-alive"

    ; Flags for sys_clone: CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD
    clone_flags  dq 0x010F00
    ; Same as above + CLONE_SETTLS (0x00080000): each reader thread gets its own FS base.
    reader_clone_flags dq 0x090F00
    msg_writer   db "[INFO] Writer Thread spawned successfully.", 0x0A
    len_writer   equ $ - msg_writer
    msg_reader   db "[INFO] Reader Thread online.", 0x0A
    len_reader   equ $ - msg_reader

section .bss
    global log_level
    global wal_fd

    log_level    resb 1
    server_fd    resq 1
    wal_fd       resq 1
    debug_num    resb 16        ; Buffer for ITOS telemetry

    ; 1. Stack for the writing thread (64KB)
    writer_stack resb 65536

    ; 2. Per-thread context (TLS) blocks for reader threads
    tls_blocks    resb NUM_READERS * TLS_SIZE

    ; 3. Stacks for the child reader threads (parent uses the main stack)
    reader_stacks resb (NUM_READERS - 1) * READER_STACK

section .text
    global _start

_start:
    cld

    ; --- Step 0: SIGPIPE Shielding ---
    mov rax, 13
    mov rdi, 13
    lea rsi, [act_ignore]
    xor rdx, rdx
    mov r10, 8
    syscall

    ; --- Step 1: Dynamic Configuration ---
    mov r8, [rsp]
    lea rdx, [rsp + 16 + r8*8]
    call init_runtime_config

    ; --- Step 2: Logging Setup ---
    mov r8, [rsp]
    lea rdi, [rsp + 16 + r8*8]
    call parse_log_level
    mov [log_level], al

    ; --- Step 3: Storage Mapping ---
    call init_storage

    ; --- Step 4: 🛡️ Hardened WAL Opening ---
    mov rax, 2                  ; sys_open
    lea rdi, [wal_path]
    mov rsi, 0x1442             ; Hardened flags (Sync + Append)
    mov rdx, 0644o              ; Permissions
    syscall
    mov [wal_fd], rax

    ; Replay the log to restore state in memory
    call recover_from_wal

    mov rdi, 1
    lea rsi, [msg_wal]
    mov rdx, len_wal
    call log_msg

    ; --- Step 5: Spawn the Writer Thread (sys_clone) ---
    mov rax, 56                 ; sys_clone
    mov rdi, [clone_flags]
    lea rsi, [writer_stack + 65536] ; Top of the new stack
    xor rdx, rdx
    xor r10, r10
    xor r8, r8
    syscall

    test rax, rax
    js .clone_failed            ; If < 0, sys_clone failed
    jz writer_entry_point       ; If 0, WE ARE THE NEW WRITER THREAD! Jump to worker.asm

    ; --- MAIN THREAD (Reader) CONTINUES HERE ---
    mov rdi, 1
    lea rsi, [msg_writer]
    mov rdx, len_writer
    call log_msg

    ; --- Step 6: Network Stack Initialization ---
    mov rax, 41                 ; sys_socket
    mov rdi, 2                  ; AF_INET
    mov rsi, 1                  ; SOCK_STREAM
    xor rdx, rdx
    syscall
    mov [server_fd], rax

    ; Set SO_REUSEADDR
    mov rax, 54
    mov rdi, [server_fd]
    mov rsi, 1
    mov rdx, 2
    push 1
    mov r10, rsp
    mov r8, 4
    syscall
    pop rax

    ; Set SO_REUSEPORT
    mov rax, 54
    mov rdi, [server_fd]
    mov rsi, 1
    mov rdx, 15
    push 1
    mov r10, rsp
    mov r8, 4
    syscall
    pop rax

    ; --- Step 7: Dynamic Binding ---
    mov ax, [rt_port]
    xchg al, ah                 ; Byte-swap for Network Byte Order
    mov [sockaddr + 2], ax

    mov rax, 49                 ; sys_bind
    mov rdi, [server_fd]
    lea rsi, [sockaddr]
    mov rdx, 16
    syscall
    test rax, rax
    js .bind_failed

    mov rax, 50                 ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 128                ; Increased backlog for high-concurrency
    syscall

    mov rdi, 1
    lea rsi, [msg_start]
    mov rdx, len_start
    call log_msg

    ; --- Step 8: Initialize TLS self-pointers and set parent FS base ---
    xor rcx, rcx
.init_tls_self:
    cmp rcx, NUM_READERS
    je .init_tls_done
    mov rax, rcx
    imul rax, TLS_SIZE
    lea rdx, [tls_blocks + rax]
    mov [rdx + TLS_SELF], rdx
    inc rcx
    jmp .init_tls_self
.init_tls_done:

    mov rax, 158                ; sys_arch_prctl
    mov rdi, 0x1002             ; ARCH_SET_FS
    lea rsi, [tls_blocks]       ; parent reader thread uses block 0
    syscall

    ; --- Step 9: Spawn NUM_READERS-1 child reader threads ---
    xor r12, r12                ; r12 = child index (0 .. NUM_READERS-2)
.spawn_readers:
    cmp r12, NUM_READERS - 1
    je .parent_reader

    ; TLS pointer for this child = tls_blocks + (r12+1)*TLS_SIZE
    mov rax, r12
    inc rax
    imul rax, TLS_SIZE
    lea r8, [tls_blocks + rax]  ; r8 = tls (CLONE_SETTLS -> FS base)

    ; Child stack top = reader_stacks + (r12+1)*READER_STACK
    mov rax, r12
    inc rax
    imul rax, READER_STACK
    lea rsi, [reader_stacks + rax]

    mov rax, 56                 ; sys_clone
    mov rdi, [reader_clone_flags]
    xor rdx, rdx                ; parent_tidptr
    xor r10, r10                ; child_tidptr
    syscall

    test rax, rax
    js .clone_failed
    jz reader_entry             ; child: enter accept loop with its own FS

    inc r12
    jmp .spawn_readers

.parent_reader:
    jmp reader_entry

.bind_failed:
.clone_failed:
    ; Exit gracefully if bind or thread spawning fails
    mov rax, 60
    mov rdi, 1
    syscall

; -----------------------------------------------------------------------------
; MAIN EVENT LOOP (Reader Thread)
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; READER ENTRY: each reader thread runs this accept/serve loop on its own TLS.
; -----------------------------------------------------------------------------
reader_entry:
    mov rax, 43                 ; sys_accept
    mov rdi, [server_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall

    test rax, rax
    js reader_entry
    mov [fs:TLS_CLIENT_FD], rax

    ; 🛡️ Set SO_RCVTIMEO to prevent Keep-Alive deadlocks
    mov rax, 54                 ; sys_setsockopt
    mov rdi, [fs:TLS_CLIENT_FD]
    mov rsi, 1                  ; SOL_SOCKET
    mov rdx, 20                 ; SO_RCVTIMEO
    lea r10, [tv_timeout]       ; struct timeval
    mov r8, 16                  ; sizeof(timeval)
    syscall

.keep_alive_loop:
    cld                         ; 1. Direction forward

    ; 🛡️ Clear the Async Handoff Flag for this new request
    mov byte [fs:TLS_ASYNC_HANDOFF], 0

    ; --- 2. Clean the buffer (Total reset to avoid ghost data) ---
    mov r11, [fs:TLS_SELF]
    lea rdi, [r11 + TLS_REQUEST_BUF]
    xor rax, rax
    mov rcx, 1024               ; 8192 bytes
    rep stosq

    ; --- 3. Fresh Read from Socket ---
    mov rax, 0                  ; sys_read
    mov rdi, [fs:TLS_CLIENT_FD]
    mov r11, [fs:TLS_SELF]
    lea rsi, [r11 + TLS_REQUEST_BUF]
    mov rdx, 8191
    syscall

    test rax, rax
    jle .close_client


    ; Null-terminate for scanners
    mov r11, [fs:TLS_SELF]
    lea rbx, [r11 + TLS_REQUEST_BUF]
    mov byte [rbx + rax], 0

    ; --- 5. Keep-Alive Detection ---
    push rax
    mov r11, [fs:TLS_SELF]
    lea rdi, [r11 + TLS_REQUEST_BUF]
    mov rsi, rax
    call check_keep_alive
    mov byte [fs:TLS_KA_FLAG], al
    pop rax

    ; --- 6. Route Dispatch ---
    mov rdi, [fs:TLS_CLIENT_FD]
    mov r11, [fs:TLS_SELF]
    lea rsi, [r11 + TLS_REQUEST_BUF]
    call route_request

    ; --- 7. Decision ---
    ; 🛡️ CHECK MEMORY FLAG: Did the router push this to the Worker Queue?
    cmp byte [fs:TLS_ASYNC_HANDOFF], 1
    je reader_entry             ; YES: Abandon socket, Writer Thread owns it now!

    cmp byte [fs:TLS_KA_FLAG], 1
    je .keep_alive_loop         ; NO: Standard Keep-Alive handling

.close_client:
    mov rax, 3
    mov rdi, [fs:TLS_CLIENT_FD]
    syscall
    jmp reader_entry

; --- Helper: ITOS for Telemetry ---
.print_rax_metrics:
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; Thread-safe stack buffer
    lea rdi, [rbp - 1]
    mov byte [rdi], 0
    mov rbx, 10
.itos_loop:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .itos_loop

    mov rax, 1
    mov rsi, rdi
    lea rdx, [rbp - 1]
    sub rdx, rdi
    mov rdi, 1
    syscall
    leave
    ret

; -----------------------------------------------------------------------------
; check_keep_alive: Scans for "keep-alive" (case-insensitive) in buffer.
; -----------------------------------------------------------------------------
check_keep_alive:
    push rbx
    push rcx
    push r8
    push r9
    xor rax, rax
    mov rcx, rsi
    sub rcx, 10
    jle .exit_ka

.scan_loop:
    mov r8, rdi
    lea r9, [keep_alive_str]
    mov rbx, 10
.cmp_loop:
    mov dl, [r8]
    or dl, 0x20
    mov r10b, [r9]
    cmp dl, r10b
    jne .not_match
    inc r8
    inc r9
    dec rbx
    jnz .cmp_loop
    mov rax, 1
    jmp .exit_ka
.not_match:
    inc rdi
    dec rcx
    jnz .scan_loop
.exit_ka:
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret