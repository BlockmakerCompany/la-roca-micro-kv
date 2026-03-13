; -----------------------------------------------------------------------------
; Module: src/core/http_parser.asm
; Project: La Roca Micro-KV
; Responsibility: Pure Logic for HTTP Query String Parsing.
;                 Extracts 'prefix', 'startkey', and 'limit' into global buffers.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- Global Query Buffers (Defined in router.asm) ---
extern q_prefix, q_startkey, q_limit

section .data
    p_prefix    db "prefix=", 0
    p_limit     db "limit=", 0
    p_start     db "startkey=", 0

section .text
    global parse_query_params

; -----------------------------------------------------------------------------
; parse_query_params: Scans a buffer for KEY=VALUE pairs separated by '&'.
; Input:
;   RSI = Pointer to the start of the query string (just after the '?')
; -----------------------------------------------------------------------------
parse_query_params:
    push rbp
    mov rbp, rsp
    push rbx
    push r12

    mov rdi, rsi                ; RDI = Working pointer for the parser

.p_loop:
    mov al, [rdi]
    cmp al, ' '                 ; HTTP URI ends with a space
    je .p_done
    test al, al                 ; Or a null terminator
    jz .p_done

    ; --- 1. Check for 'prefix=' ---
    push rdi
    lea rsi, [p_prefix]
    call .match_key
    pop rdi
    test rax, rax
    jz .is_lim
    add rdi, 7                  ; Skip "prefix="
    lea rsi, [q_prefix]
    call .copy_val
    jmp .next_param

.is_lim:
    ; --- 2. Check for 'limit=' ---
    push rdi
    lea rsi, [p_limit]
    call .match_key
    pop rdi
    test rax, rax
    jz .is_st
    add rdi, 6                  ; Skip "limit="
    call .atoi_l
    jmp .next_param

.is_st:
    ; --- 3. Check for 'startkey=' ---
    push rdi
    lea rsi, [p_start]
    call .match_key
    pop rdi
    test rax, rax
    jz .next_param
    add rdi, 9                  ; Skip "startkey="
    lea rsi, [q_startkey]
    call .copy_val

.next_param:
    ; Skip until we find '&' or ' '
.sk_l:
    mov al, [rdi]
    cmp al, '&'
    je .found_amp
    cmp al, ' '
    je .p_done
    test al, al
    jz .p_done
    inc rdi
    jmp .sk_l
.found_amp:
    inc rdi                     ; Move past '&'
    jmp .p_loop

.p_done:
    pop r12
    pop rbx
    leave
    ret

; --- Private Helper: String match ---
.match_key:
    push rsi
    push rdi
.mk_l:
    mov al, [rsi]
    test al, al
    jz .mk_ok
    cmp al, [rdi]
    jne .mk_fail
    inc rsi
    inc rdi
    jmp .mk_l
.mk_ok:
    pop rdi
    pop rsi
    mov rax, 1
    ret
.mk_fail:
    pop rdi
    pop rsi
    xor rax, rax
    ret

; --- Private Helper: Copy value to buffer ---
.copy_val:
    xor rcx, rcx
.cv_l:
    mov al, [rdi]
    cmp al, '&'
    je .cv_done
    cmp al, ' '
    je .cv_done
    test al, al
    jz .cv_done
    cmp rcx, 31                 ; Buffer safety limit for keys (32 bytes)
    jae .cv_done
    mov [rsi], al
    inc rdi
    inc rsi
    inc rcx
    jmp .cv_l
.cv_done:
    mov byte [rsi], 0           ; Null terminate the destination
    ret

; --- Private Helper: ASCII to Integer (32-bit) ---
.atoi_l:
    xor rax, rax
.at_l:
    movzx rcx, byte [rdi]
    cmp cl, '0'
    jb .at_done
    cmp cl, '9'
    ja .at_done
    sub cl, '0'
    imul rax, 10
    add rax, rcx
    inc rdi
    jmp .at_l
.at_done:
    cmp rax, 500                ; Safety cap: max 500 results
    jbe .at_save
    mov rax, 500
.at_save:
    mov [q_limit], eax
    ret