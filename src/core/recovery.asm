; -----------------------------------------------------------------------------
; Module: src/core/recovery.asm
; Project: La Roca Micro-KV
; Responsibility: Hardened WAL Replay Engine.
;                 Validates hardware CRC32 signatures before replaying
;                 transactions to ensure zero-corruption during boot.
; -----------------------------------------------------------------------------
%include "config.inc"

extern wal_fd
extern get_shard_ptr
extern btree_insert
extern btree_delete
extern calculate_crc32
extern log_msg           ; 🛡️ Importamos tu logger global

section .data
    msg_corrupt db "[CRITICAL] WAL Integrity Check Failed! Checksum mismatch. Halting block recovery.", 0x0A
    len_corrupt equ $ - msg_corrupt

    msg_ok      db "[TRACE] WAL Block Integrity OK. Replaying...", 0x0A
    len_ok      equ $ - msg_ok

section .bss
    recovery_buf resb 1024

section .text
    global recover_from_wal

; -----------------------------------------------------------------------------
; recover_from_wal: Replays the WAL log with integrity checks.
; -----------------------------------------------------------------------------
recover_from_wal:
    push rbp
    mov rbp, rsp
    push rbx                    ; wal_fd
    push r12                    ; shard_ptr
    push r13                    ; scratchpad

    ; 1. Validate WAL File Descriptor
    mov rbx, [wal_fd]
    cmp rbx, 0
    js .exit_recovery

    ; 2. Rewind: Reposition to start
    mov rax, 8                  ; sys_lseek
    mov rdi, rbx
    xor rsi, rsi
    xor rdx, rdx
    syscall

.read_loop:
    ; 3. Read an atomic 1024-byte block
    mov rax, 0                  ; sys_read
    mov rdi, rbx
    lea rsi, [recovery_buf]
    mov rdx, 1024
    syscall

    cmp rax, 1024
    jne .exit_recovery          ; EOF or partial record

    ; --- 🛡️ INTEGRITY CHECK (CRC32 Verification) ---
    ; Calculate checksum of the payload (offset 4 to 1023)
    lea rsi, [recovery_buf + 4]
    mov rcx, 1020               ; Total block minus the 4-byte CRC header
    call calculate_crc32        ; Returns EAX = Calculated CRC

    ; Compare with the stored CRC at offset +0
    cmp eax, dword [recovery_buf]
    jne .corruption_detected    ; CRITICAL: Checksum mismatch!

    ; --- TELEMETRÍA: BLOQUE SANO ---
    push rax
    push rcx
    push rdx
    mov rdi, 1
    lea rsi, [msg_ok]
    mov rdx, len_ok
    call log_msg
    pop rdx
    pop rcx
    pop rax

    ; --- 4. Replay Operation Logic (New Offsets) ---
    ; Layout: [CRC(4) | Op(1) | Len(2) | Key(32) | Val(985)]

    ; Keys are now at offset +7.
    lea rsi, [recovery_buf + 7]
    call get_shard_ptr
    mov r12, rdx

    ; Opcode Dispatcher (Now at offset +4)
    movzx rax, byte [recovery_buf + 4]
    cmp al, 1
    je .do_set_recovery
    cmp al, 2
    je .do_del_recovery

    jmp .read_loop              ; Skip unknown opcodes

.do_set_recovery:
    mov rdi, r12
    lea rsi, [recovery_buf + 7]  ; Key at +7
    lea rdx, [recovery_buf + 39] ; Value at +39 (4+1+2+32)
    movzx rcx, word [recovery_buf + 5] ; Payload Len at +5
    call btree_insert
    jmp .read_loop

.do_del_recovery:
    mov rdi, r12
    lea rsi, [recovery_buf + 7]
    call btree_delete
    jmp .read_loop

.corruption_detected:
    ; --- TELEMETRÍA: CORRUPCIÓN DETECTADA ---
    mov rdi, 1
    lea rsi, [msg_corrupt]
    mov rdx, len_corrupt
    call log_msg

    ; For a database, it's safer to stop recovery than to apply garbage.
    jmp .exit_recovery

.exit_recovery:
    pop r13
    pop r12
    pop rbx
    leave
    ret