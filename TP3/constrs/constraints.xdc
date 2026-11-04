## ==========================================================================
## TP3 - Pipeline RISC-V + Debug Unit   |   Basys 3 (Artix-7 XC7A35T-1CPG236C)
## ==========================================================================
## Pines de top_tp3 (INT-1, #19): clock, reset, UART y LEDs.

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

## LEDs
##   LD0..LD12 : estado de la FSM de la Debug Unit (one-hot)
##   LD13      : halted
##   LD14      : illegal
##   LD15      : pipeline_empty
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {o_led[0]}]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {o_led[1]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {o_led[2]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {o_led[3]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {o_led[4]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {o_led[5]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {o_led[6]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {o_led[7]}]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {o_led[8]}]
set_property -dict { PACKAGE_PIN V3  IOSTANDARD LVCMOS33 } [get_ports {o_led[9]}]
set_property -dict { PACKAGE_PIN W3  IOSTANDARD LVCMOS33 } [get_ports {o_led[10]}]
set_property -dict { PACKAGE_PIN U3  IOSTANDARD LVCMOS33 } [get_ports {o_led[11]}]
set_property -dict { PACKAGE_PIN P3  IOSTANDARD LVCMOS33 } [get_ports {o_led[12]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports {o_led[13]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports {o_led[14]}]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD LVCMOS33 } [get_ports {o_led[15]}]

## rx es asincronica al clock: pasa por un sincronizador de dos FF (en uart.v)
set_false_path -from [get_ports i_rx]
