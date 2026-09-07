module top_alu
#(
    parameter NB_SWITCH = 8,
    parameter NB_RESULT = NB_SWITCH + 1,
    parameter NB_OP     = 6
)
(
    input  wire                   clk,
    input  wire [NB_SWITCH-1:0]   i_sw,
    input  wire                   btn_0,       // Dato A (Central)
    input  wire                   btn_1,       // Dato B (Arriba)
    input  wire                   btn_2,       // Operacion (Izquierdo)
    input  wire                   btn_clear,   // NUEVO: Clear (Derecho)
    output wire [NB_RESULT-1:0]   o_leds
);

    reg  [NB_SWITCH-1:0] reg_data_a;
    reg  [NB_SWITCH-1:0] reg_data_b;
    reg  [NB_OP-1:0]     reg_op;

    reg flag_a  = 1'b0;
    reg flag_b  = 1'b0;
    reg flag_op = 1'b0;

    wire [NB_SWITCH-1:0] alu_result;
    wire                 alu_carry;

    // --- Lógica secuencial con Reset (Clear) ---
    always @(posedge clk) begin
        if (btn_clear) begin
            // Si se aprieta Clear, borramos los datos y bajamos las banderas
            reg_data_a <= {NB_SWITCH{1'b0}};
            reg_data_b <= {NB_SWITCH{1'b0}};
            reg_op     <= {NB_OP{1'b0}};
            flag_a     <= 1'b0;
            flag_b     <= 1'b0;
            flag_op    <= 1'b0;
        end 
        else begin
            // Si no hay Clear, el sistema funciona normal
            if (btn_0) begin
                reg_data_a <= i_sw;
                flag_a     <= 1'b1;
            end

            if (btn_1) begin
                reg_data_b <= i_sw;
                flag_b     <= 1'b1;
            end

            if (btn_2) begin
                reg_op  <= i_sw[NB_OP-1:0];
                flag_op <= 1'b1;
            end
        end
    end

    // Instanciación de la ALU (se mantiene igual)
    ALU #(
        .N_BITS(NB_SWITCH),
        .N_OP  (NB_OP)
    )
    u_alu
    (
        .in_a    (reg_data_a),
        .in_b    (reg_data_b),
        .in_op   (reg_op),
        .o_result(alu_result),
        .o_carry (alu_carry)
    );

    // Condición de salida a los LEDs
    assign o_leds = (flag_a & flag_b & flag_op) ? {alu_carry, alu_result} : {NB_RESULT{1'b0}};

endmodule