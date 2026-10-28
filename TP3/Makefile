# Simulacion con Icarus Verilog (iverilog -g2005, como en TP2)
#
#   make sim TB=alu_tb     compila src/*.v + sim/alu_tb.v y lo corre
#   make test              corre todos los testbenches de sim/ y falla si
#                          alguno no imprime "TEST PASSED: 0 errores"
#   make list              lista los testbenches disponibles
#   make clean             borra build/
#
# Cada testbench vive en sim/<nombre>.v y su modulo top se llama <nombre>.
# vvp corre desde TP3/, asi que $readmemh("programs/x.hex") funciona igual
# que en xsim con rutas relativas a la carpeta del TP.

IVERILOG ?= iverilog
VVP      ?= vvp
FLAGS    := -g2005 -Wall

BUILD    := build
SRCS     := $(wildcard src/*.v)
TBS      := $(basename $(notdir $(wildcard sim/*.v)))

.PHONY: sim test list clean

sim:
ifndef TB
	$(error Falta TB. Uso: make sim TB=<testbench>. Disponibles: $(TBS))
endif
	@mkdir -p $(BUILD)
	$(IVERILOG) $(FLAGS) -s $(TB) -o $(BUILD)/$(TB).out $(SRCS) sim/$(TB).v
	$(VVP) -n $(BUILD)/$(TB).out

test:
	@mkdir -p $(BUILD)
	@fail=0; \
	for tb in $(TBS); do \
		printf '%-30s ' "$$tb"; \
		if $(IVERILOG) $(FLAGS) -s $$tb -o $(BUILD)/$$tb.out $(SRCS) sim/$$tb.v > $(BUILD)/$$tb.log 2>&1 && \
		   $(VVP) -n $(BUILD)/$$tb.out >> $(BUILD)/$$tb.log 2>&1 && \
		   grep -q "TEST PASSED: 0 errores" $(BUILD)/$$tb.log; then \
			echo "OK"; \
		else \
			echo "FALLA (ver $(BUILD)/$$tb.log)"; fail=1; \
		fi; \
	done; \
	exit $$fail

list:
	@echo $(TBS)

clean:
	rm -rf $(BUILD)
