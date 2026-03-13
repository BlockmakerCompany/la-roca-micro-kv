; -----------------------------------------------------------------------------
; Module: src/data/search_engine.asm
; Project: La Roca Micro-KV
; Responsibility: Dynamic Read-Only Logic. 
;                 Implements Binary Search ($O(\log N)$) using runtime geometry.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- External dynamic configuration ---
extern rt_slot_size
extern rt_key_size

section .text
    global btree_find
    global btree_find_lower_bound
    global compare_keys

; -----------------------------------------------------------------------------
; btree_find_lower_bound: Finds the first index where ShardKey >= SearchKey.
; -----------------------------------------------------------------------------
btree_find_lower_bound:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r8, rdi                 ; R8  = Shard Base Address
    mov r11, qword [r8]         ; R11 = Current Key Count
    mov r13, rsi                ; R13 = Search Key Pointer

    xor r10, r10                ; R10 = Low (0)
    mov r14, r11                ; R14 = Candidate (End)
    dec r11                     ; R11 = High (Count - 1)

    test r14, r14
    jz .lb_done

.lb_loop:
    cmp r10, r11
    jg .lb_done

    ; Calculate Midpoint
    mov rax, r10
    add rax, r11
    shr rax, 1
    mov r9, rax                 ; R9 = Mid Index

    ; --- DYNAMIC OFFSET CALCULATION ---
    ; Calculate address: ShardBase + 256 + (Index * rt_slot_size)
    mov rax, r9
    mul qword [rt_slot_size]    ; RAX = Index * SLOT_SIZE
    mov rbx, rax
    lea r12, [r8 + 256 + rbx]   ; R12 = Pointer to Mid Slot

    lea rdi, [r12]
    mov rsi, r13
    call compare_keys

    ; Binary Search Decision
    ja .go_right                ; SearchKey > ShardKey

    mov r14, r9                 ; Candidate found
    test r9, r9
    jz .lb_done
    mov r11, r9
    dec r11
    jmp .lb_loop

.go_right:
    mov r10, r9
    inc r10
    jmp .lb_loop

.lb_done:
    mov rax, r14
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

; -----------------------------------------------------------------------------
; btree_find: Exact match lookup.
; -----------------------------------------------------------------------------
btree_find:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi

    call btree_find_lower_bound
    mov r9, rax

    pop rdi                     ; RDI = Shard Base
    pop rsi                     ; RSI = Search Key

    cmp r9, [rdi]
    jae .not_found

    ; --- DYNAMIC OFFSET CALCULATION ---
    mov rax, r9
    mul qword [rt_slot_size]
    lea r12, [rdi + 256 + rax]

    push rdi
    lea rdi, [r12]
    call compare_keys
    pop rdi
    jne .not_found

    mov rax, r12
    jmp .exit

.not_found:
    xor rax, rax
.exit:
    leave
    ret

; -----------------------------------------------------------------------------
; compare_keys: Dynamic string comparator.
; -----------------------------------------------------------------------------
compare_keys:
    push rcx
    push rsi
    push rdi
    mov rcx, [rt_key_size]      ; Use dynamic key size (usually 32)
    cld
    repe cmpsb
    pop rdi
    pop rsi
    pop rcx
    ret