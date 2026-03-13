; -----------------------------------------------------------------------------
; Module: src/main.asm
; Project: La Roca Micro-KV
; Responsibility: Orchestrates dynamic initialization and the main event loop.
;                 Implements synchronous I/O for WAL durability.
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

section .data
    ; sockaddr_in structure for IPv4
    sockaddr     db 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

    msg_start    db "[INFO] Micro-KV Engine started and listening", 0x0A
    len_start    equ $ - msg_start

    wal_path     db "db/wal.log", 0
    msg_wal      db "[INFO] WAL: Recovery complete. Integrity verified.", 0x0A
    len_wal      equ $ - msg_wal

    act_ignore   dq 1, 0, 0, 0  ; SIG_IGN for SIGPIPE

section .bss
    global log_level
    global wal_fd
    log_level    resb 1
    server_fd    resq 1
    wal_fd       resq 1
    client_fd    resq 1
    request_buf  resb 2048

section .text
    global _start

_start:
    cld

    ; --- Step 0: SIGPIPE Shielding ---
    ; Prevents the process from dying if a client closes the connection abruptly.
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
    ; Flags used:
    ; O_RDWR (2) | O_CREAT (64) | O_APPEND (1024) | O_DSYNC (4096)
    ; O_DSYNC ensures that write() calls don't return until data is on physical disk.
    ; Total = 5186 (0x1442)
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

    ; --- Step 5: Network Stack ---
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

    ; --- Step 6: Dynamic Binding ---
    mov ax, [rt_port]
    xchg al, ah                 ; Byte-swap for Network Byte Order (Big Endian)
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

; -----------------------------------------------------------------------------
; MAIN EVENT LOOP
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

    ; Read request
    mov rax, 0
    mov rdi, [client_fd]
    lea rsi, [request_buf]
    mov rdx, 2047
    syscall

    test rax, rax
    jle .close_client

    ; Null-terminate for security scanners
    lea rbx, [request_buf]
    mov byte [rbx + rax], 0

    ; Dispatch to the Router System (Modular & Granular)
    mov rdi, [client_fd]
    lea rsi, [request_buf]
    call route_request

.close_client:
    ; The router/handlers should have closed it, but we enforce it as a safety net
    mov rax, 3
    mov rdi, [client_fd]
    syscall

    ; Request Buffer Sanitization (Zero-out sensitive data)
    lea rdi, [request_buf]
    xor al, al
    mov rcx, 256                ; Partial clear for performance
    rep stosq

    jmp .accept_loop