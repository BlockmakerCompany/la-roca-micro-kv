; -----------------------------------------------------------------------------
; Module: src/handlers/base.asm
; Project: La Roca Micro-KV
; Responsibility: Global HTTP Response Handlers & Generic Helpers.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc" ; <--- IMPORTANTE: Centralizamos la data aquí

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
    push rdi
    mov rax, 1                  ; sys_write
    lea rsi, [hdr_alive]
    mov rdx, len_alive          ; Resuelto localmente por el %include
    syscall
    pop rdi
    call close_socket
    ret

handle_ready:
    jmp handle_live

handle_404:
    push rdi
    mov rax, 1
    lea rsi, [hdr_404]
    mov rdx, len_404
    syscall
    pop rdi
    call close_socket
    ret

handle_400:
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
    push rdi
    mov rax, 1
    lea rsi, [msg_413]
    mov rdx, len_413
    syscall
    pop rdi
    call close_socket
    ret

handle_507:
    push rdi
    mov rax, 1
    lea rsi, [hdr_507]
    mov rdx, len_507
    syscall
    pop rdi
    call close_socket
    ret