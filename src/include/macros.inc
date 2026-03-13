; -----------------------------------------------------------------------------
; Macro: DEBUG_LOG
; Responsibility: Prints a static string to STDOUT (Docker Logs)
; -----------------------------------------------------------------------------
%macro DEBUG_LOG 2
    push rax
    push rdi
    push rsi
    push rdx
    mov rax, 1          ; sys_write
    mov rdi, 1          ; STDOUT (FD 1)
    lea rsi, [%%msg]
    mov rdx, %%len
    syscall
    pop rdx
    pop rsi
    pop rdi
    pop rax

    section .data
        %%msg db %1, 0x0A ; Agregamos un newline
        %%len equ $ - %%msg
    section .text
%endmacro