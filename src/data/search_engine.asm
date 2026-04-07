; -----------------------------------------------------------------------------
; Module: src/data/search_engine.asm
; Project: La Roca Micro-KV
; Responsibility: Dynamic Read-Only Logic. 
;                 Implements B+ Tree Search ($O(\log N)$) for exact matches.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- External dynamic configuration ---
extern rt_slot_size
extern rt_key_size

; --- External B+ Tree functions (from btree.asm) ---
extern btree_search

; --- Constants for B+ Tree Leaf Navigation ---
%define NODE_OFFSET_KEYS     1
%define HEADER_SIZE          19
%define MAX_KEY_SIZE         32
%define ENTRY_SIZE           40

section .text
    global btree_find
    global compare_keys

; -----------------------------------------------------------------------------
; btree_find: Exact match lookup using B+ Tree index.
; Input:  RDI = Shard Base Address
;         RSI = Search Key Pointer
; Output: RAX = Pointer to Data Value Slot (or 0 if not found)
; -----------------------------------------------------------------------------
btree_find:
    push rbp
    mov rbp, rsp
    push rbx
    push r12

    mov r12, rdi            ; Save Shard Base Pointer

    ; 1. Find the target Leaf Node (calls btree_search in btree.asm)
    call btree_search       ; RAX = Offset of the Leaf Node
    lea rbx, [r12 + rax]    ; RBX = Physical address of the Leaf

    ; 2. Linear search within the Leaf Node
    movzx rcx, word [rbx + NODE_OFFSET_KEYS]
    xor r9, r9
.find_key:
    cmp r9, rcx
    je .not_found

    ; Calculate pointer to current key in the leaf
    mov rax, r9
    imul rax, ENTRY_SIZE
    lea rdi, [rbx + HEADER_SIZE + rax]

    ; Compare Keys (compare_keys safely preserves RDI/RSI)
    call compare_keys
    je .found_it            ; Exact key match found!

    inc r9
    jmp .find_key

.found_it:
    ; Extract the 8-byte pointer attached to the key
    mov rax, [rdi + MAX_KEY_SIZE]
    add rax, r12            ; Add Shard Base (Final physical memory address)
    jmp .exit_get

.not_found:
    xor rax, rax            ; Return 0 (Not Found)
.exit_get:
    pop r12
    pop rbx
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