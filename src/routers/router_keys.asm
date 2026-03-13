; -----------------------------------------------------------------------------
; Module: src/core/router_keys.asm
; Project: La Roca Micro-KV
; Responsibility: Handle Key-Value operations under the "/keys" namespace.
;                 Includes a security guard to prevent Path Traversal (..).
; -----------------------------------------------------------------------------
%include "config.inc"

extern get_shard_ptr
extern handle_get, handle_set, handle_del, handle_scan, handle_400, handle_404
extern rt_key_size

section .bss
    global validated_key
    validated_key resb 256

    global q_prefix, q_startkey, q_limit
    q_prefix   resb 256
    q_startkey resb 256
    q_limit    resd 1

section .text
    global route_keys

; -----------------------------------------------------------------------------
; route_keys: Primary entry point for /keys namespace
; -----------------------------------------------------------------------------
route_keys:
    push rbx
    mov r12, rdi                ; r12 = Client Socket FD
    mov r13, rsi                ; r13 = Request Buffer

    TRACE "Request entering route_keys"

    ; 1. Verb Identification
    mov eax, [r13]
    cmp eax, 0x20544547         ; "GET "
    je .prep_get
    cmp eax, 0x54534F50         ; "POST"
    je .prep_post
    cmp eax, 0x454C4544         ; "DELE"
    je .prep_del
    xor rax, rax                ; Not a data verb
    pop rbx
    ret

.prep_get:
    lea rsi, [r13 + 4]          ; URI start after "GET "
    jmp .check_namespace

.prep_post:
    lea rsi, [r13 + 5]          ; URI start after "POST "
    jmp .check_namespace

.prep_del:
    lea rsi, [r13 + 7]          ; URI start after "DELETE "

.check_namespace:
    ; --- NAMESPACE INTERCEPTION ---
    ; Verify if URI starts with "/keys" (5 bytes)
    mov rax, [rsi]
    mov rdx, rax
    mov rcx, 0x000000FFFFFFFFFF ; Mask for 5 bytes
    and rdx, rcx
    mov rcx, 0x7379656b2f       ; "/keys"
    cmp rdx, rcx
    jne .not_handled

    ; --- 🛡️ SECURITY GUARD: ANTI-PATH TRAVERSAL ---
    TRACE "Starting path traversal security scan..."
    push rsi

    ; Start scanning the whole URI path from the beginning of "/keys"
.sc_loop:
    mov al, [rsi]
    test al, al                 ; End of string
    jz .sc_pass
    cmp al, ' '                 ; End of URI (HTTP delimiter)
    je .sc_pass

    cmp al, '.'                 ; Potential dot
    jne .sc_next

    ; If we find a dot, check the very next character
    cmp byte [rsi+1], '.'
    je .sc_fail                 ; Double dot ".." detected!

.sc_next:
    inc rsi
    jmp .sc_loop

.sc_fail:
    TRACE "SECURITY ALERT: Path Traversal attempt blocked (..)"
    pop rsi
    jmp .security_abort

.sc_pass:
    pop rsi
    TRACE "Path traversal scan: CLEAN"
    ; --- END SECURITY GUARD ---

    ; Determine logic path based on character after "/keys"
    mov al, [rsi + 5]
    cmp al, '/'                 ; "/keys/..."
    je .is_keys_path
    cmp al, '?'                 ; "/keys?..."
    je .call_scan
    cmp al, ' '                 ; "/keys "
    je .call_scan
    jmp .not_handled

.is_keys_path:
    add rsi, 5                  ; Skip "/keys" prefix
    ; Proceed to single key processing

.process_key:
    cmp byte [rsi], '/'         ; Ensure we are at the slash
    jne .not_handled
    inc rsi                     ; RSI points to key content

    ; 2. Clear validated_key buffer
    lea rdi, [validated_key]
    xor rax, rax
    mov rcx, 32
    rep stosq

    ; 3. Key Extraction
    lea rdi, [validated_key]
    xor rcx, rcx
.v_loop:
    lodsb
    cmp al, ' '
    je .v_done
    test al, al
    jz .v_done

    inc rcx
    cmp rcx, 31                 ; Shard slot limit
    ja .err_400

    stosb
    jmp .v_loop

.v_done:
    test rcx, rcx
    jz .not_handled

    ; 4. Dispatch to Shards and Handlers
    lea rsi, [validated_key]
    call get_shard_ptr
    mov rdi, rdx                ; Shard pointer
    mov rsi, r13                ; Request buffer
    mov rdx, r12                ; Socket FD

    mov eax, [r13]
    cmp eax, 0x20544547         ; GET
    je .call_get
    cmp eax, 0x54534F50         ; POST
    je .call_set
    call handle_del
    jmp .handled

.call_get:
    call handle_get
    jmp .handled
.call_set:
    call handle_set
    jmp .handled
.call_scan:
    mov rdi, r12
    mov rsi, r13
    call handle_scan
    jmp .handled

.security_abort:
    ; Important: use the Socket FD in R12 to send the error
    mov rdi, r12
    call handle_404
    jmp .handled

.err_400:
    mov rdi, r12
    call handle_400
    jmp .handled

.handled:
    mov rax, 1
    pop rbx
    ret

.not_handled:
    xor rax, rax
    pop rbx
    ret