#-----------------------------------------------------------------------------
# create_project.tcl - Arma el proyecto de Vivado del TP3
#
# Uso:
#   1) Abrir Vivado
#   2) Tools > Run Tcl Script...  y elegir este archivo
#      (o desde consola:  vivado -mode batch -source create_project.tcl)
#
# Genera el proyecto en  TP3/vivado/TP3.xpr  con todas las fuentes, los
# testbenches y el .xdc ya agregados y los tops seteados.
# El proyecto de Vivado no se versiona: se regenera con este script.
#-----------------------------------------------------------------------------

set project_name "TP3"
set part_name    "xc7a35tcpg236-1"   ;# Basys 3 - Artix-7

# Tops (se fijan en INT-1, #19)
set top_synth "top_tp3"
set top_sim   "top_tp3_tb"

set origin_dir [file dirname [file normalize [info script]]]
set proj_dir   "$origin_dir/vivado"

create_project $project_name $proj_dir -part $part_name -force

# --- Fuentes de diseno ---
set src_files [glob -nocomplain $origin_dir/src/*.v]
if {[llength $src_files] > 0} {
    add_files -fileset sources_1 $src_files
}

# --- Archivos de inicializacion de memoria (programas en .hex) ---
set hex_files [glob -nocomplain $origin_dir/programs/*.hex]
if {[llength $hex_files] > 0} {
    add_files -fileset sources_1 $hex_files
}

# --- Constraints ---
add_files -fileset constrs_1 "$origin_dir/constrs/constraints.xdc"

# --- Simulacion ---
set sim_files [glob -nocomplain $origin_dir/sim/*.v]
if {[llength $sim_files] > 0} {
    add_files -fileset sim_1 $sim_files
}

# --- Tops (solo si ya existen los modulos) ---
if {[file exists "$origin_dir/src/$top_synth.v"]} {
    set_property top $top_synth [get_filesets sources_1]
}
if {[file exists "$origin_dir/sim/$top_sim.v"]} {
    set_property top $top_sim [get_filesets sim_1]
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts ""
puts "==================================================================="
puts " Proyecto creado en: $proj_dir/$project_name.xpr"
puts " Top de sintesis   : [get_property top [get_filesets sources_1]]"
puts " Top de simulacion : [get_property top [get_filesets sim_1]]"
puts "==================================================================="
