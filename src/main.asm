; -----------------------------------------------------------------------------
; Module: src/main.asm
; Project: La Roca Micro-KV
; Responsibility: Orchestrates dynamic initialization and the main event loop.
;                 Implements synchronous I/O, HTTP Keep-Alive, and spawns
;                 the secondary Writer Thread for concurrent operations.
; -----------------------------------------------------------------------------
%include "config.inc"

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
    msg_writer   db "[INFO] Writer Thread spawned successfully.", 0x0A
    len_writer   equ $ - msg_writer

section .bss
    global log_level
    global wal_fd
    global async_handoff        ; 🛡️ GLOBAL HANDOFF FLAG

    async_handoff resb 1
    log_level    resb 1
    server_fd    resq 1
    wal_fd       resq 1
    client_fd    resq 1
    ka_flag      resb 1         ; Keep-Alive state flag
    request_buf  resb 8192
    debug_num    resb 16        ; Buffer for ITOS telemetry

    ; 1. Stack for the writing thread (64KB)
    writer_stack resb 65536

    ; 2. The Sequential Lock (0 = Free/Even, 1 = Writing/Odd)
    global seq_lock
    seq_lock     resq 1

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

    ; --- Step 7: Dynamic Binding ---
    mov ax, [rt_port]
    xchg al, ah                 ; Byte-swap for Network Byte Order
    mov [sockaddr + 2], ax

    mov rax, 49                 ; sys_bind
    mov rdi, [server_fd]
    lea rsi, [sockaddr]
    mov rdx, 16
    syscall

    mov rax, 50                 ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 128                ; Increased backlog for high-concurrency
    syscall

    mov rdi, 1
    lea rsi, [msg_start]
    mov rdx, len_start
    call log_msg

    jmp .accept_loop

.clone_failed:
    ; Exit gracefully if thread spawning fails
    mov rax, 60
    mov rdi, 1
    syscall

; -----------------------------------------------------------------------------
; MAIN EVENT LOOP (Reader Thread)
; -----------------------------------------------------------------------------
.accept_loop:
    mov rax, 43                 ; sys_accept
    mov rdi, [server_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall

    test rax, rax
    js .accept_loop
    mov [client_fd], rax

    ; 🛡️ Set SO_RCVTIMEO to prevent Keep-Alive deadlocks
    mov rax, 54                 ; sys_setsockopt
    mov rdi, [client_fd]
    mov rsi, 1                  ; SOL_SOCKET
    mov rdx, 20                 ; SO_RCVTIMEO
    lea r10, [tv_timeout]       ; struct timeval
    mov r8, 16                  ; sizeof(timeval)
    syscall

.keep_alive_loop:
    cld                         ; 1. Direction forward

    ; 🛡️ Clear the Async Handoff Flag for this new request
    mov byte [async_handoff], 0

    ; --- 2. Clean the buffer (Total reset to avoid ghost data) ---
    lea rdi, [request_buf]
    xor rax, rax
    mov rcx, 1024               ; 8192 bytes
    rep stosq

    ; --- 3. Fresh Read from Socket ---
    mov rax, 0                  ; sys_read
    mov rdi, [client_fd]
    lea rsi, [request_buf]
    mov rdx, 8191
    syscall

    ; --- 📊 TELEMETRY BLOCK ---
    push rax                    ; Save actual bytes read
    test rax, rax
    jle .skip_telemetry

    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_debug_read]
    mov rdx, len_debug_read
    syscall

    pop rax
    push rax
    call .print_rax_metrics

    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_debug_hex]
    mov rdx, len_debug_hex
    syscall

    mov rax, 1
    mov rdi, 1
    lea rsi, [request_buf]
    mov rdx, 24                 ; 24 bytes to see the path
    syscall

    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_newline]
    mov rdx, 1
    syscall

.skip_telemetry:
    pop rax                     ; Recover original RAX (bytes read)

    test rax, rax
    jle .close_client

    ; Null-terminate for scanners
    lea rbx, [request_buf]
    mov byte [rbx + rax], 0

    ; --- 5. Keep-Alive Detection ---
    push rax
    lea rdi, [request_buf]
    mov rsi, rax
    call check_keep_alive
    mov [ka_flag], al
    pop rax

    ; --- 6. Route Dispatch ---
    mov rdi, [client_fd]
    lea rsi, [request_buf]
    call route_request

    ; --- 7. Decision ---
    ; 🛡️ CHECK MEMORY FLAG: Did the router push this to the Worker Queue?
    cmp byte [async_handoff], 1
    je .accept_loop             ; YES: Abandon socket, Writer Thread owns it now!

    cmp byte [ka_flag], 1
    je .keep_alive_loop         ; NO: Standard Keep-Alive handling

.close_client:
    mov rax, 3
    mov rdi, [client_fd]
    syscall
    jmp .accept_loop

; --- Helper: ITOS for Telemetry ---
.print_rax_metrics:
    lea rdi, [debug_num + 15]
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
    lea rdx, [debug_num + 15]
    sub rdx, rdi
    mov rdi, 1
    syscall
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