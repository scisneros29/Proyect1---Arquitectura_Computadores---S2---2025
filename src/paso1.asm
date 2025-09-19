;nasm -f elf64 -g -F dwarf -o paso1.o paso1.asm
;ld -m elf_x86_64 -o paso1 paso1.o
;./paso1

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; PASO 1 — Leer y procesar config.ini
; Lee:
;   caracter_barra:<utf8>
;   color_barra:<decimal>
;   color_fondo:<decimal>
; Aplica defaults si faltan y muestra los valores detectados.
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Números de syscall (Linux x86-64)
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_OPEN    2
%define SYS_CLOSE   3
%define SYS_EXIT   60

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Banderas de open(2)
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
%define O_RDONLY    0

section .data
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Nombre del archivo de config
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    fname_config        db "config.ini", 0

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Palabras que se buscarán (incluye los dos puntos ':')
    ; Con lengths calculadas
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    key_bar_char:       db "caracter_barra:"
    key_bar_char_len    equ $ - key_bar_char

    key_color_bar:      db "color_barra:"
    key_color_bar_len   equ $ - key_color_bar

    key_color_bg:       db "color_fondo:"
    key_color_bg_len    equ $ - key_color_bg

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Mensajes para mostrar en consola
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    msg_ok1             db "caracter_barra:'"
    msg_ok1_len         equ $ - msg_ok1

    msg_ok2             db "'", 10, "color_barra:"
    msg_ok2_len         equ $ - msg_ok2

    msg_ok3             db 10, "color_fondo:"
    msg_ok3_len         equ $ - msg_ok3

    msg_nl              db 10
    msg_nl_len          equ $ - msg_nl

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Mensajes de error
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    msg_err_open        db "No pude abrir config.ini",10
    msg_err_open_len    equ $ - msg_err_open

    msg_err_read        db "No pude leer config.ini",10
    msg_err_read_len    equ $ - msg_err_read

section .bss
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Apartamos tamaño de buffer donde cargamos el archivo config.ini
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    config_buf      resb 2048
    config_len      resq 1          ; bytes válidos leídos

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Variables de configuración parseadas
    ; - bar_bytes: hasta 8 bytes para 1 "carácter" (UTF-8 o ASCII)
    ; - bar_len:   longitud del carácter (en bytes)
    ; - color_barra / color_fondo: códigos ANSI (p. ej., 92, 40)
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    bar_bytes       resb 8
    bar_len         resd 1
    color_barra     resd 1
    color_fondo     resd 1

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Buffer para convertir enteros a decimal en texto
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    num_buf         resb 16
    num_len         resd 1

section .text
global _start

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; write_stdout
;   Escribe en STDOUT el buffer [RSI .. RSI+RDX)
;   Convención:
;     IN: RSI = puntero, RDX = longitud
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
write_stdout:
    mov rax, SYS_WRITE
    mov rdi, 1                    ; fd=STDOUT
    syscall
    ret

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; u32_to_dec
;   Convierte EAX (u32) a decimal ASCII.
;   Devuelve:
;     RSI -> puntero al inicio del texto en num_buf
;     RDX = longitud del texto
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
u32_to_dec:
    push rbx
    push rcx
    mov rcx, 0                    ; contador de dígitos
    mov rbx, 10
    lea rdi, [num_buf + 15]       ; cursor al final del buffer
    mov byte [rdi], 0             ; finalizador
    dec rdi
    cmp eax, 0
    jne .u_loop
    ; caso de tener un 0
    mov byte [rdi], '0'
    mov rcx, 1
    jmp .u_done
.u_loop:
    xor rdx, rdx                  ; preparar 64/32 div: RDX:RAX / RBX
    div rbx                       ; RAX=quo, RDX=rest
    add dl, '0'                   ; resto -> dígito ascii
    mov [rdi], dl                 ; escribir desde el final
    dec rdi
    inc rcx
    test eax, eax                 ; ¿quedan más dígitos?
    jnz .u_loop
.u_done:
    inc rdi                       ; avanzar al primer dígito
    mov rsi, rdi                  ; RSI -> inicio de la cadena
    mov edx, ecx                  ; RDX = longitud
    mov [num_len], edx
    pop rcx
    pop rbx
    ret

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; skip_spaces
;   Avanza RAX sobre espacios y tabuladores.
;   Devuelve: RAX apuntando al primer no-espacio.
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
skip_spaces:
.ss_next:
    mov bl, [rax]
    cmp bl, ' '
    je .ss_adv
    cmp bl, 9                     ; tab
    je .ss_adv
    ret
.ss_adv:
    inc rax
    jmp .ss_next

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; read_bar_token
;   Copia el "caracter_barra" desde RAX hasta fin de línea
;   (detiene en '\n' o '\r'), máximo 8 bytes (soporta UTF-8).
;   Guarda bar_bytes[] y bar_len.
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
read_bar_token:
    push rcx
    push rsi
    push rdi
    mov rsi, rax                  ; cursor de lectura
    lea rdi, [bar_bytes]          ; destino
    xor rcx, rcx                  ; contador de bytes copiados
.rbt_copy:
    mov al, [rsi]
    cmp al, 10                    ; '\n'
    je .rbt_done
    cmp al, 13                    ; '\r'
    je .rbt_done
    cmp ecx, 8                    ; límite de 8 bytes
    jae .rbt_done
    mov [rdi + rcx], al           ; copiar byte
    inc rcx
    inc rsi
    jmp .rbt_copy
.rbt_done:
    mov [bar_len], ecx
    pop rdi
    pop rsi
    pop rcx
    ret

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; _start — flujo principal: ==============================================================
;   1) Defaults
;   2) Abrir/leer/cerrar config.ini
;   3) Buscar y parsear cada clave
;   4) Imprimir resultados de verificación
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
_start:
    ; ------------------------
    ; 1) Valores por defecto (si no se detecta ninguna clave)
    ; ------------------------
    mov dword [color_barra], 92   ; texto verde brillante
    mov dword [color_fondo], 40   ; fondo negro
    mov dword [bar_len], 1
    mov byte  [bar_bytes], '*'    ; '*' por defecto

    ; ------------------------
    ; 2) Abrir config.ini (SYS_OPEN)
    ; ------------------------
    mov rax, SYS_OPEN
    mov rdi, fname_config
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl  .err_open
    mov r12, rax                  ; fd

    ; Leer config.ini (SYS_READ)
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [config_buf]
    mov rdx, 2048
    syscall
    cmp rax, 0
    jle .err_read
    mov [config_len], rax

    ; Cerrar fd (SYS_CLOSE)
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    ; ------------------------
    ; Punteros y longitudes útiles
    ; ------------------------
    lea r8,  [config_buf]         ; r8 = buf
    mov r9,  [config_len]         ; r9 = len

; ====== BÚSQUEDA LÍNEA 1: "caracter_barra:" 
    lea r10, [key_bar_char]       ; r10 = key ptr
    mov r11, key_bar_char_len     ; r11 = key len
    xor rbx, rbx                  ; i = 0 (índice en buf)

.cb_search_i:
    ; ¿cabe la clave completa desde i?
    cmp rbx, r9
    jae .cb_not_found
    mov rax, rbx
    add rax, r11
    cmp rax, r9
    ja  .cb_not_found

    xor rcx, rcx                  ; j = 0
.cb_search_j:
    cmp rcx, r11
    je  .cb_found                 ; coincidió toda la clave
    ; comparar buf[i+j] con key[j]
    mov rax, rbx
    add rax, rcx
    mov al, [r8 + rax]
    mov dl, [r10 + rcx]
    cmp al, dl
    jne .cb_next_i
    inc rcx
    jmp .cb_search_j

.cb_found:
    ; RAX = buf + i + key_len -> apunta al valor
    mov rax, rbx
    add rax, r11
    add rax, r8
    call skip_spaces              ; saltar espacios tras ':'
    call read_bar_token           ; copiar hasta fin de línea a bar_bytes/bar_len
    jmp .after_bar

.cb_next_i:
    inc rbx
    jmp .cb_search_i

.cb_not_found:
.after_bar:

; ====== BÚSQUEDA LÍNEA 2: "color_barra:" 
    lea r10, [key_color_bar]
    mov r11, key_color_bar_len
    xor rbx, rbx

.cbar_search_i:
    cmp rbx, r9
    jae .cbar_not_found
    mov rax, rbx
    add rax, r11
    cmp rax, r9
    ja  .cbar_not_found

    xor rcx, rcx
.cbar_search_j:
    cmp rcx, r11
    je  .cbar_found
    mov rax, rbx
    add rax, rcx
    mov al, [r8 + rax]
    mov dl, [r10 + rcx]
    cmp al, dl
    jne .cbar_next_i
    inc rcx
    jmp .cbar_search_j

.cbar_found:
    ; parsear entero decimal muy simple
    mov rax, rbx
    add rax, r11
    add rax, r8
    call skip_spaces
    mov rdi, rax
    xor eax, eax                  ; acumulador = 0
.cbar_parse:
    mov bl, [rdi]
    cmp bl, '0'
    jb  .cbar_store               ; si no es dígito -> fin
    cmp bl, '9'
    ja  .cbar_store
    imul eax, eax, 10
    movzx ebx, bl
    sub ebx, '0'
    add eax, ebx
    inc rdi
    jmp .cbar_parse
.cbar_store:
    mov [color_barra], eax
    jmp .after_cbar

.cbar_next_i:
    inc rbx
    jmp .cbar_search_i

.cbar_not_found:
.after_cbar:

; ====== BÚSQUEDA LÍNEA 3: "color_fondo:" 
    lea r10, [key_color_bg]
    mov r11, key_color_bg_len
    xor rbx, rbx

.cbg_search_i:
    cmp rbx, r9
    jae .cbg_not_found
    mov rax, rbx
    add rax, r11
    cmp rax, r9
    ja  .cbg_not_found

    xor rcx, rcx
.cbg_search_j:
    cmp rcx, r11
    je  .cbg_found
    mov rax, rbx
    add rax, rcx
    mov al, [r8 + rax]
    mov dl, [r10 + rcx]
    cmp al, dl
    jne .cbg_next_i
    inc rcx
    jmp .cbg_search_j

.cbg_found:
    mov rax, rbx
    add rax, r11
    add rax, r8
    call skip_spaces
    mov rdi, rax
    xor eax, eax
.cbg_parse:
    mov bl, [rdi]
    cmp bl, '0'
    jb  .cbg_store
    cmp bl, '9'
    ja  .cbg_store
    imul eax, eax, 10
    movzx ebx, bl
    sub ebx, '0'
    add eax, ebx
    inc rdi
    jmp .cbg_parse
.cbg_store:
    mov [color_fondo], eax
    jmp .after_cbg

.cbg_next_i:
    inc rbx
    jmp .cbg_search_i

.cbg_not_found:
.after_cbg:

    ; ------------------------
    ; 4) Mostrar los resultados parseados
    ; ------------------------

    ; "caracter_barra: '"
    mov rsi, msg_ok1
    mov rdx, msg_ok1_len
    call write_stdout

    ; el caracter (hasta bar_len bytes)
    lea rsi, [bar_bytes]
    mov edx, [bar_len]
    test edx, edx
    jz  .skip_char_print
    call write_stdout
.skip_char_print:

    ; "'\ncolor_barra: "
    mov rsi, msg_ok2
    mov rdx, msg_ok2_len
    call write_stdout

    ; número color_barra
    mov eax, [color_barra]
    call u32_to_dec
    call write_stdout

    ; "\ncolor_fondo: "
    mov rsi, msg_ok3
    mov rdx, msg_ok3_len
    call write_stdout

    ; número color_fondo
    mov eax, [color_fondo]
    call u32_to_dec
    call write_stdout

    ; salto final
    mov rsi, msg_nl
    mov rdx, msg_nl_len
    call write_stdout

    ; salir ok
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Rutinas de detección de errores
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.err_open:
    mov rsi, msg_err_open
    mov rdx, msg_err_open_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

.err_read:
    mov rsi, msg_err_read
    mov rdx, msg_err_read_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 2
    syscall
