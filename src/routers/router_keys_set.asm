; -----------------------------------------------------------------------------
; Module: src/routers/router_keys_set.asm
; Project: La Roca Micro-KV
; Responsibility: Route POST requests for individual keys.
;                 Implements concurrency control via Spinlocks.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- Conditional Trace Macro ---
%macro TRACE 1
    %ifdef TRACE_ENABLED
        section .data
            %%msg db "[TRACE:KEYS_SET] ", %1, 0x0A
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

; --- External Primitives ---
extern get_shard_ptr
extern handle_set, handle_400, handle_404
extern validated_key
extern acquire_lock, release_lock   ; From utils.asm

section .text
    global route_keys_set

; -----------------------------------------------------------------------------
; route_keys_set: Logic for POST /keys/{key}
; Input:
;   RDI = Client Socket FD
;   RSI = Request Buffer
; -----------------------------------------------------------------------------
route_keys_set:
    push rbx
    push r12
    push r13

    mov r12, rdi                ; r12 = Socket FD
    mov r13, rsi                ; r13 = Buffer

    TRACE "Sub-router SET (POST) activated"

    ; 1. Calculate URI start
    ; For POST, the offset is usually "POST " (5 bytes)
    lea rsi, [r13 + 5]

    ; 2. Skip "/keys/" (6 bytes)
    add rsi, 6

    ; 3. Clear validated_key buffer
    lea rdi, [validated_key]
    xor rax, rax
    mov rcx, 32                 ; 256 bytes total
    rep stosq

    ; 4. Key Extraction
    lea rdi, [validated_key]
    xor rcx, rcx
.ext_loop:
    lodsb
    cmp al, ' '                 ; End of URI
    je .ext_done
    test al, al
    jz .ext_done

    inc rcx
    cmp rcx, 31                 ; Hard limit
    ja .err_400

    stosb
    jmp .ext_loop

.ext_done:
    test rcx, rcx
    jz .err_404

    ; 5. Shard Resolution
    TRACE "Key extracted. Resolving shard..."
    lea rsi, [validated_key]
    call get_shard_ptr

    ; Preparation for handler
    mov rdi, rdx                ; RDI = Shard pointer
    mov rsi, r13                ; RSI = Original Buffer
    mov rdx, r12                ; RDX = Socket FD

    ; 6. 🔒 CONCURRENCY CONTROL: ACQUIRE LOCK
    ; We lock the entire engine before the SET handler starts writing
    ; to the WAL and the B-Tree to prevent race conditions.
    TRACE "Acquiring global shard lock..."
    call acquire_lock

    ; 7. Execute SET handler
    TRACE "Dispatching to handle_set"
    call handle_set

    ; 8. 🔓 RELEASE LOCK
    TRACE "Releasing global shard lock"
    call release_lock

    mov rax, 1                  ; Handled
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