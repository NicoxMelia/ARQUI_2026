#-----------------------------------------------------------------------------
# create_project.tcl - Arma el proyecto de Vivado del TP2
#
# Uso:
#   1) Abrir Vivado
#   2) Tools > Run Tcl Script...  y elegir este archivo
#      (o desde consola:  vivado -mode batch -source create_project.tcl)
#
# Genera el proyecto en  TP2/vivado/TP2.xpr  con todas las fuentes, el
# testbench y el .xdc ya agregados y el top seteado.
#-----------------------------------------------------------------------------

set project_name "TP2"
set part_name    "xc7a35tcpg236-1"   ;# Basys 3 - Artix-7

set origin_dir [file dirname [file normalize [info script]]]
set proj_dir   "$origin_dir/vivado"

create_project $project_name $proj_dir -part $part_name -force

# --- Fuentes de diseno ---
add_files -fileset sources_1 [glob $origin_dir/src/*.v]

# --- Constraints ---
add_files -fileset constrs_1 "$origin_dir/constrs/constraints.xdc"

# --- Simulacion ---
add_files -fileset sim_1 [glob $origin_dir/sim/*.v]

# --- Tops ---
set_property top top_uart_alu    [get_filesets sources_1]
set_property top top_uart_alu_tb [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts ""
puts "==================================================================="
puts " Proyecto creado en: $proj_dir/$project_name.xpr"
puts " Top de sintesis   : top_uart_alu"
puts " Top de simulacion : top_uart_alu_tb"
puts "==================================================================="
