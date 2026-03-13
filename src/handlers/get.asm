; -----------------------------------------------------------------------------
; Module: src/handlers/get.asm
; Project: La Roca Micro-KV
; Responsibility: High-performance Zero-Copy Data Retrieval (Dynamic Geometry).
;                 Enforces socket closure after transmission to prevent leaks.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc" ; <--- Resolves hdr_200_dyn, hdr_crlf_crlf locally

; --- External Symbols ---
extern handle_404, close_socket
extern btree_find
extern validated_key

; --- Dynamic Configuration Dependencies ---
extern rt_offset_len, rt_offset_val

section .bss
    ascii_len  resb 16

section .text
    global handle_get

; -----------------------------------------------------------------------------
; handle_get: Handles key lookup and zero-copy binary response.
; -----------------------------------------------------------------------------
handle_get:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Context Mapping
    mov r12, rdi                ; r12 = Shard Base Pointer
    mov r13, rdx                ; r13 = Client Socket FD

    ; 1. B-Tree Index Lookup
    mov rdi, r12
    lea rsi, [validated_key]
    call btree_find
    test rax, rax
    jz .err_404

    ; 2. Metadata Extraction (Dynamic Offsets)
    ; RAX = Slot start, r14 = Payload length, r15 = Value Pointer
    mov rdx, [rt_offset_len]
    movzx r14, word [rax + rdx]
    mov rdx, [rt_offset_val]
    lea r15, [rax + rdx]

    ; 3. ITOS (Integer-to-ASCII) for Content-Length Header
    mov rax, r14
    lea rdi, [ascii_len + 15]
    mov byte [rdi], 0
    mov rbx, 10
.itoa:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .itoa

    ; Prepare dynamic length write parameters
    mov rbx, rdi                ; rbx = ASCII start pointer
    lea rdx, [ascii_len + 15]
    sub rdx, rbx                ; rdx = ASCII length
    push rdx

    ; --- 4. HTTP RESPONSE CHAIN ---

    ; A. Static Headers (Connection: close included)
    mov rax, 1
    mov rdi, r13
    lea rsi, [hdr_200_dyn]
    mov rdx, len_200_dyn
    syscall

    ; B. Dynamic Content-Length Value
    pop rdx
    mov rax, 1
    mov rdi, r13
    mov rsi, rbx
    syscall

    ; C. Header-Body Delimiter (\r\n\r\n)
    mov rax, 1
    mov rdi, r13
    lea rsi, [hdr_crlf_crlf]
    mov rdx, len_crlf_crlf
    syscall

    ; D. Zero-Copy Body Transmission
    test r14, r14
    jz .finish_with_close

    mov rax, 1
    mov rdi, r13
    mov rsi, r15
    mov rdx, r14
    syscall

.finish_with_close:
    ; Mandatory Hygiene: Close socket to signal EOF and drain buffers.
    mov rdi, r13
    call close_socket
    jmp .finish

.err_404:
    ; Key-miss: handle_404 responds and closes the socket.
    mov rdi, r13
    call handle_404

.finish:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret