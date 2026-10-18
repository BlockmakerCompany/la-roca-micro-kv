; -----------------------------------------------------------------------------
; Module: src/handlers/del.asm
; Project: La Roca Micro-KV
; Responsibility: Logic for HTTP DELETE operations.
;                 Implements WAL logging, B-Tree gap-collapse deletion.
;                 SELF-CONTAINED: runs in the Writer Thread and extracts the key
;                 from the raw request buffer (no reader-thread TLS dependency).
; -----------------------------------------------------------------------------
%include "config.inc"
%include "responses.inc"     ; Centralized headers and lengths (removes Linker ambiguity)

; --- External Symbols ---
extern handle_404, handle_400, close_socket
extern btree_delete, append_wal
extern get_shard_ptr
extern get_shard_index      ; 🛡️ IMPORT: Shard index for per-shard seqlock
extern shard_seq_inc        ; 🛡️ IMPORT: Seqlock writer barrier
extern rt_key_size

section .bss
    del_key resb 256        ; Writer-owned key buffer (single writer thread)

section .text
    global handle_del

; -----------------------------------------------------------------------------
; handle_del: Processes the deletion of a key-value pair.
; Contract (Writer Thread): RSI = Raw Request Buffer ("DELETE /keys/{key} ..."),
;                           RDX = Client Socket FD. RDI is ignored.
; -----------------------------------------------------------------------------
handle_del:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r13, rdx                ; r13 = Client Socket FD
    mov r14, rsi                ; r14 = Raw Request Buffer

    ; 1. Extract key from "DELETE /keys/{key}" (key starts at offset 13)
    lea rsi, [r14 + 13]

    lea rdi, [del_key]
    xor rax, rax
    mov rcx, 32                 ; 32 qwords = 256 bytes
    rep stosq

    lea rdi, [del_key]
    xor rcx, rcx
.ext_loop:
    lodsb
    cmp al, ' '                 ; End of URI
    je .ext_done
    test al, al
    jz .ext_done
    inc rcx
    cmp rcx, [rt_key_size]      ; Max key length safety (dynamic geometry)
    jae .err_400
    stosb
    jmp .ext_loop

.ext_done:
    test rcx, rcx               ; Empty key?
    jz .err_404

    ; 2. Resolve shard
    lea rsi, [del_key]
    call get_shard_ptr
    mov r12, rdx                ; r12 = Shard Base Pointer

    ; 3. Persist Intent: Write-Ahead Log (WAL). OpCode 0x02 = DELETE.
    mov rdi, 2                  ; Op: DELETE
    lea rsi, [del_key]
    xor rdx, rdx                ; No payload
    xor rcx, rcx                ; Length 0
    call append_wal

    ; 4. Update Index: B-Tree Deletion (under per-shard seqlock)
    lea rsi, [del_key]
    call get_shard_index
    mov rbx, rax

    mov rdi, rbx
    call shard_seq_inc          ; WRITE BEGIN: +1 (ODD -> readers spin/retry)

    mov rdi, r12
    lea rsi, [del_key]
    call btree_delete           ; RAX=1 if found, 0 if miss

    push rax                    ; Preserve result (shard_seq_inc clobbers RAX)
    mov rdi, rbx
    call shard_seq_inc          ; WRITE END: +1 (EVEN -> readers can proceed)
    pop rax

    test rax, rax
    jz .err_404                 ; key miss

    ; 5. Success Response (200 OK)
    mov rax, 1                  ; sys_write
    mov rdi, r13
    lea rsi, [hdr_200_del]
    mov rdx, len_200_del
    syscall

    ; 6. Writer thread owns the socket and MUST close it.
    jmp .finish_with_close

.err_400:
    mov rdi, r13
    call handle_400             ; handle_400 already closes the socket
    jmp .finish

.err_404:
    mov rdi, r13
    call handle_404             ; handle_404 responds but does NOT close (keep-alive)
    jmp .finish_with_close      ; writer owns the socket: close it explicitly

.finish_with_close:
    mov rax, 3
    mov rdi, r13
    syscall

.finish:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
