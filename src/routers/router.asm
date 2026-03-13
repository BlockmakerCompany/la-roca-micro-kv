; -----------------------------------------------------------------------------
; Module: src/routers/router.asm
; Project: La Roca Micro-KV
; Responsibility: Main entry point for request routing.
;                 Implements global security filtering before dispatching.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- External Modules ---
extern route_system
extern route_keys
extern handle_404
extern secure_path_scan       ; From security.asm

section .text
    global route_request

; -----------------------------------------------------------------------------
; route_request: Orchestrates global routing flow.
; -----------------------------------------------------------------------------
route_request:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13

    mov r12, rdi                ; r12 = Client Socket FD
    mov r13, rsi                ; r13 = Raw Request Buffer

    TRACE "New request received. Running global security scan..."

    ; --- 🛡️ GLOBAL SECURITY GUARD ---
    ; Before any routing, we check the entire request line for ".."
    ; This is our zero-trust policy.
    mov rsi, r13
    call secure_path_scan
    test rax, rax
    jnz .security_alert

    ; --- 1. System Routes (/stats, /health, etc.) ---
    TRACE "Dispatching to System Router..."
    mov rdi, r12
    mov rsi, r13
    call route_system
    test rax, rax
    jnz .done                   ; Handled by route_system

    ; --- 2. Key-Value Routes (/keys/...) ---
    TRACE "Dispatching to Keys Router..."
    mov rdi, r12
    mov rsi, r13
    call route_keys
    test rax, rax
    jnz .done                   ; Handled by route_keys

    ; --- 3. Fallback: Not Found ---
    TRACE "No route matched. Sending 404..."
    mov rdi, r12
    call handle_404

    ; We set RAX=1 to notify the main loop that the socket
    ; has been handled and closed by the handler.
    mov rax, 1
    jmp .done

.security_alert:
    TRACE "SECURITY ALERT: Global Path Traversal attempt blocked!"
    mov rdi, r12
    call handle_404             ; Obscurity: return 404 for attacks
    mov rax, 1
    jmp .done

.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret