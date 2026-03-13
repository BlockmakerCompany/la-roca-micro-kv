; -----------------------------------------------------------------------------
; Module: src/core/utils.asm
; Project: La Roca Micro-KV
; Responsibility: System utilities: Logging, Env parsing, and Spinlocks.
; -----------------------------------------------------------------------------

; 🛡️ PREPROCESSOR GUARD: Tells config.inc NOT to declare 'extern log_event'
%define UTILS_MODULE 1
%include "config.inc"

extern log_level            ; Defined in main.asm .bss section

section .data
    log_env_key  db "LOG_LEVEL="
    ts_open      db "[", 0
    ts_close     db "] ", 0
    newline      db 0x0A

    ; --- Concurrency Control ---
    global_shard_lock dq 0      ; 0 = Unlocked, 1 = Locked

section .bss
    ts_struct    resq 2         ; sys_clock_gettime: tv_sec, tv_nsec
    ascii_ts     resb 24        ; ITOS buffer

section .text
    global parse_log_level
    global log_event
    global log_msg
    global acquire_lock
    global release_lock

; -----------------------------------------------------------------------------
; acquire_lock: Atomic Spinlock using LOCK XCHG.
; -----------------------------------------------------------------------------
acquire_lock:
    mov rax, 1
.retry:
    lock xchg [global_shard_lock], rax
    test rax, rax
    jz .acquired
.pause:
    pause
    jmp .retry
.acquired:
    ret

; -----------------------------------------------------------------------------
; release_lock: Atomic release of the global lock.
; -----------------------------------------------------------------------------
release_lock:
    mov qword [global_shard_lock], 0
    ret

; -----------------------------------------------------------------------------
; parse_log_level: Extracts LOG_LEVEL from environment.
; -----------------------------------------------------------------------------
; Output: RAX = Configured Log Level Constant
; -----------------------------------------------------------------------------
parse_log_level:
    push rbp
    mov rbp, rsp
.env_loop:
    mov rsi, [rdi]
    test rsi, rsi
    jz .not_found
    push rdi
    mov rdi, log_env_key
    mov rcx, 10
    cld
    push rsi
    repe cmpsb
    pop rsi
    pop rdi
    je .found_key
    add rdi, 8
    jmp .env_loop
.found_key:
    mov al, [rsi + 10]
    cmp al, 't'             ; "trace"
    je .is_trace
    cmp al, 'i'             ; "info"
    je .is_info
    cmp al, 'e'             ; "error"
    je .is_error
    cmp al, 'n'             ; "none"
    je .is_none
    jmp .not_found

.is_trace:
    mov rax, LOG_TRACE
    jmp .done
.is_info:
    mov rax, LOG_INFO
    jmp .done
.is_error:
    mov rax, LOG_ERROR
    jmp .done
.is_none:
    mov rax, LOG_NONE
    jmp .done

.not_found:
    mov rax, LOG_ERROR      ; Default fallback: always show errors
.done:
    leave
    ret

; -----------------------------------------------------------------------------
; log_event: Dynamic severity-based logger (Frontend)
; -----------------------------------------------------------------------------
; Input: RDI = Severity (1=ERR, 2=INFO, 3=TRACE)
;        RSI = String Pointer
;        RDX = String Length
; -----------------------------------------------------------------------------
log_event:
    movzx rax, byte [log_level]
    cmp rdi, rax
    jg .skip_log            ; If msg severity > configured level, skip

    ; If it passes the filter, fallthrough to the timestamped logger
    jmp log_msg

.skip_log:
    ret

; -----------------------------------------------------------------------------
; log_msg: Timestamped STDERR logger (Backend)
; -----------------------------------------------------------------------------
; Input: RSI = String Pointer
;        RDX = String Length
; -----------------------------------------------------------------------------
log_msg:
    push rdi
    push rsi
    push rdx
    mov rax, 228                ; sys_clock_gettime
    xor rdi, rdi                ; CLOCK_REALTIME
    lea rsi, [ts_struct]
    syscall

    mov rax, 1                  ; sys_write
    mov rdi, 2                  ; stderr
    lea rsi, [ts_open]
    mov rdx, 1
    syscall

    mov rax, [ts_struct]
    call _print_rax_to_ascii

    mov rax, 1
    mov rdi, 2
    lea rsi, [ts_close]
    mov rdx, 2
    syscall

    pop rdx
    pop rsi
    mov rax, 1
    mov rdi, 2
    syscall

    mov rax, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall
    pop rdi
    ret

; -----------------------------------------------------------------------------
; _print_rax_to_ascii: ITOS helper.
; -----------------------------------------------------------------------------
_print_rax_to_ascii:
    lea rdi, [ascii_ts + 23]
    mov byte [rdi], 0
    mov rbx, 10
.itoa_l:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .itoa_l
    mov rsi, rdi
    lea rdx, [ascii_ts + 23]
    sub rdx, rdi
    mov rax, 1
    mov rdi, 2
    syscall
    ret