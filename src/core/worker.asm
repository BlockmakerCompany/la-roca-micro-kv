; -----------------------------------------------------------------------------
; Module: src/core/worker.asm
; Project: La Roca Micro-KV
; Responsibility: The Writer Thread (Consumer) and Ring Buffer logic.
;                 Manages async handoff with the Reader Thread.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- Telemetry Macro ---
%macro DEBUG_LOG 1
    section .data
        %%msg db "[DEBUG:WORKER] ", %1, 0x0A
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
%endmacro

extern handle_set
extern handle_del
extern async_handoff        ; 🛡️ BANDERA GLOBAL PARA EL TRASPASO

section .bss
    global queue_head
    global queue_tail
    global job_queue

    queue_head   resq 1
    queue_tail   resq 1

    ; Array of 16 Jobs. Each job is 8208 bytes
    job_queue    resb 131328

section .text
    global writer_entry_point
    global enqueue_job

; =============================================================================
; THE CONSUMER: WRITER THREAD MAIN LOOP
; =============================================================================
writer_entry_point:
    DEBUG_LOG "Writer Thread Online. Awaiting jobs."

.writer_poll:
    mov rax, [queue_head]
    mov rbx, [queue_tail]
    cmp rax, rbx
    je .writer_sleep

    DEBUG_LOG "Job detected! Dequeuing..."

    mov rcx, 16
    xor rdx, rdx
    div rcx
    imul rdx, 8208
    lea r14, [job_queue + rdx]

    mov rdx, [r14]              ; FD
    mov r12, [r14 + 8]          ; Opcode
    lea rsi, [r14 + 16]         ; Buffer

    cmp r12, 1
    je .do_set
    cmp r12, 2
    je .do_del
    jmp .job_done

.do_set:
    DEBUG_LOG "Dispatching to handle_set..."
    call handle_set
    jmp .job_done

.do_del:
    DEBUG_LOG "Dispatching to handle_del..."
    call handle_del

.job_done:
    lock inc qword [queue_head]
    DEBUG_LOG "Job complete. Queue Head advanced."
    jmp .writer_poll

.writer_sleep:
    sub rsp, 16
    mov qword [rsp], 0
    mov qword [rsp+8], 1000000
    mov rax, 35
    mov rdi, rsp
    xor rsi, rsi
    syscall
    add rsp, 16
    jmp .writer_poll

; =============================================================================
; THE PRODUCER: ENQUEUE FUNCTION (Called by Reader Thread)
; =============================================================================
enqueue_job:
    DEBUG_LOG "Reader Thread: Enqueuing new job..."
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r12, rdi
    mov r13, rsi
    mov r14, rdx

    mov rax, [queue_tail]
    mov rcx, 16
    xor rdx, rdx
    div rcx
    imul rdx, 8208
    lea rbx, [job_queue + rdx]

    mov [rbx], r12
    mov [rbx + 8], r13

    lea rdi, [rbx + 16]
    mov rsi, r14
    mov rcx, 1024
    cld
    rep movsq

    lock inc qword [queue_tail]

    ; 🛡️ LEVANTAMOS LA BANDERA PARA QUE MAIN.ASM ABANDONE EL SOCKET
    mov byte [async_handoff], 1

    DEBUG_LOG "Reader Thread: Job successfully placed in Ring Buffer."

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret