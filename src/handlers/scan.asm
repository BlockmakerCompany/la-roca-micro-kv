; -----------------------------------------------------------------------------
; Module: src/handlers/scan.asm
; Project: La Roca Micro-KV
; Responsibility: Dynamic Range Scan Handler with Trace Logging.
;                 Navigates the B+ Tree Leaf Linked List for extreme efficiency.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc"

; --- External Dependencies ---
extern btree_search
extern compare_keys
extern get_shard_ptr
extern handle_400, handle_404, close_socket
extern q_prefix, q_startkey, q_limit
extern parse_query_params

section .data
    newline     db 0x0A
    msg_trace   db "[TRACE] Scan evaluating key: ", 0
    len_trace   equ $ - msg_trace

section .text
    global handle_scan

handle_scan:
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; Local stack allocation
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp-8], rdi            ; Save Client Socket FD
    mov r12, rsi                ; Save Request Buffer Pointer

    call .clear_query_buffers

    ; --- 1. URI PARSER ---
    mov rsi, r12
.find_q:
    lodsb
    test al, al
    jz .err_bad_req
    cmp al, '?'
    jne .find_q

    call parse_query_params

    ; --- 2. B+ TREE LEAF JUMP ---
    lea rsi, [q_prefix]
    cmp byte [rsi], 0
    je .err_bad_req

    call get_shard_ptr
    test rdx, rdx
    jz .err_not_found
    mov r12, rdx                ; R12 = Shard Base Pointer

    lea rsi, [q_startkey]
    cmp byte [rsi], 0
    jne .do_jump
    lea rsi, [q_prefix]
.do_jump:
    mov rdi, r12
    call btree_search           ; RAX = Offset del Nodo Hoja (Leaf)
    test rax, rax
    jz .err_not_found
    lea r13, [r12 + rax]        ; R13 = Dirección Física del Nodo Hoja

    ; --- 3. INTRA-LEAF START INDEX ---
    xor r8, r8                  ; R8 = Índice actual
    movzx r9, word [r13 + 1]    ; R9 = Total de llaves en la hoja
.find_start_idx:
    cmp r8, r9
    je .start_harvest           ; Si no, cosechamos en la próxima hoja

    mov rax, r8
    imul rax, 40                ; ENTRY_SIZE
    lea rdi, [r13 + 19 + rax]   ; RDI = LeafKey

    ; RSI ya tiene la Search Key preservada
    call compare_keys

    ; 🛡️ CRITICAL FIX: jbe (Jump if Below or Equal) atrapará CF=1 o ZF=1
    jbe .start_harvest

    inc r8
    jmp .find_start_idx

.start_harvest:
    ; --- 4. SEND HTTP HEADERS ---
    mov rax, 1
    mov rdi, [rbp-8]
    lea rsi, [hdr_scan_ok]
    mov rdx, len_scan_ok
    syscall

    ; --- 5. HARVEST LOOP (B+ Tree Linked List) ---
    xor r14, r14                ; R14 = Results counter
    mov r15d, [q_limit]
    test r15d, r15d
    jnz .leaf_loop
    mov r15d, 50                ; Default limit

.leaf_loop:
    movzx r9, word [r13 + 1]    ; R9 = Total llaves en la hoja actual

.key_loop:
    cmp r8, r9
    jae .next_leaf              ; Si se acabaron las llaves, saltar a la próxima

    mov rax, r8
    imul rax, 40
    lea rbx, [r13 + 19 + rax]   ; RBX = Pointer a la llave actual

    ; --- TELEMETRY (STDOUT) ---
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_trace]
    mov rdx, len_trace
    syscall
    mov rax, 1
    mov rsi, rbx
    mov rdx, 32
    syscall
    mov rax, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall

    ; --- PREFIX VALIDATION ---
    lea rsi, [q_prefix]
    mov rdi, rbx
    call .check_prefix
    test rax, rax
    jz .finish_with_close       ; Prefix mismatch -> Terminar paginación

    ; --- DISPATCH KEY ---
    call .send_trimmed_key
    inc r14

    ; --- LIMIT CHECK ---
    cmp r14, r15
    jae .finish_with_close

    inc r8
    jmp .key_loop

.next_leaf:
    mov rax, [r13 + 11]         ; Leer NODE_OFFSET_NEXT
    test rax, rax
    jz .finish_with_close       ; Si es 0, fin del Shard

    lea r13, [r12 + rax]        ; R13 = Dirección de la nueva hoja
    xor r8, r8                  ; Reiniciar índice
    jmp .leaf_loop

.finish_with_close:
    mov rdi, [rbp-8]
    call close_socket
    jmp .exit

.err_bad_req:
    mov rdi, [rbp-8]
    call handle_400
    jmp .exit

.err_not_found:
    mov rdi, [rbp-8]
    call handle_404
    jmp .exit

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    add rsp, 16
    leave
    ret

; --- Helpers ---
.send_trimmed_key:
    mov rsi, rbx
    xor rdx, rdx
.tl:
    cmp byte [rsi + rdx], 0
    je .tw
    inc rdx
    cmp rdx, 32
    je .tw
    jmp .tl
.tw:
    push rdx
    mov rax, 1
    mov rdi, [rbp-8]
    syscall
    mov rax, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall
    pop rdx
    ret

.check_prefix:
    xor rax, rax
.cp_l:
    mov dl, [rsi]
    test dl, dl
    jz .cp_m
    cmp dl, [rdi]
    jne .cp_f
    inc rsi
    inc rdi
    jmp .cp_l
.cp_m:
    mov rax, 1
.cp_f:
    ret

.clear_query_buffers:
    lea rdi, [q_prefix]
    xor rax, rax
    mov rcx, 16
    rep stosq
    mov dword [q_limit], 0
    ret