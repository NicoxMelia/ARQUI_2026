## ==========================================================================
## TP3 - Pipeline RISC-V + Debug Unit   |   Basys 3 (Artix-7 XC7A35T-1CPG236C)
## ==========================================================================
## Base minima (clock, reset y UART). Los LEDs y demas pines se agregan en
## INT-1 (#19) junto con el top definitivo.

## Reloj de 100 MHz
set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.000 -waveform {0.000 5.000} [get_ports clk]

## Boton central: reset general
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports i_reset]

## Puente USB-UART (FT2232HQ)
##   i_rx : dato que llega de la PC a la FPGA  (RsRx)
##   o_tx : dato que sale de la FPGA a la PC   (RsTx)
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports i_rx]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports o_tx]

## rx es asincronica al clock: pasa por un sincronizador de dos FF
set_false_path -from [get_ports i_rx]
