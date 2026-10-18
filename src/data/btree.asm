; -----------------------------------------------------------------------------
; Module: src/data/btree.asm
; Project: La Roca Micro-KV
; Responsibility: B+ Tree with Mega-Pages (256KB) and 2-Level Split Logic.
; -----------------------------------------------------------------------------

%define PAGE_SIZE BTREE_PAGE_SIZE    ; 🛡️ 256KB HugePage for extreme cache locality
%define PTR_SIZE 8

; --- NODE LAYOUT (fixed; entry width is dynamic via rt_key_size) ---
%define NODE_OFFSET_TYPE     0
%define NODE_OFFSET_KEYS     1
%define NODE_OFFSET_PARENT   3
%define NODE_OFFSET_NEXT     11
%define HEADER_SIZE          BTREE_HEADER_SIZE

%include "config.inc"

extern rt_slot_size
extern rt_key_size
extern rt_val_max_size
extern rt_offset_len
extern rt_offset_type
extern rt_offset_val
extern rt_entry_size
extern rt_node_max_keys
extern compare_keys

section .text
    global btree_init
    global btree_insert
    global btree_search
    global btree_delete

_bump_alloc:
    mov rax, [rdi + 24]
    mov rdx, rax
    add rdx, rcx
    mov [rdi + 24], rdx
    ret

btree_init:
    cmp qword [rdi + 16], 0
    jne .init_done

    push rbp
    mov rbp, rsp
    mov rcx, PAGE_SIZE
    call _bump_alloc
    mov [rdi + 16], rax

    lea rbx, [rdi + rax]
    mov byte [rbx + NODE_OFFSET_TYPE], 1
    mov word [rbx + NODE_OFFSET_KEYS], 0
    mov qword [rbx + NODE_OFFSET_PARENT], 0
    mov qword [rbx + NODE_OFFSET_NEXT], 0
    leave
.init_done:
    ret

btree_search:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov rax, [rdi + 16]

.traverse_loop:
    lea rbx, [rdi + rax]
    cmp byte [rbx + NODE_OFFSET_TYPE], 1
    je .found_leaf

    xor r12, r12
    movzx rcx, word [rbx + NODE_OFFSET_KEYS]

.scan_keys:
    cmp r12, rcx
    jge .follow_rightmost_ptr

    mov r8, r12
    imul r8, [rt_entry_size]
    lea r9, [rbx + HEADER_SIZE + r8]

    push rdi
    push rsi
    mov rdi, r9
    call compare_keys
    pop rsi
    pop rdi
    jb .found_boundary

    inc r12
    jmp .scan_keys

.found_boundary:
    test r12, r12
    jz .follow_current_ptr  ; Edge case: SearchKey < First Directory Key
    dec r12
.follow_current_ptr:
    mov r8, r12
    imul r8, [rt_entry_size]
    lea r9, [rbx + HEADER_SIZE + r8]
    add r9, [rt_key_size]           ; Pointer sits right after the key
    mov rax, [r9]
    jmp .traverse_loop

.follow_rightmost_ptr:
    mov r8, rcx
    dec r8
    imul r8, [rt_entry_size]
    lea r9, [rbx + HEADER_SIZE + r8]
    add r9, [rt_key_size]
    mov rax, [r9]
    jmp .traverse_loop

.found_leaf:
    pop r12
    pop rbx
    leave
    ret

btree_insert:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rcx

    mov r13, rdi
    mov r14, rsi
    mov r15, rdx

    ; 1. Allocate Data Slot
    mov rcx, [rt_slot_size]
    call _bump_alloc
    mov r12, rax

    ; 2. Format Slot
    lea rdi, [r13 + r12]
    mov rsi, r14
    mov rcx, [rt_key_size]
    cld
    rep movsb

    pop rcx
    mov rdx, [rt_offset_len]
    sub rdx, [rt_key_size]
    mov [rdi + rdx], cx

    mov rdx, [rt_offset_type]
    sub rdx, [rt_key_size]
    mov byte [rdi + rdx], 1

    mov rdx, [rt_offset_val]
    sub rdx, [rt_key_size]
    lea rdi, [rdi + rdx]
    mov rsi, r15
    mov rcx, [rt_val_max_size]
    rep movsb

.retry_find_leaf:
    ; 3. Find target Leaf Node
    mov rdi, r13
    mov rsi, r14
    call btree_search
    mov rbx, rax
    lea r8, [r13 + rbx]

    ; 4. Check Capacity
    movzx rcx, word [r8 + NODE_OFFSET_KEYS]
    cmp rcx, [rt_node_max_keys]
    jae .trigger_split

    ; 5. Find Insertion Point
    xor r9, r9
.find_pos:
    cmp r9, rcx
    je .shift_and_insert
    mov rax, r9
    imul rax, [rt_entry_size]
    lea rdi, [r8 + HEADER_SIZE + rax]
    call compare_keys
    je .overwrite_existing
    jb .shift_and_insert
    inc r9
    jmp .find_pos

.overwrite_existing:
    mov rdx, [rt_key_size]
    mov [rdi + rdx], r12
    mov rax, 1
    jmp .exit_insert

.shift_and_insert:
    mov rax, rcx
    sub rax, r9
    jz .do_insert
    mov r10, [rt_entry_size]    ; r10 = entry width
    mov rdx, rax                ; rdx = (count - index) entries to shift
    imul rdx, r10               ; rdx = bytes to move
    mov rax, rcx
    imul rax, r10               ; rax = tail offset = count * entry_size
    lea rdi, [r8 + HEADER_SIZE + rax]
    add rdi, r10
    sub rdi, 8                  ; dest = tail + entry_size - 8
    lea rsi, [r8 + HEADER_SIZE + rax]
    sub rsi, 8                  ; src  = tail - 8
    mov rcx, rdx
    shr rcx, 3
    std
    rep movsq
    cld

