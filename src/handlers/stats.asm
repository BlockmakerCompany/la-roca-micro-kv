; -----------------------------------------------------------------------------
; Module: src/handlers/stats.asm
; Project: La Roca Micro-KV
; Responsibility: Global Metadata Aggregation & Telemetry JSON Streaming.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc"

; --- External Symbols ---
extern db_ptrs              ; Array of 27 pointers to mmap'd regions
extern rt_port, rt_slot_size, rt_slots_per_shard, rt_key_size
extern close_socket         ; From base.asm

section .data
    ; JSON Fragments (Specific to this module)
    j_part1     db '{"engine":"La Roca Micro-KV","status":"online","port":'
    len_p1      equ $ - j_part1
    j_part2     db ',"slot_size_bytes":'
    len_p2      equ $ - j_part2
    j_part3     db ',"shard_capacity":'
    len_p3      equ $ - j_part3
    j_part4     db ',"total_shards":27,"key_size_bytes":'
    len_p4      equ $ - j_part4
    j_part5     db ',"total_keys":'
    len_p5      equ $ - j_part5
    j_end       db '}', 0x0A
    len_end     equ $ - j_end

section .bss
    num_buf     resb 32

section .text
    global handle_stats

handle_stats:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r15, rdx                ; r15 = Client Socket FD

    ; 1. AGGREGATION: Sum all atomic counters from the 27 shards
    xor r12, r12                ; Index
    xor r13, r13                ; Global Accumulator
    lea r14, [db_ptrs]
.sum_loop:
    cmp r12, 27
    je .done_sum
    mov r8, [r14 + r12*8]
    test r8, r8
    jz .next_shard
    add r13, qword [r8]         ; The counter is the first QWORD of each shard
.next_shard:
    inc r12
    jmp .sum_loop

.done_sum:
    ; 2. STREAMING: Dispatch JSON fragments

    ; A. HTTP JSON Headers (Now from responses.inc)
    mov rax, 1
    mov rdi, r15
    lea rsi, [hdr_200_json]
    mov rdx, len_200_json
    syscall

    ; B. JSON Structure logic
    mov rax, 1
    lea rsi, [j_part1]
    mov rdx, len_p1
    syscall

    mov rax, [rt_port]
    call .send_number

    mov rax, 1
    lea rsi, [j_part2]
    mov rdx, len_p2
    syscall

    mov rax, [rt_slot_size]
    call .send_number

    mov rax, 1
    lea rsi, [j_part3]
    mov rdx, len_p3
    syscall

    mov rax, [rt_slots_per_shard]
    call .send_number

    mov rax, 1
    lea rsi, [j_part4]
    mov rdx, len_p4
    syscall

    mov rax, [rt_key_size]
    call .send_number

    mov rax, 1
    lea rsi, [j_part5]
    mov rdx, len_p5
    syscall

    mov rax, r13                ; Aggregated total
    call .send_number

    mov rax, 1
    lea rsi, [j_end]
    mov rdx, len_end
    syscall

    ; 3. TEARDOWN: Mandatory Hygiene
    mov rdi, r15
    call close_socket           ; Uniform closure

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

; Helper for numeric streaming
.send_number:
    lea rdi, [num_buf + 31]
    mov byte [rdi], 0
    mov rbx, 10
    test rax, rax
    jnz .itoa_loop
    dec rdi
    mov byte [rdi], '0'
    jmp .write_sys
.itoa_loop:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .itoa_loop
.write_sys:
    mov rsi, rdi
    lea r8, [num_buf + 31]
    sub r8, rdi
    mov rdx, r8
    mov rax, 1
    mov rdi, r15                ; Client FD
    syscall
    ret