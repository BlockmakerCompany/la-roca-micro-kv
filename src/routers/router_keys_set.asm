; -----------------------------------------------------------------------------
; Module: src/routers/router_keys_set.asm
; Project: La Roca Micro-KV
; Responsibility: Route POST requests.
;                 Delegates processing to the Writer Thread via Ring Buffer.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- Conditional Trace Macro ---
%macro TRACE 1
    %ifdef TRACE_ENABLED
        section .data
            %%msg db "[TRACE:KEYS_SET] ", %1, 0x0A
            %%len equ $ - %%msg
        section .text
            push rax
            push rdi
            push rsi
            push rdx
            mov rax, 1
            mov rdi, 1
            lea rsi, [%%msg]
            mov rdx, %%len
            syscall
            pop rdx
            pop rsi
            pop rdi
            pop rax
    %endif
%endmacro

; --- External Primitives ---
extern enqueue_job

section .text
    global route_keys_set

; -----------------------------------------------------------------------------
; route_keys_set: Logic for POST /keys/{key}
; Input:
;   RDI = Client Socket FD
;   RSI = Request Buffer
; -----------------------------------------------------------------------------
route_keys_set:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13

    mov r12, rdi                ; r12 = Socket FD
    mov r13, rsi                ; r13 = Buffer

    TRACE "Sub-router SET (POST) activated. Enqueuing job..."

    ; 1. Push to the Message Queue (Ring Buffer)
    mov rdi, r12                ; Arg 1: FD
    mov rsi, 1                  ; Arg 2: Opcode (1 = SET)
    mov rdx, r13                ; Arg 3: Raw Request Buffer
    call enqueue_job

    ; 2. Signal the routing chain that this route matched.
    ; (main.asm will see async_handoff == 1 and abandon the socket).
    mov rax, 1

    pop r13
    pop r12
    pop rbx
    leave
    ret