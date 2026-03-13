; -----------------------------------------------------------------------------
; Module: src/core/security.asm
; Project: La Roca Micro-KV
; Responsibility: Centralized security primitives, URI sanitization,
;                 and hardware-accelerated integrity (CRC32).
; -----------------------------------------------------------------------------
%include "config.inc"

section .text
    global secure_path_scan
    global check_int_overflow
    global calculate_crc32

; -----------------------------------------------------------------------------
; secure_path_scan: Scans a buffer for dangerous Path Traversal sequences (..).
; -----------------------------------------------------------------------------
secure_path_scan:
    push rsi
.loop:
    mov al, [rsi]
    test al, al
    jz .safe
    cmp al, ' '
    je .safe
    cmp al, '.'
    jne .next
    cmp byte [rsi+1], '.'
    je .unsafe
.next:
    inc rsi
    jmp .loop
.unsafe:
    pop rsi
    mov rax, 1
    ret
.safe:
    pop rsi
    xor rax, rax
    ret

; -----------------------------------------------------------------------------
; calculate_crc32: Hardware-accelerated checksum using SSE4.2 instructions.
; -----------------------------------------------------------------------------
; Input:  RSI = Pointer to data buffer
;         RCX = Length of data in bytes
; Output: EAX = 32-bit Checksum
; -----------------------------------------------------------------------------
calculate_crc32:
    push rsi
    push rcx
    mov eax, 0xFFFFFFFF         ; Initial CRC value (Standard)

    test rcx, rcx               ; Safety check for 0 length
    jz .done

.crc_loop:
    ; The 'crc32' instruction updates the EAX accumulator
    ; with the byte pointed by RSI.
    crc32 eax, byte [rsi]
    inc rsi
    loop .crc_loop

.done:
    not eax                     ; Final XOR (Standard CRC32 requirement)
    pop rcx
    pop rsi
    ret

; -----------------------------------------------------------------------------
; check_int_overflow: Placeholder for inlined logic in handlers.
; -----------------------------------------------------------------------------
check_int_overflow:
    ret