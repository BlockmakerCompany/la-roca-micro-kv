; -----------------------------------------------------------------------------
; Module: src/data/btree.asm
; Project: La Roca Micro-KV
; Responsibility: Data Mutations using Dynamic Configuration.
; -----------------------------------------------------------------------------
%include "config.inc"

extern compare_keys
extern rt_key_size, rt_slot_size, rt_slots_per_shard, rt_val_max_size
extern rt_offset_len, rt_offset_type, rt_offset_val

section .text
    global btree_insert
    global btree_delete

; -----------------------------------------------------------------------------
; btree_insert: Dynamic version. Supports variable SLOT_SIZE & KEY_SIZE.
; -----------------------------------------------------------------------------
btree_insert:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rcx

    mov r8, rdi
    mov r13, qword [r8]
    mov r14, rsi
    mov r15, rdx

    ; 1. Dynamic Capacity Guard
    cmp r13, [rt_slots_per_shard]
    jae .full_err

    ; 2. Linear Search
    xor r9, r9
.find_pos:
    cmp r9, r13
    je .do_ins

    mov rax, r9
    mul qword [rt_slot_size]
    mov rbx, rax
    lea r12, [r8 + 256 + rbx]

    lea rdi, [r12]
    mov rsi, r14
    call compare_keys
    je .overwrite
    jb .shift_needed

    inc r9
    jmp .find_pos

.overwrite:
    pop rcx
    mov rdx, [rt_offset_len]
    mov [r12 + rdx], cx

    mov rdx, [rt_offset_val]
    lea rdi, [r12 + rdx]
    mov rsi, r15
    mov rcx, [rt_val_max_size]
    cld
    rep movsb
    mov rax, 1
    jmp .exit_ins

.shift_needed:
    mov rbx, r13
.shift_loop:
    cmp rbx, r9
    jle .do_ins

    mov rax, rbx
    mul qword [rt_slot_size]
    lea rdi, [r8 + 256 + rax]

    sub rax, [rt_slot_size]
    lea rsi, [r8 + 256 + rax]

    mov rcx, [rt_slot_size]
    shr rcx, 3
    cld
    rep movsq
    dec rbx
    jmp .shift_loop

.do_ins:
    mov rax, r9
    mul qword [rt_slot_size]
    lea rdi, [r8 + 256 + rax]

.write_data:
    ; A. Key (Now 100% Dynamic)
    mov rsi, r14
    mov rcx, [rt_key_size]      ; <--- Adiós al 32 fijo
    cld
    rep movsb

    ; B. Length
    pop rcx
    mov rdx, [rt_offset_len]
    sub rdx, [rt_key_size]      ; <--- Ajuste dinámico
    mov [rdi + rdx], cx

    ; C. Status
    mov rdx, [rt_offset_type]
    sub rdx, [rt_key_size]
    mov byte [rdi + rdx], 1

    ; D. Value
    mov rdx, [rt_offset_val]
    sub rdx, [rt_key_size]
    lea rdi, [rdi + rdx]
    mov rsi, r15
    mov rcx, [rt_val_max_size]
    rep movsb

    inc qword [r8]
    mov rax, 1
    jmp .exit_ins

.full_err:
    pop rcx
    xor rax, rax
.exit_ins:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

; -----------------------------------------------------------------------------
; btree_delete: Dynamic gap collapse.
; -----------------------------------------------------------------------------
btree_delete:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r8, rdi
    mov r13, qword [r8]
    test r13, r13
    jz .not_f

    mov r14, rsi
    xor r9, r9
.search_del:
    cmp r9, r13
    je .not_f

    mov rax, r9
    mul qword [rt_slot_size]
    lea r12, [r8 + 256 + rax]

    lea rdi, [r12]
    mov rsi, r14
    call compare_keys
    je .perform_del
    jb .not_f

    inc r9
    jmp .search_del

.perform_del:
    mov rbx, r9
    mov r15, r13
    dec r15
.del_shift:
    cmp rbx, r15
    jge .del_done

    mov rax, rbx
    mul qword [rt_slot_size]
    lea rdi, [r8 + 256 + rax]
    add rax, [rt_slot_size]
    lea rsi, [r8 + 256 + rax]

    mov rcx, [rt_slot_size]
    shr rcx, 3
    cld
    rep movsq
    inc rbx
    jmp .del_shift

.del_done:
    dec qword [r8]
    mov rax, 1
    jmp .exit_del
.not_f:
    xor rax, rax
.exit_del:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret