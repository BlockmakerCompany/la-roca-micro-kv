; -----------------------------------------------------------------------------
; Module: src/handlers/set.asm
; Project: La Roca Micro-KV
; Responsibility: Hardened, binary-safe POST/SET handling.
;                 Implements strict Content-Length validation, 411/413 error
;                 handling, and mandatory socket closure for security.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc"

; --- Telemetry Macro ---
%macro DEBUG_LOG 1
    section .data
        %%msg db "[DEBUG:SET] ", %1, 0x0A
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

extern handle_400, handle_507
extern btree_insert, append_wal
extern flush_shard
extern validated_key
extern rt_val_max_size

section .bss
    tmp_val    resb 2048
    tmp_v_len  resw 1

section .text
    global handle_set

handle_set:
    DEBUG_LOG "Initializing SET handler..."
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                ; Shard
    mov r13, rdx                ; Socket FD
    mov r14, rsi                ; Request Buffer

    ; 1. Buffer Sanitization
    lea rdi, [tmp_val]
    xor al, al
    mov rcx, 2048
    cld
    rep stosb

    ; 2. Content-Length Header Parsing
    mov rsi, r14
    xor r15, r15
.find_cl:
    mov eax, [rsi]
    and eax, 0xFFFFFF
    cmp eax, 0x6e6f43           ; "Con"
    je .cl_found
    lodsb
    test al, al
    jz .err_411
    mov rbx, rsi
    sub rbx, r14
    cmp rbx, 1024
    ja .err_411
    jmp .find_cl

.cl_found:
    DEBUG_LOG "Content-Length header located."
.skip_to_num:
    lodsb
    cmp al, '0'
    jb .skip_to_num
    cmp al, '9'
    ja .skip_to_num
    dec rsi

.conv_l:
    lodsb
    cmp al, '0'
    jb .check_limit
    cmp al, '9'
    ja .check_limit
    sub al, '0'

    ; --- 🛡️ ARITHMETIC SAFETY GUARD (S5 Resilience) ---
    mov rbx, r15
    imul r15, 10
    jo .err_msg_too_large       ; Overflow flag: number too big for 64-bit

    movzx rdx, al
    add r15, rdx
    jc .err_msg_too_large       ; Carry flag: number wrapped around

    ; Early capacity check (against dynamic KVS limit)
    mov edx, dword [rt_val_max_size]
    cmp r15, rdx
    ja .err_msg_too_large       ; Above KVS slot limit -> 413
    ; ---------------------------------------------------

    jmp .conv_l

.check_limit:
    DEBUG_LOG "Payload size validated."
    test r15, r15
    jz .err_bad                 ; Content-Length: 0 is still 400

    ; 3. Body Boundary Detection
    mov rsi, r14
.h_search:
    lodsb
    test al, al
    jz .err_bad
    cmp al, 0x0D
    jne .h_search
    mov eax, [rsi-1]
    cmp eax, 0x0A0D0A0D
    jne .h_search
    add rsi, 3
    DEBUG_LOG "Body boundary located."

    ; 4. Binary-Safe Data Transfer
    lea rdi, [tmp_val]
    mov rcx, r15
    mov [tmp_v_len], cx
    rep movsb

.do_ins:
    DEBUG_LOG "Persisting to WAL and B-Tree..."
    mov rdi, 1
    lea rsi, [validated_key]
    lea rdx, [tmp_val]
    movzx rcx, word [tmp_v_len]
    call append_wal

    mov rdi, r12
    lea rsi, [validated_key]
    lea rdx, [tmp_val]
    movzx rcx, word [tmp_v_len]
    call btree_insert
    test rax, rax
    jz .err_full

    call flush_shard
    DEBUG_LOG "Transaction committed. Sending 200 OK..."

    mov rax, 1
    mov rdi, r13
    lea rsi, [hdr_200_stored]
    mov rdx, len_200_stored
    syscall
    jmp .finish_with_close

; --- Error Handlers ---

.err_411:
    DEBUG_LOG "Error 411: Missing Content-Length."
    mov rax, 1
    mov rdi, r13
    lea rsi, [msg_411]
    mov rdx, len_411
    syscall
    jmp .finish_with_close

.err_msg_too_large:
    DEBUG_LOG "Error 413: Content-Length out of bounds."
    mov rax, 1
    mov rdi, r13
    lea rsi, [msg_413]
    mov rdx, len_413
    syscall
    jmp .finish_with_close

.err_bad:
    DEBUG_LOG "Error 400: Bad Request."
    mov rdi, r13
    call handle_400
    jmp .finish_with_close

.err_full:
    DEBUG_LOG "Error 507: Shard capacity reached."
    mov rdi, r13
    call handle_507
    jmp .finish_with_close

.finish_with_close:
    DEBUG_LOG "Closing client socket."
    mov rax, 3
    mov rdi, r13
    syscall

.finish:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret