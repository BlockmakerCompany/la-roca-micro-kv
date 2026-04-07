; -----------------------------------------------------------------------------
; Module: src/handlers/base.asm
; Project: La Roca Micro-KV
; Responsibility: Global HTTP Response Handlers & Generic Helpers.
;                 Implements Keep-Alive for health checks and
;                 Mandatory Closure for error states.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc"

section .text
    ; Generic Handlers
    global handle_live, handle_ready, handle_404, handle_400, handle_411, handle_413, handle_507
    ; Helpers
    global close_socket

; -----------------------------------------------------------------------------
; Helper: close_socket
; Input: RDI = Socket FD
; -----------------------------------------------------------------------------
close_socket:
    mov rax, 3                  ; sys_close
    syscall
    ret

; -----------------------------------------------------------------------------
; Standard Handlers
; -----------------------------------------------------------------------------

handle_live:
    ; SUCCESS PATH: We keep the connection alive for health probes efficiency.
    mov rax, 1                  ; sys_write
    lea rsi, [hdr_alive]        ; Must include "Connection: keep-alive"
    mov rdx, len_alive
    syscall
    ; We return WITHOUT calling close_socket
    ret

handle_ready:
    jmp handle_live

handle_404:
    ; ERROR PATH: Resource not found. We close the socket for security.
    push rdi
    mov rax, 1
    lea rsi, [hdr_404]
    mov rdx, len_404
    syscall
    pop rdi
    ret

handle_400:
    ; SECURITY PATH: Bad request. Mandatory closure to mitigate fuzzing.
    push rdi
    mov rax, 1
    lea rsi, [hdr_400]
    mov rdx, len_400
    syscall
    pop rdi
    call close_socket
    ret

handle_411:
    push rdi
    mov rax, 1
    lea rsi, [msg_411]
    mov rdx, len_411
    syscall
    pop rdi
    call close_socket
    ret

handle_413:
    ; CRITICAL: Entity too large. Always close to stop data ingestion.
    push rdi
    mov rax, 1
    lea rsi, [msg_413]
    mov rdx, len_413
    syscall
    pop rdi
    call close_socket
    ret

handle_507:
    ; STORAGE PATH: Shard full. Close to signal client to stop retry on this socket.
    push rdi
    mov rax, 1
    lea rsi, [hdr_507]
    mov rdx, len_507
    syscall
    pop rdi
    call close_socket
    ret