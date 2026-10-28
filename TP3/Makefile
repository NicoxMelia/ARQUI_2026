# Simulacion con Icarus Verilog (iverilog -g2005, como en TP2)
#
#   make sim TB=alu_tb     compila src/*.v + sim/alu_tb.v y lo corre
#   make test              corre todos los testbenches de sim/ y falla si
#                          alguno no imprime "TEST PASSED: 0 errores"
#   make list              lista los testbenches disponibles
#   make vivado-only       lista los archivos que solo se prueban en Vivado
#   make clean             borra build/
#
# Cada testbench vive en sim/<nombre>.v y su modulo top se llama <nombre>.
# vvp corre desde TP3/, asi que $readmemh("programs/x.hex") funciona igual
# que en xsim con rutas relativas a la carpeta del TP.
#
# Archivos que Icarus no puede compilar (IP de Xilinx, primitivas, etc.):
# marcarlos con un comentario en cualquier linea
#     // REQUIERE_VIVADO: <motivo>
# Los de src/ se excluyen de la compilacion y los de sim/ se saltean en
# `make test`. Se informan aparte para que alguien los corra en Vivado.

IVERILOG ?= iverilog
VVP      ?= vvp
FLAGS    := -g2005 -Wall

BUILD    := build
MARK     := REQUIERE_VIVADO
VIV_ONLY := $(shell grep -l "$(MARK):" src/*.v sim/*.v 2>/dev/null)
SRCS     := $(filter-out $(VIV_ONLY),$(wildcard src/*.v))
TBS      := $(basename $(notdir $(wildcard sim/*.v)))

.PHONY: sim test list vivado-only clean

sim:
ifndef TB
	$(error Falta TB. Uso: make sim TB=<testbench>. Disponibles: $(TBS))
endif
	@if grep -q "$(MARK):" sim/$(TB).v; then \
		echo "$(TB) requiere Vivado: $$(grep -m1 -o '$(MARK):.*' sim/$(TB).v | cut -d: -f2- | sed 's/^ *//')"; \
		exit 1; \
	fi
	@mkdir -p $(BUILD)
	$(IVERILOG) $(FLAGS) -s $(TB) -o $(BUILD)/$(TB).out $(SRCS) sim/$(TB).v
	$(VVP) -n $(BUILD)/$(TB).out

test:
	@mkdir -p $(BUILD)
	@ok=0; fail=0; skip=0; \
	: > $(BUILD)/resumen.md; \
	for tb in $(TBS); do \
		printf '%-30s ' "$$tb"; \
		if grep -q "$(MARK):" sim/$$tb.v; then \
			why=$$(grep -m1 -o '$(MARK):.*' sim/$$tb.v | cut -d: -f2- | sed 's/^ *//'); \
			echo "REQUIERE VIVADO ($$why)"; skip=$$((skip+1)); \
			echo "| \`$$tb\` | :warning: requiere Vivado | $$why |" >> $(BUILD)/resumen.md; \
		elif $(IVERILOG) $(FLAGS) -s $$tb -o $(BUILD)/$$tb.out $(SRCS) sim/$$tb.v > $(BUILD)/$$tb.log 2>&1 && \
		   $(VVP) -n $(BUILD)/$$tb.out >> $(BUILD)/$$tb.log 2>&1 && \
		   grep -q "TEST PASSED: 0 errores" $(BUILD)/$$tb.log; then \
			echo "OK"; ok=$$((ok+1)); \
			echo "| \`$$tb\` | :white_check_mark: OK | |" >> $(BUILD)/resumen.md; \
		else \
			echo "FALLA (ver $(BUILD)/$$tb.log)"; fail=$$((fail+1)); \
			echo "| \`$$tb\` | :x: FALLA | ver log del job |" >> $(BUILD)/resumen.md; \
		fi; \
	done; \
	for f in $(filter src/%,$(VIV_ONLY)); do \
		why=$$(grep -m1 -o '$(MARK):.*' $$f | cut -d: -f2- | sed 's/^ *//'); \
		echo "| \`$$f\` | :warning: excluido de Icarus | $$why |" >> $(BUILD)/resumen.md; \
	done; \
	echo; \
	echo "OK: $$ok   FALLA: $$fail   REQUIERE VIVADO: $$skip   (fuentes excluidas: $(words $(filter src/%,$(VIV_ONLY))))"; \
	exit $$((fail > 0))

list:
	@echo $(TBS)

vivado-only:
	@for f in $(VIV_ONLY); do \
		echo "$$f: $$(grep -m1 -o '$(MARK):.*' $$f | cut -d: -f2- | sed 's/^ *//')"; \
	done

clean:
	rm -rf $(BUILD)
