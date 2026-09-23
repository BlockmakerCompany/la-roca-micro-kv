; -----------------------------------------------------------------------------
; Module: src/core/worker.asm
; Project: La Roca Micro-KV
; Responsibility: The Writer Thread (Consumer) and Ring Buffer logic.
;                 Manages async handoff with the Reader Thread using a
;                 futex-based producer/consumer pair (no busy-poll, no
;                 silent overflow).
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

; --- Futex / Queue constants ---
%define SYS_FUTEX       202
%define FUTEX_WAIT      0
%define FUTEX_WAKE      1
%define QUEUE_CAPACITY  16
%define JOB_SIZE        8208

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
    je .writer_wait           ; Empty queue: sleep on queue_tail

    DEBUG_LOG "Job detected! Dequeuing..."

    mov rcx, QUEUE_CAPACITY
    xor rdx, rdx
    div rcx                   ; RAX = head/16, RDX = head % 16
    imul rdx, JOB_SIZE
    lea r14, [job_queue + rdx]

    mov rdx, [r14]            ; FD
    mov r12, [r14 + 8]        ; Opcode
    lea rsi, [r14 + 16]       ; Buffer

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
    ; Wake any producer blocked on a full queue (waiting on queue_head).
    mov rax, SYS_FUTEX
    lea rdi, [queue_head]
    mov rsi, FUTEX_WAKE
    mov rdx, 1
    xor r10, r10
    syscall
    DEBUG_LOG "Job complete. Queue Head advanced."
    jmp .writer_poll

.writer_wait:
    ; Sleep until a producer wakes us on queue_tail. RBX still holds the tail
    ; value we observed; if a producer advances tail before we sleep, FUTEX_WAIT
    ; returns EAGAIN immediately (no lost wakeup).
    mov rax, SYS_FUTEX
    lea rdi, [queue_tail]
    mov rsi, FUTEX_WAIT
    mov rdx, rbx              ; expected value = current tail
    xor r10, r10
    syscall
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

    mov r12, rdi              ; FD
    mov r13, rsi              ; Opcode
    mov r14, rdx              ; Buffer

.enqueue_wait:
    mov rax, [queue_tail]
    mov rbx, [queue_head]
    mov rcx, rax
    sub rcx, rbx
    cmp rcx, QUEUE_CAPACITY
    jae .queue_full           ; No free slot: backpressure

    ; Compute slot from tail
    mov rcx, QUEUE_CAPACITY
    xor rdx, rdx
    div rcx                   ; RAX = tail/16, RDX = tail % 16
    imul rdx, JOB_SIZE
    lea rbx, [job_queue + rdx]

    mov [rbx], r12            ; FD
    mov [rbx + 8], r13        ; Opcode

    lea rdi, [rbx + 16]
    mov rsi, r14
    mov rcx, 1024             ; 1024 qwords = 8192 bytes
    cld
    rep movsq

    lock inc qword [queue_tail]

    ; Wake the writer (it may be sleeping on queue_tail).
    mov rax, SYS_FUTEX
    lea rdi, [queue_tail]
    mov rsi, FUTEX_WAKE
    mov rdx, 1
    xor r10, r10
    syscall

    mov byte [async_handoff], 1

    DEBUG_LOG "Reader Thread: Job successfully placed in Ring Buffer."

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.queue_full:
    ; Sleep until the writer advances queue_head (frees a slot). RBX holds the
    ; head value we observed; a concurrent advance before we sleep makes
    ; FUTEX_WAIT return EAGAIN immediately.
    mov rax, SYS_FUTEX
    lea rdi, [queue_head]
    mov rsi, FUTEX_WAIT
    mov rdx, rbx              ; expected value = current head
    xor r10, r10
    syscall
    jmp .enqueue_wait
