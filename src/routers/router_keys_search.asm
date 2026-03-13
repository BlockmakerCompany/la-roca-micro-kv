; -----------------------------------------------------------------------------
; Module: src/routers/router_keys_search.asm
; Project: La Roca Micro-KV
; Responsibility: Route SCAN/SEARCH requests under /keys.
;                 Parses Query Parameters: prefix, startkey, and limit.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- Conditional Trace Macro ---
%macro TRACE 1
    %ifdef TRACE_ENABLED
        section .data
            %%msg db "[TRACE:SEARCH] ", %1, 0x0A
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
    %endif
%endmacro

extern handle_scan, handle_400
extern q_prefix, q_startkey, q_limit

section .text
    global route_keys_search

; -----------------------------------------------------------------------------
; route_keys_search: Logic for GET /keys?prefix=...&limit=...
; Input:
;   RDI = Client Socket FD
;   RSI = Request Buffer
; -----------------------------------------------------------------------------
route_keys_search:
    push rbx
    push r12
    push r13
    push r14

    mov r12, rdi                ; r12 = Socket FD
    mov r13, rsi                ; r13 = Buffer

    TRACE "Sub-router SEARCH activated"

    ; 1. Reset Query State
    call .reset_query_buffers

    ; 2. Locate the start of parameters
    ; We look for '?' or ' ' (end of /keys)
    lea rsi, [r13 + 4]          ; Skip "GET "
.find_q:
    lodsb
    cmp al, ' '                 ; Root scan (no params)
    je .execute_scan
    cmp al, '?'                 ; Start of params
    je .parse_params
    test al, al
    jz .execute_scan            ; Safety
    jmp .find_q

.parse_params:
    ; RSI now points after '?'
.param_loop:
    ; Identify key: prefix=, start=, limit=
    mov eax, [rsi]

    ; Check "pref" (prefix=)
    cmp eax, 0x66657270         ; "pref"
    je .extract_prefix

    ; Check "star" (start=)
    cmp eax, 0x72617473         ; "star"
    je .extract_start

    ; Check "limi" (limit=)
    cmp eax, 0x696d696c         ; "limi"
    je .extract_limit

.skip_param:
    ; If unknown param, skip until '&' or ' '
    lodsb
    cmp al, ' '
    je .execute_scan
    cmp al, '&'
    je .param_loop
    test al, al
    jz .execute_scan
    jmp .skip_param

.extract_prefix:
    add rsi, 7                  ; Skip "prefix="
    lea rdi, [q_prefix]
    call .extract_value
    jmp .next_param

.extract_start:
    add rsi, 9                  ; Skip "startkey=" (o ajusta según tu protocolo)
    lea rdi, [q_startkey]
    call .extract_value
    jmp .next_param

.extract_limit:
    add rsi, 6                  ; Skip "limit="
    call .extract_int
    mov [q_limit], eax
    ; .extract_int already advanced RSI to delimiter
    jmp .next_param

.next_param:
    ; Check if there's more
    cmp byte [rsi-1], '&'
    je .param_loop
    jmp .execute_scan

.execute_scan:
    TRACE "Executing scan with parsed parameters"
    mov rdi, r12
    mov rsi, r13
    call handle_scan
    mov rax, 1
    jmp .exit

; --- Internal Helpers ---

.reset_query_buffers:
    lea rdi, [q_prefix]
    xor rax, rax
    mov rcx, 64                 ; 256 bytes / 4
    rep stosd
    lea rdi, [q_startkey]
    mov rcx, 64
    rep stosd
    mov dword [q_limit], 100    ; Default limit
    ret

.extract_value:
    ; Copy from RSI to RDI until '&' or ' '
    xor rcx, rcx
.ev_l:
    lodsb
    cmp al, ' '
    je .ev_d
    cmp al, '&'
    je .ev_d
    stosb
    inc rcx
    cmp rcx, 255
    ja .ev_d
    jmp .ev_l
.ev_d:
    ret

.extract_int:
    ; Simple atoi for limit parameter
    xor rax, rax
    xor rcx, rcx
    mov rbx, 10
.ei_l:
    lodsb
    cmp al, '0'
    jb .ei_d
    cmp al, '9'
    ja .ei_d
    sub al, '0'
    movzx rdx, al
    imul rax, rbx
    add rax, rdx
    jmp .ei_l
.ei_d:
    ret

.exit:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret