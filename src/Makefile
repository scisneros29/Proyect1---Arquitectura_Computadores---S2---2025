# === Makefile para paso2.asm (NASM + ld) ===

# Herramientas
NASM    := nasm
LD      := ld

# Flags
NASMFLAGS := -f elf64 -g -F dwarf
LDFLAGS   := -m elf_x86_64

# Nombres
SRC   := paso3.asm
OBJ   := paso3.o
BIN   := paso3

# Regla por defecto: compilar, enlazar y ejecutar
.PHONY: all
all: run

# Compilar y enlazar
$(BIN): $(OBJ)
	$(LD) $(LDFLAGS) -o $(BIN) $(OBJ)

$(OBJ): $(SRC)
	$(NASM) $(NASMFLAGS) -o $(OBJ) $(SRC)

# Ejecutar el binario (depende de tenerlo listo)
.PHONY: run
run: $(BIN)
	./$(BIN)

# Limpiar artefactos
.PHONY: clean
clean:
	rm -f $(OBJ) $(BIN)