.do_insert:
    mov rax, r9
    imul rax, [rt_entry_size]
    lea rdi, [r8 + HEADER_SIZE + rax]
    mov rsi, r14
    mov rcx, [rt_key_size]
    rep movsb
    mov [rdi], r12

    movzx rcx, word [r8 + NODE_OFFSET_KEYS]
    inc rcx
    mov word [r8 + NODE_OFFSET_KEYS], cx

    inc qword [r13]
    mov rax, 1
    jmp .exit_insert

.trigger_split:
    ; -------------------------------------------------------------
    ; B+ TREE 2-LEVEL SPLIT (Mega-Page Mode, dynamic entry width)
    ; -------------------------------------------------------------
    ; Allocate Sibling
    mov rcx, PAGE_SIZE
    call _bump_alloc
    mov r10, rax                 ; r10 = sibling page offset
    lea r11, [r13 + r10]         ; r11 = sibling page address

    mov byte [r11 + NODE_OFFSET_TYPE], 1
    mov qword [r11 + NODE_OFFSET_PARENT], 0

    ; Split counts: old keeps ceil(N/2), new gets floor(N/2)
    mov rax, [rt_node_max_keys]
    mov rdx, rax
    shr rdx, 1                   ; rdx = new_count = N/2
    sub rax, rdx                 ; rax = old_count = N - N/2
    mov word [r8 + NODE_OFFSET_KEYS], ax
    mov word [r11 + NODE_OFFSET_KEYS], dx

    ; Copy second half of entries to the sibling leaf
    mov r15, rax                 ; r15 = old_count (value ptr no longer needed)
    imul r15, [rt_entry_size]    ; r15 = byte offset of the split point
    lea rsi, [r8 + HEADER_SIZE + r15]
    lea rdi, [r11 + HEADER_SIZE]
    mov rcx, rdx                 ; rcx = new_count
    imul rcx, [rt_entry_size]    ; rcx = bytes to copy
    cld
    rep movsb

    ; Linked List NEXT Pointer Swap
    mov rax, [r8 + NODE_OFFSET_NEXT]
    mov [r11 + NODE_OFFSET_NEXT], rax
    mov [r8 + NODE_OFFSET_NEXT], r10

    ; Create Directory Root
    mov rcx, PAGE_SIZE
    call _bump_alloc
    mov r9, rax
    lea rdi, [r13 + r9]

    mov byte [rdi + NODE_OFFSET_TYPE], 0    ; Internal Node (Type 0)
    mov word [rdi + NODE_OFFSET_KEYS], 2    ; Contains 2 routing pointers
    mov qword [rdi + NODE_OFFSET_PARENT], 0
    mov [r13 + 16], r9                      ; Save new Root in Shard Header

    mov [r8 + NODE_OFFSET_PARENT], r9
    mov [r11 + NODE_OFFSET_PARENT], r9

    ; Link Old Leaf (routing key + old leaf offset)
    lea rsi, [r8 + HEADER_SIZE]
    lea rdi, [r13 + r9 + HEADER_SIZE]
    mov rcx, [rt_key_size]
    rep movsb
    mov [rdi], rbx               ; rbx = old leaf offset (still intact)

    ; Link New Leaf (routing key + new leaf offset)
    lea rsi, [r11 + HEADER_SIZE]
    lea rdi, [r13 + r9 + HEADER_SIZE]
    add rdi, [rt_entry_size]
    mov rcx, [rt_key_size]
    rep movsb
    mov [rdi], r10

    ; RESTART INSERT WITH NEW TREE STRUCTURE
    jmp .retry_find_leaf

.exit_insert:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

btree_delete:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13

    mov r12, rdi
    call btree_search
    test rax, rax
    jz .not_found

    lea rbx, [r12 + rax]
    movzx rcx, word [rbx + NODE_OFFSET_KEYS]
    test rcx, rcx
    jz .not_found

    xor r9, r9
.find_key:
    cmp r9, rcx
    je .not_found

    mov rax, r9
    imul rax, [rt_entry_size]
    lea rdi, [rbx + HEADER_SIZE + rax]

    push rsi
    push rdi
    call compare_keys
    pop rdi
    pop rsi
    je .perform_delete

    inc r9
    jmp .find_key

.perform_delete:
    mov rax, rcx
    sub rax, r9
    dec rax
    jz .update_counts

    mov r13, [rt_entry_size]   ; r13 = entry width
    imul rax, r13              ; rax = bytes to move
    mov r10, rax
    mov rax, r9
    imul rax, r13              ; rax = index * entry_size
    lea rdi, [rbx + HEADER_SIZE + rax]
    lea rsi, [rdi + r13]       ; src = entry[index+1]

    mov rcx, r10
    cld
    rep movsb

.update_counts:
    movzx rcx, word [rbx + NODE_OFFSET_KEYS]
    dec rcx
    mov word [rbx + NODE_OFFSET_KEYS], cx

    mov rax, [r12]
    test rax, rax
    jz .exit_success
    dec rax
    mov [r12], rax

.exit_success:
    mov rax, 1
    jmp .exit_del

.not_found:
    xor rax, rax

.exit_del:
    pop r13
    pop r12
    pop rbx
    leave
    ret