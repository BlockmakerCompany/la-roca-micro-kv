; -----------------------------------------------------------------------------
; Module: src/core/router_system.asm
; Responsibility: Handle system probes without side effects.
; -----------------------------------------------------------------------------
%include "config.inc"

extern handle_live, handle_stats

section .text
    global route_system

route_system:
    mov r12, rdi                ; FD
    mov r13, rsi                ; Buffer

    ; System routes are strictly GET
    mov eax, [r13]
    cmp eax, 0x20544547         ; 'GET '
    jne .not_handled

    lea rsi, [r13 + 4]          ; Point to URI start '/'
    mov rax, [rsi]

    ; Check /live
    mov rdx, rax
    mov rcx, 0x0000FFFFFFFFFFFF ; 6-byte mask
    and rdx, rcx
    mov rcx, 0x206576696C2F     ; "/live "
    cmp rdx, rcx
    je .call_live

    ; Check /stats
    mov rdx, rax
    mov rcx, 0x00FFFFFFFFFFFFFF ; 7-byte mask
    and rdx, rcx
    mov rcx, 0x2073746174732F   ; "/stats "
    cmp rdx, rcx
    je .call_stats

.not_handled:
    xor rax, rax
    ret

.call_live:
    mov rdi, r12
    call handle_live
    mov rax, 1
    ret

.call_stats:
    mov rdx, r12
    call handle_stats
    mov rax, 1
    ret