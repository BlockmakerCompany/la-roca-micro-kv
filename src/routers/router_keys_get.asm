; -----------------------------------------------------------------------------
; Module: src/routers/router_keys_get.asm
; Project: La Roca Micro-KV
; Responsibility: Route GET and DELETE requests for individual keys.
;                 Handles key extraction and shard dispatching.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- Conditional Trace Macro ---
%macro TRACE 1
    %ifdef TRACE_ENABLED
        section .data
            %%msg db "[TRACE:KEYS_GET] ", %1, 0x0A
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

extern get_shard_ptr
extern handle_get, handle_del, handle_400, handle_404
extern validated_key

section .text
    global route_keys_get

; -----------------------------------------------------------------------------
; route_keys_get: Logic for /keys/{key} (GET/DELETE)
; Input:
;   RDI = Client Socket FD
;   RSI = Request Buffer
; -----------------------------------------------------------------------------
route_keys_get:
    push rbx
    push r12
    push r13

    mov r12, rdi                ; r12 = Socket FD
    mov r13, rsi                ; r13 = Buffer

    TRACE "Sub-router GET/DELETE activated"

    ; 1. Calculate URI start based on Verb
    mov eax, [r13]
    cmp eax, 0x20544547         ; "GET "
    je .offset_get
    lea rsi, [r13 + 7]          ; "DELETE "
    jmp .find_key_start

.offset_get:
    lea rsi, [r13 + 4]          ; Start after "GET "

.find_key_start:
    ; Skip "/keys/" (6 bytes)
    add rsi, 6

    ; 2. Clear validated_key buffer
    lea rdi, [validated_key]
    xor rax, rax
    mov rcx, 32                 ; Clear 256 bytes (32 * 8)
    rep stosq

    ; 3. Extract Key from URI
    lea rdi, [validated_key]
    xor rcx, rcx
.ext_loop:
    lodsb
    cmp al, ' '                 ; End of URI
    je .ext_done
    test al, al                 ; End of string
    jz .ext_done

    inc rcx
    cmp rcx, 31                 ; Max key length safety
    ja .err_400

    stosb
    jmp .ext_loop

.ext_done:
    test rcx, rcx               ; Empty key?
    jz .err_404

    TRACE "Key extracted successfully, resolving shard..."

    ; 4. Shard Resolution and Dispatch
    lea rsi, [validated_key]
    call get_shard_ptr

    mov rdi, rdx                ; RDI = Shard pointer
    mov rsi, r13                ; RSI = Request Buffer
    mov rdx, r12                ; RDX = Socket FD

    ; Re-check verb for final call
    mov eax, [r13]
    cmp eax, 0x20544547         ; GET
    je .call_get

    TRACE "Dispatching to DELETE handler"
    call handle_del
    jmp .handled

.call_get:
    TRACE "Dispatching to GET handler"
    call handle_get

.handled:
    mov rax, 1                  ; Signal success
    jmp .exit

.err_400:
    mov rdi, r12
    call handle_400
    mov rax, 1
    jmp .exit

.err_404:
    mov rdi, r12
    call handle_404
    mov rax, 1

.exit:
    pop r13
    pop r12
    pop rbx
    ret