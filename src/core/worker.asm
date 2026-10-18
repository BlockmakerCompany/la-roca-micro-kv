; -----------------------------------------------------------------------------
; Module: src/core/worker.asm
; Project: La Roca Micro-KV
; Responsibility: The Writer Thread (Consumer) and Ring Buffer logic.
;                 Manages async handoff with Reader Threads using a
;                 futex-based multi-producer / single-consumer pair.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- Telemetry Macro (no-op) ---
%macro DEBUG_LOG 1
%endmacro

extern handle_set
extern handle_del
extern flush_all_shards     ; 🛡️ GROUP COMMIT: batch msync of all shards

; --- Futex / Queue constants ---
%define SYS_FUTEX       202
%define FUTEX_WAIT      0
%define FUTEX_WAKE      1
%define QUEUE_CAPACITY  64
%define QUEUE_MASK      63
%define JOB_SIZE        8208
%define FLUSH_EVERY     32        ; group-commit: msync shards every N writes

section .data
    ; struct timespec { tv_sec; tv_nsec } — RELATIVE timeout for FUTEX_WAIT.
    ; Bounds the producer's wait on a full queue (so a dead writer can't hang the
    ; readers forever) and gives the writer a periodic idle wakeup.
    wait_timeout dq 1, 0          ; 1 second

section .bss
    global queue_head
    global queue_tail
    global job_queue

    queue_head    resq 1
    queue_tail    resq 1
    producer_lock resd 1
    dirty_count   resq 1          ; writes since last group commit

    ; Array of 64 Jobs. Each job is 8208 bytes (64 * 8208 = 525312 bytes)
    job_queue     resb 525312

section .text
    global writer_entry_point
    global enqueue_job

; =============================================================================
; PRODUCER SPINLOCK HELPERS
; =============================================================================
acquire_producer_lock:
.try_acquire:
    mov eax, 1
    xchg eax, [producer_lock]
    test eax, eax
    jz .acquired
.spin:
    pause
    cmp dword [producer_lock], 0
    jne .spin
    jmp .try_acquire
.acquired:
    ret

release_producer_lock:
    mov dword [producer_lock], 0
    ret

; =============================================================================
; THE CONSUMER: WRITER THREAD MAIN LOOP
; =============================================================================
writer_entry_point:
.writer_poll:
    mov rax, [queue_head]
    mov rbx, [queue_tail]
    cmp rax, rbx
    je .writer_wait           ; Empty queue: sleep on queue_tail

    mov rdx, rax
    and rdx, QUEUE_MASK
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
    call handle_set
    jmp .job_done

.do_del:
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

    ; 🛡️ GROUP COMMIT: batch-flush the shard mmaps every FLUSH_EVERY writes.
    inc qword [dirty_count]
    cmp qword [dirty_count], FLUSH_EVERY
    jb .skip_flush
    call flush_all_shards
    mov qword [dirty_count], 0
.skip_flush:

    jmp .writer_poll

.writer_wait:
    ; Sleep until a producer wakes us on queue_tail. RBX still holds the tail
    ; value we observed; if a producer advances tail before we sleep, FUTEX_WAIT
    ; returns EAGAIN immediately (no lost wakeup). The timeout bounds the wait
    ; and gives a periodic idle wakeup (we re-check the queue either way).
    mov rax, SYS_FUTEX
    lea rdi, [queue_tail]
    mov rsi, FUTEX_WAIT
    mov rdx, rbx              ; expected value = current tail
    lea r10, [wait_timeout]   ; bounded wait (1s)
    syscall
    jmp .writer_poll

; =============================================================================
; THE PRODUCER: ENQUEUE FUNCTION (Called concurrently by Reader Threads)
; =============================================================================
enqueue_job:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r12, rdi              ; FD
    mov r13, rsi              ; Opcode
    mov r14, rdx              ; Buffer

.enqueue_retry:
    call acquire_producer_lock

    mov rax, [queue_tail]
    mov rbx, [queue_head]
    mov rcx, rax
    sub rcx, rbx
    cmp rcx, QUEUE_CAPACITY
    jb .slot_ready

    ; Queue is full: release lock before sleeping to avoid blocking other producers
    call release_producer_lock

    ; Sleep until the writer advances queue_head (frees a slot).
    ; RBX holds observed queue_head; if writer advanced it, FUTEX_WAIT returns -EAGAIN.
    mov rax, SYS_FUTEX
    lea rdi, [queue_head]
    mov rsi, FUTEX_WAIT
    mov rdx, rbx              ; expected value = current head
    lea r10, [wait_timeout]   ; bounded wait (1s): never hang on a dead writer
    syscall
    ; 0 = woken, -EAGAIN (-11) = head advanced, -ETIMEDOUT (-110) = timeout.
    cmp rax, 0
    je .enqueue_retry
    cmp rax, -11
    je .enqueue_retry
    jmp .give_up               ; timeout/error: writer likely dead, drop the job

.give_up:
    ; Do NOT set TLS_ASYNC_HANDOFF: the reader sees 0 and closes the socket
    ; itself instead of waiting on a writer that is no longer draining.
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.slot_ready:
    ; RAX = current queue_tail
    mov rdx, rax
    and rdx, QUEUE_MASK
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

    ; Release producer lock now that slot is populated and tail is updated
    call release_producer_lock

    ; Wake the writer (it may be sleeping on queue_tail).
    mov rax, SYS_FUTEX
    lea rdi, [queue_tail]
    mov rsi, FUTEX_WAKE
    mov rdx, 1
    xor r10, r10
    syscall

    mov byte [fs:TLS_ASYNC_HANDOFF], 1

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
