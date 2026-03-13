; -----------------------------------------------------------------------------
; Module: src/core/env_parser.asm
; Project: La Roca Micro-KV
; Responsibility: Linux Environment Block (envp) Scanner.
;                 Locates ROCK_* variables and updates runtime configuration.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- External Dynamic Config Pointers ---
extern rt_port
extern rt_key_size
extern rt_slot_size
extern rt_slots_per_shard
extern rt_shard_size
extern recalc_offsets           ; Imported from config_runtime.asm

section .data
    ; Keys to search for in the environment
    key_port        db "ROCK_PORT=", 0
    key_keysize     db "ROCK_KEY_SIZE=", 0
    key_slot        db "ROCK_SLOT_SIZE=", 0
    key_slots_shard db "ROCK_SLOTS_PER_SHARD=", 0

section .text
    global parse_env_vars

; -----------------------------------------------------------------------------
; parse_env_vars: Iterates through envp strings (KEY=VALUE)
; Input:
;   RDX = Pointer to envp array (from main.asm/_start)
; -----------------------------------------------------------------------------
parse_env_vars:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13

    mov r12, rdx                ; R12 = Current envp pointer
    test r12, r12
    jz .done

.loop:
    mov rsi, [r12]              ; RSI = Pointer to current "KEY=VALUE" string
    test rsi, rsi               ; Check for NULL (end of envp)
    jz .done

    ; --- 1. Check for ROCK_PORT ---
    lea rdi, [key_port]
    call .compare_key
    test rax, rax
    jz .check_keysize
    call .atoi_64
    mov [rt_port], rax
    jmp .next

.check_keysize:
    ; --- 2. Check for ROCK_KEY_SIZE ---
    lea rdi, [key_keysize]
    call .compare_key
    test rax, rax
    jz .check_slot
    call .atoi_64
    mov [rt_key_size], rax
    call recalc_offsets         ; CRITICAL: Update internal memory map
    jmp .next

.check_slot:
    ; --- 3. Check for ROCK_SLOT_SIZE ---
    lea rdi, [key_slot]
    call .compare_key
    test rax, rax
    jz .check_slots_shard
    call .atoi_64
    mov [rt_slot_size], rax
    call recalc_offsets         ; CRITICAL: Ensure slot isn't smaller than key requires!
    call .recalc_shard_size     ; Update total shard size
    jmp .next

.check_slots_shard:
    ; --- 4. Check for ROCK_SLOTS_PER_SHARD ---
    lea rdi, [key_slots_shard]
    call .compare_key
    test rax, rax
    jz .next
    call .atoi_64
    mov [rt_slots_per_shard], rax
    call .recalc_shard_size

.next:
    add r12, 8                  ; Move to next pointer in envp array
    jmp .loop

.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret

; --- Helper: Recalculate shard boundary ---
.recalc_shard_size:
    mov rax, [rt_slot_size]
    mov rbx, [rt_slots_per_shard]
    mul rbx                     ; rax = slot_size * slots_per_shard
    mov [rt_shard_size], rax
    ret

; --- Helper: Compare environment key ---
; Input: RDI = Target Key, RSI = Env String
; Output: RAX = 1 (Match, RSI points to value), 0 (No match)
.compare_key:
    push rsi
    push rdi
.c_loop:
    mov al, [rdi]
    test al, al
    jz .match
    cmp al, [rsi]
    jne .no_match
    inc rdi
    inc rsi
    jmp .c_loop
.match:
    pop rdi
    add rsp, 8                  ; Discard saved RSI, use updated RSI
    mov rax, 1
    ret
.no_match:
    pop rdi
    pop rsi
    xor rax, rax
    ret

; --- Helper: 64-bit ASCII to Integer ---
.atoi_64:
    xor rax, rax
    xor rcx, rcx
.a_loop:
    mov cl, [rsi]
    cmp cl, '0'
    jb .a_done
    cmp cl, '9'
    ja .a_done
    sub cl, '0'
    imul rax, 10
    add rax, rcx
    inc rsi
    jmp .a_loop
.a_done:
    ret