; -----------------------------------------------------------------------------
; Module: src/data/wal.asm
; Project: La Roca Micro-KV
; Responsibility: Hardened Write-Ahead Log (WAL) with Hardware CRC32.
;                 Ensures data integrity via SSE4.2 checksums before commit.
;
; Layout (1024 bytes):
; [+0]  CRC32 Checksum (4 bytes, uint32) -> Covers bytes 4-1023
; [+4]  OpCode (1 byte: 0x01=SET, 0x02=DEL)
; [+5]  Payload Length (2 bytes, uint16)
; [+7]  Key (32 bytes, fixed-width)
; [+39] Value (985 bytes, raw binary)
; -----------------------------------------------------------------------------
%include "config.inc"

extern wal_fd
extern calculate_crc32      ; From security.asm

section .bss
    wal_buf resb 1024

section .text
    global append_wal

; -----------------------------------------------------------------------------
; append_wal: Serializes data and signs it with a hardware CRC32.
; -----------------------------------------------------------------------------
append_wal:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; 1. Preserve arguments
    mov r12, rdi            ; OpCode
    mov r13, rsi            ; Key Ptr
    mov r14, rdx            ; Val Ptr
    mov r15, rcx            ; Val Len

    ; 2. Absolute Sanitization (Zero-padding)
    lea rdi, [wal_buf]
    xor al, al
    mov rcx, 1024
    cld
    rep stosb

    ; 3. Assemble Record Metadata (Starting at offset +4)
    lea rdi, [wal_buf]

    ; [+4] OpCode
    mov rax, r12
    mov byte [rdi + 4], al

    ; [+5] Data Length
    mov rcx, r15
    mov word [rdi + 5], cx

    ; 4. Serialize Key (Bytes 7-38)
    lea rdi, [wal_buf + 7]
    mov rsi, r13
    mov rcx, 32
    rep movsb

    ; 5. Serialize Value Payload (Bytes 39-1023)
    cmp r12, 1
    jne .compute_integrity
    test r15, r15
    jz .compute_integrity

    lea rdi, [wal_buf + 39]
    mov rsi, r14
    mov rcx, r15
    rep movsb

.compute_integrity:
    ; 6. 🛡️ Hardware Checksum Generation
    ; We calculate the CRC32 of the entire record EXCEPT the CRC field itself.
    ; This covers OpCode, Length, Key, Value AND the trailing zero-padding.
    lea rsi, [wal_buf + 4]   ; Start scanning after the CRC field
    mov rcx, 1020           ; 1024 - 4 bytes of CRC
    call calculate_crc32    ; Returns EAX = CRC32

    ; Store the result at the very beginning of the buffer
    mov dword [wal_buf], eax

    ; 7. Atomic Disk Commit
    mov rax, 1              ; sys_write
    mov rdi, [wal_fd]
    lea rsi, [wal_buf]
    mov rdx, 1024
    syscall

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret