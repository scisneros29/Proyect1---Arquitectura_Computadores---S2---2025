;nasm -f elf64 -g -F dwarf -o paso2.o paso2.asm
;ld -m elf_x86_64 -o paso2 paso2.o
;./paso2


; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; PASO 1+2 — Versión “novato”
;  - Paso 1: Leer y procesar config.ini
;  - Paso 2: Leer y procesar inventario.txt y almacenar en memoria
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Números de syscall (Linux x86-64)
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Banderas de open(2)
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
%define O_RDONLY   0

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Límite de ítems aceptados del inventario
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
%define MAX_ITEMS  128

section .data
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Nombres de archivos
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    fname_config        db "config.ini", 0
    fname_invent        db "Inventario.txt", 0

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Claves a buscar en config.ini (incluyen ':')
    ; y sus longitudes calculadas
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    key_bar_char:       db "caracter_barra:"
    key_bar_char_len    equ $ - key_bar_char

    key_color_bar:      db "color_barra:"
    key_color_bar_len   equ $ - key_color_bar

    key_color_bg:       db "color_fondo:"
    key_color_bg_len    equ $ - key_color_bg

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Mensajes de verificación para CONFIG
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    msg_ok1             db "caracter_barra: '"
    msg_ok1_len         equ $ - msg_ok1
    msg_ok2             db "'", 10, "color_barra: "
    msg_ok2_len         equ $ - msg_ok2
    msg_ok3             db 10, "color_fondo: "
    msg_ok3_len         equ $ - msg_ok3
    msg_nl              db 10
    msg_nl_len          equ $ - msg_nl

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Mensajes de error (CONFIG)
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    msg_err_open        db "No pude abrir config.ini",10
    msg_err_open_len    equ $ - msg_err_open
    msg_err_read        db "No pude leer config.ini",10
    msg_err_read_len    equ $ - msg_err_read

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Mensajes de verificación / error (INVENTARIO)
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    msg_inv_ok          db "INVENTARIO OK",10
    msg_inv_ok_len      equ $ - msg_inv_ok
    msg_items           db "items=",0
    msg_items_len       equ $ - msg_items - 1
    msg_colonsp         db ": "
    msg_colonsp_len     equ $ - msg_colonsp

    msg_err_open_inv    db "No pude abrir inventario.txt",10
    msg_err_open_inv_len equ $ - msg_err_open_inv
    msg_err_read_inv    db "No pude leer inventario.txt",10
    msg_err_read_inv_len equ $ - msg_err_read_inv

section .bss
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Buffer y longitud para config.ini
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    config_buf      resb 2048
    config_len      resq 1

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Variables parseadas de CONFIG
    ;  - bar_bytes/bar_len: “caracter_barra” (hasta 8 bytes por UTF-8)
    ;  - color_barra / color_fondo: enteros decimales
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

    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Memoria para Inventario.txt
    ;  - inv_buf/inv_len: archivo completo
    ;  - Estructuras paralelas por ítem (ptr, len, qty)
    ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    inv_buf         resb 4096
    inv_len         resq 1
    inv_count       resd 1
    inv_name_ptrs   resq MAX_ITEMS
    inv_name_lens   resd MAX_ITEMS
    inv_qtys        resd MAX_ITEMS

section .text
global _start

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; write_stdout
;   Escribe en STDOUT el rango [RSI .. RSI+RDX)
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
write_stdout:
    mov rax, SYS_WRITE
    mov rdi, 1
    syscall
    ret

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; u32_to_dec
;   Convierte EAX (u32) a ASCII decimal.
;   Devuelve:
;     RSI -> puntero al texto en num_buf
;     RDX = longitud del texto
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
u32_to_dec:
    push rbx
    push rcx
    push rdx
    mov rcx, 0
    mov rbx, 10
    lea rdi, [rel num_buf + 15]
    mov byte [rdi], 0
    dec rdi
    cmp eax, 0
    jne .u_loop
    mov byte [rdi], '0'
    mov rcx, 1
    jmp .u_done
.u_loop:
    xor rdx, rdx
    div rbx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    inc rcx
    test eax, eax
    jnz .u_loop
.u_done:
    inc rdi
    mov rsi, rdi
    mov edx, ecx
    mov [rel num_len], edx
    pop rdx
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
    cmp bl, 9           ; '\t'
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
    mov rsi, rax
    lea rdi, [rel bar_bytes]
    xor ecx, ecx
.rbt_copy:
    mov al, [rsi]
    cmp al, 10
    je .rbt_done
    cmp al, 13
    je .rbt_done
    cmp ecx, 8
    jae .rbt_done
    mov [rdi + rcx], al
    inc ecx
    inc rsi
    jmp .rbt_copy
.rbt_done:
    mov [rel bar_len], ecx
    pop rdi
    pop rsi
    pop rcx
    ret

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; _start — Flujo principal
;   1) Defaults
;   2) Leer config.ini y parsear 3 claves
;   3) Mostrar verificación de CONFIG
;   4) Leer/parsear Inventario.txt a estructuras paralelas
;   5) Mostrar conteo e ítems “Nombre: Cantidad”
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
_start:
    ; ------------------------
    ; 1) Defaults de CONFIG
    ; ------------------------
    mov dword [rel color_barra], 92
    mov dword [rel color_fondo], 40
    mov dword [rel bar_len], 1
    mov byte  [rel bar_bytes], '*'

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;; PASO 1: CONFIG ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Abrir config.ini
    mov rax, SYS_OPEN
    lea rdi, [rel fname_config]
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .err_open
    mov r12, rax

    ; Leer config.ini a config_buf
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [rel config_buf]
    mov rdx, 2048
    syscall
    cmp rax, 0
    jle .err_read
    mov [rel config_len], rax

    ; Cerrar fd
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    ; Punteros útiles: r8=buf, r9=len
    lea r8,  [rel config_buf]
    mov r9,  [rel config_len]

    ; ------- buscar "caracter_barra:" -------
    lea r10, [rel key_bar_char]
    mov r11, key_bar_char_len
    xor rbx, rbx
.cb_search_i:
    cmp rbx, r9
    jae .cb_not_found
    mov rax, rbx
    add rax, r11
    cmp rax, r9
    ja  .cb_not_found
    xor rcx, rcx
.cb_search_j:
    cmp rcx, r11
    je  .cb_found
    mov rax, rbx
    add rax, rcx
    mov al, [r8 + rax]
    mov dl, [r10 + rcx]
    cmp al, dl
    jne .cb_next_i
    inc rcx
    jmp .cb_search_j
.cb_found:
    mov rax, rbx
    add rax, r11
    add rax, r8
    call skip_spaces
    call read_bar_token
    jmp .after_bar
.cb_next_i:
    inc rbx
    jmp .cb_search_i
.cb_not_found:
.after_bar:

    ; ------- buscar "color_barra:" -------
    lea r8,  [rel config_buf]
    mov r9,  [rel config_len]
    lea r10, [rel key_color_bar]
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
    mov rax, rbx
    add rax, r11
    add rax, r8
    call skip_spaces
    mov rdi, rax
    xor eax, eax
.cbar_parse:
    mov bl, [rdi]
    cmp bl, '0'
    jb .cbar_store
    cmp bl, '9'
    ja .cbar_store
    imul eax, eax, 10
    movzx ebx, bl
    sub ebx, '0'
    add eax, ebx
    inc rdi
    jmp .cbar_parse
.cbar_store:
    mov [rel color_barra], eax
    jmp .after_cbar
.cbar_next_i:
    inc rbx
    jmp .cbar_search_i
.cbar_not_found:
.after_cbar:

    ; ------- buscar "color_fondo:" -------
    lea r8,  [rel config_buf]
    mov r9,  [rel config_len]
    lea r10, [rel key_color_bg]
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
    jb .cbg_store
    cmp bl, '9'
    ja .cbg_store
    imul eax, eax, 10
    movzx ebx, bl
    sub ebx, '0'
    add eax, ebx
    inc rdi
    jmp .cbg_parse
.cbg_store:
    mov [rel color_fondo], eax
    jmp .after_cbg
.cbg_next_i:
    inc rbx
    jmp .cbg_search_i
.cbg_not_found:
.after_cbg:

    ; ------------------------
    ; Mostrar resultados de CONFIG
    ; ------------------------
    lea rsi, [rel msg_ok1]
    mov rdx, msg_ok1_len
    call write_stdout

    lea rsi, [rel bar_bytes]
    mov edx, [rel bar_len]
    test edx, edx
    jz .skip_char_print
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

; ;;;;;;;;;;;;;;;;;;;;;;;;; PASO 2: INVENTARIO ;;;;;;;;;;;;;;;;;;;;;;;;;
    ; Inicializar contador
    mov dword [rel inv_count], 0

    ; Abrir Inventario.txt
    mov rax, SYS_OPEN
    lea rdi, [rel fname_invent]
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .err_open_inv
    mov r13, rax

    ; Leer Inventario.txt a inv_buf
    mov rax, SYS_READ
    mov rdi, r13
    lea rsi, [rel inv_buf]
    mov rdx, 4096
    syscall
    cmp rax, 0
    jle .err_read_inv
    mov [rel inv_len], rax

    ; Cerrar fd
    mov rax, SYS_CLOSE
    mov rdi, r13
    syscall

    ; Parseo lineal: “Nombre: 123”
    lea rsi, [rel inv_buf]         ; cursor
    mov rdx, [rel inv_len]         ; bytes restantes
    lea r12, [rel inv_name_ptrs]   ; base nombres
    lea r14, [rel inv_name_lens]   ; base longitudes
    lea r15, [rel inv_qtys]        ; base cantidades

.inv_next_line:
    cmp rdx, 0
    jle .inv_done

    ; Saltar CR/LF/espacios/tabs iniciales
.inv_skip_ws:
    cmp rdx, 0
    jle .inv_done
    mov al, [rsi]
    cmp al, 10
    je  .inv_cons1
    cmp al, 13
    je  .inv_cons1
    cmp al, ' '
    je  .inv_cons1
    cmp al, 9
    je  .inv_cons1
    jmp .inv_key_start
.inv_cons1:
    inc rsi
    dec rdx
    jmp .inv_skip_ws

    ; Capturar nombre hasta ':'
.inv_key_start:
    mov r8, rsi
    xor r9, r9
.inv_scan_key:
    cmp rdx, 0
    jle .inv_done
    mov al, [rsi]
    cmp al, ':'
    je  .inv_key_end
    cmp al, 10
    je  .inv_line_skip
    cmp al, 13
    je  .inv_line_skip
    inc rsi
    inc r9
    dec rdx
    jmp .inv_scan_key

    ; Recorte de espacios finales del nombre
.inv_key_end:
    mov rcx, r9
    cmp rcx, 0
    je  .inv_after_colon
.inv_trim_tail:
    mov rax, r8
    add rax, rcx
    dec rax
    mov bl, [rax]
    cmp bl, ' '
    je  .inv_trim_dec
    cmp bl, 9
    je  .inv_trim_dec
    jmp .inv_trim_ok
.inv_trim_dec:
    dec rcx
    jmp .inv_trim_tail
.inv_trim_ok:

    ; Guardar puntero+longitud si hay espacio
    mov eax, [rel inv_count]
    cmp eax, MAX_ITEMS
    jae .inv_after_colon
    mov ebx, eax
    mov rax, r8
    mov [r12 + rbx*8], rax
    mov [r14 + rbx*4], ecx

    ; Saltar ':' y espacios posteriores
.inv_after_colon:
    inc rsi
    dec rdx
.inv_val_ws:
    cmp rdx, 0
    jle .inv_line_end
    mov al, [rsi]
    cmp al, ' '
    je  .inv_cons2
    cmp al, 9
    je  .inv_cons2
    jmp .inv_num
.inv_cons2:
    inc rsi
    dec rdx
    jmp .inv_val_ws

    ; Leer número (cantidad)
.inv_num:
    xor ebx, ebx
.inv_num_loop:
    cmp rdx, 0
    jle .inv_store
    mov al, [rsi]
    cmp al, 10
    je  .inv_store
    cmp al, 13
    je  .inv_store
    cmp al, '0'
    jb  .inv_store
    cmp al, '9'
    ja  .inv_store
    imul ebx, ebx, 10
    movzx eax, al
    sub eax, '0'
    add ebx, eax
    inc rsi
    dec rdx
    jmp .inv_num_loop

    ; Guardar cantidad e incrementar contador
.inv_store:
    mov eax, [rel inv_count]
    cmp eax, MAX_ITEMS
    jae .inv_line_end
    mov ecx, eax
    mov [r15 + rcx*4], ebx
    inc eax
    mov [rel inv_count], eax

    ; Avanzar hasta '\n'
.inv_line_end:
.inv_to_nl:
    cmp rdx, 0
    jle .inv_done
    mov al, [rsi]
    inc rsi
    dec rdx
    cmp al, 10
    jne .inv_to_nl
    jmp .inv_next_line

    ; Línea sin ':' → descartar hasta '\n'
.inv_line_skip:
.inv_skip_to_nl:
    cmp rdx, 0
    jle .inv_done
    mov al, [rsi]
    inc rsi
    dec rdx
    cmp al, 10
    jne .inv_skip_to_nl
    jmp .inv_next_line

; ---- Hasta aquí el parseo del inventario ----
.inv_done:
    ; Mostrar verificación básica imprimiendo en consoal
    lea rsi, [rel msg_inv_ok]
    mov rdx, msg_inv_ok_len
    call write_stdout

    lea rsi, [rel msg_items]
    mov rdx, msg_items_len
    call write_stdout

    mov eax, [rel inv_count]
    call u32_to_dec
    call write_stdout

    lea rsi, [rel msg_nl]
    mov rdx, msg_nl_len
    call write_stdout

    ; Listado “Nombre: Cantidad”
    lea r12, [rel inv_name_ptrs]
    lea r14, [rel inv_name_lens]
    lea r15, [rel inv_qtys]
    xor r8d, r8d
.inv_print_loop:
    mov eax, [rel inv_count]
    cmp r8d, eax
    jge .exit_ok

    ; Nombre
    mov rax, [r12 + r8*8]
    mov edx, [r14 + r8*4]
    mov rsi, rax
    call write_stdout

    ; ": "
    lea rsi, [rel msg_colonsp]
    mov rdx, msg_colonsp_len
    call write_stdout

    ; Cantidad
    mov eax, [r15 + r8*4]
    call u32_to_dec
    call write_stdout

    ; Nueva línea
    lea rsi, [rel msg_nl]
    mov rdx, msg_nl_len
    call write_stdout

    inc r8d
    jmp .inv_print_loop

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Salida OK
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
.exit_ok:
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Rutinas de detección de errores
; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;
.err_open:
    lea rsi, [rel msg_err_open]
    mov rdx, msg_err_open_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

.err_read:
    lea rsi, [rel msg_err_read]
    mov rdx, msg_err_read_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 2
    syscall

.err_open_inv:
    lea rsi, [rel msg_err_open_inv]
    mov rdx, msg_err_open_inv_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 3
    syscall

.err_read_inv:
    lea rsi, [rel msg_err_read_inv]
    mov rdx, msg_err_read_inv_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 4
    syscall
