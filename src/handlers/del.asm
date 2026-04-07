; -----------------------------------------------------------------------------
; Module: src/handlers/del.asm
; Project: La Roca Micro-KV
; Responsibility: Logic for HTTP DELETE operations.
;                 Implements WAL logging, B-Tree gap-collapse deletion,
;                 and supports HTTP Keep-Alive on success.
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc"     ; Centralized headers and lengths (removes Linker ambiguity)

; --- External Symbols ---
extern handle_404, close_socket
extern btree_delete, append_wal
extern flush_shard
extern validated_key        ; Cleaned 32-byte key buffer provided by Router

section .text
    global handle_del

; -----------------------------------------------------------------------------
; handle_del: Processes the deletion of a key-value pair.
; -----------------------------------------------------------------------------
handle_del:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13

    ; Context Mapping
    mov r12, rdi                ; r12 = Shard Base Pointer
    mov r13, rdx                ; r13 = Client Socket FD

    ; 1. Persist Intent: Write-Ahead Log (WAL)
    ; OpCode 0x02 = DELETE.
    mov rdi, 2                  ; Op: DELETE
    lea rsi, [validated_key]
    xor rdx, rdx                ; No payload
    xor rcx, rcx                ; Length 0
    call append_wal

    ; 2. Update Index: B-Tree Deletion
    mov rdi, r12
    lea rsi, [validated_key]
    call btree_delete           ; RAX=1 if found, 0 if miss

    ; Guard: If key miss, handle_404 will respond and CLOSE the socket
    test rax, rax
    jz .err_411_miss

    ; 3. Hardware Commit
    mov rdi, r12
    call flush_shard

    ; 4. Success Response (200 OK)
    mov rax, 1                  ; sys_write
    mov rdi, r13
    lea rsi, [hdr_200_del]      ; Must include "Connection: keep-alive" in responses.inc
    mov rdx, len_200_del
    syscall

    ; 🛡️ CRITICAL FIX: Do NOT close socket here.
    ; Return cleanly to main loop for Keep-Alive.
    jmp .finish

.err_411_miss:
    mov rdi, r13
    call handle_404             ; handle_404 in base.asm already performs closure

.finish:
    pop r13
    pop r12
    pop rbx
    leave
    ret