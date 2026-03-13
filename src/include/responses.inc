; -----------------------------------------------------------------------------
; Module: src/include/responses.inc
; Project: La Roca Micro-KV
; Responsibility: Centralized HTTP response strings and local constants.
;                 Includes "Connection: close" to ensure socket drainage.
; -----------------------------------------------------------------------------

%ifndef RESPONSES_INC
%define RESPONSES_INC

section .data
    ; --- Success Responses (200 OK) ---

    ; POST/SET Success
    hdr_200_stored  db "HTTP/1.1 200 OK", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 6", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Stored"
    len_200_stored  equ $ - hdr_200_stored

    ; DELETE Success
    hdr_200_del     db "HTTP/1.1 200 OK", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 7", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Deleted"
    len_200_del     equ $ - hdr_200_del

    ; Health Check Success
    hdr_alive       db "HTTP/1.1 200 OK", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 5", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Alive"
    len_alive       equ $ - hdr_alive

    ; --- Client Error Responses (4xx) ---

    ; 400 Bad Request: Generic malformed request
    hdr_400         db "HTTP/1.1 400 Bad Request", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 11", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Bad Request"
    len_400         equ $ - hdr_400

    ; 404 Not Found: Key or Route not found
    hdr_404         db "HTTP/1.1 404 Not Found", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 9", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Not Found"
    len_404         equ $ - hdr_404

    ; 411 Length Required: Missing Content-Length
    msg_411         db "HTTP/1.1 411 Length Required", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 15", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Length Required"
    len_411         equ $ - msg_411

    ; 413 Payload Too Large: Exceeds VAL_MAX_SIZE (Required for Test 15)
    msg_413         db "HTTP/1.1 413 Payload Too Large", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 17", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Payload too large"
    len_413         equ $ - msg_413

    ; --- Server Error Responses (5xx) ---

    ; 507 Insufficient Storage: Shard Full
    hdr_507         db "HTTP/1.1 507 Insufficient Storage", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Length: 10", 0x0D, 0x0A, 0x0D, 0x0A
                    db "Shard Full"
    len_507         equ $ - hdr_507

    ; --- Dynamic Elements (GET/SCAN) ---

    ; Start of a GET response (Content-Length value added at runtime)
    hdr_200_dyn     db "HTTP/1.1 200 OK", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A
                    db "Content-Type: application/octet-stream", 0x0D, 0x0A
                    db "Content-Length: "
    len_200_dyn     equ $ - hdr_200_dyn

    ; Header/Body separator
    hdr_crlf_crlf   db 0x0D, 0x0A, 0x0D, 0x0A
    len_crlf_crlf   equ $ - hdr_crlf_crlf

    hdr_scan_ok     db "HTTP/1.1 200 OK", 0x0D, 0x0A
                    db "Content-Type: text/plain", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A, 0x0D, 0x0A
    len_scan_ok     equ $ - hdr_scan_ok

    hdr_200_json    db "HTTP/1.1 200 OK", 0x0D, 0x0A
                    db "Content-Type: application/json", 0x0D, 0x0A
                    db "Connection: close", 0x0D, 0x0A, 0x0D, 0x0A
    len_200_json    equ $ - hdr_200_json

%endif