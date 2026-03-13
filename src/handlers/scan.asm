; -----------------------------------------------------------------------------
; Module: src/handlers/scan.asm
; Project: La Roca Micro-KV
; Responsibility: Dynamic Range Scan Handler with Trace Logging.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc"

; --- External Dependencies ---
extern btree_find_lower_bound
extern get_shard_ptr
extern handle_400, handle_404, close_socket
extern q_prefix, q_startkey, q_limit
extern rt_slot_size, rt_offset_type
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

    ; --- 2. BINARY JUMP ---
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
    call btree_find_lower_bound
    mov r13, rax                ; R13 = Starting Index (i)

    ; --- 3. SEND HTTP HEADERS ---
    mov rax, 1
    mov rdi, [rbp-8]
    lea rsi, [hdr_scan_ok]      ; From responses.inc
    mov rdx, len_scan_ok
    syscall

    ; --- 4. HARVEST LOOP ---
    xor r14, r14                ; R14 = Results counter
    mov r15d, [q_limit]
    test r15d, r15d
    jnz .loop
    mov r15d, 50                ; Default limit

.loop:
    cmp r14, r15
    jae .finish_with_close
    mov rax, [r12]              ; Total keys in shard
    cmp r13, rax
    jae .finish_with_close

    ; DYNAMIC OFFSET CALCULATION
    mov rax, r13
    xor rdx, rdx
    mul qword [rt_slot_size]
    lea rbx, [r12 + 256 + rax]  ; RBX = Pointer to current slot

    ; --- TELEMETRY (STDOUT) ---
    push rax
    push rdi
    mov rax, 1
    mov rdi, 1                  ; Docker Logs
    lea rsi, [msg_trace]
    mov rdx, len_trace
    syscall
    mov rax, 1
    mov rsi, rbx                ; Key
    mov rdx, 32
    syscall
    mov rax, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall
    pop rdi
    pop rax

    ; --- PREFIX VALIDATION ---
    lea rsi, [q_prefix]
    mov rdi, rbx
    call .check_prefix
    test rax, rax
    jz .finish_with_close       ; Prefix mismatch -> Ordered break

    ; --- STATUS CHECK ---
    mov rdx, [rt_offset_type]
    cmp byte [rbx + rdx], 1     ; Active record?
    jne .next

    ; --- DISPATCH KEY ---
    call .send_trimmed_key
    inc r14

.next:
    inc r13
    jmp .loop

.finish_with_close:
    mov rdi, [rbp-8]
    call close_socket           ; Final hygiene closure
    jmp .exit

.err_bad_req:
    mov rdi, [rbp-8]
    call handle_400             ; handle_400 already closes socket
    jmp .exit

.err_not_found:
    mov rdi, [rbp-8]
    call handle_404             ; handle_404 already closes socket
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
    mov rcx, 16                 ; 128 bytes
    rep stosq
    mov dword [q_limit], 0
    ret