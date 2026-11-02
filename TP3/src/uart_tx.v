`timescale 1ns / 1ps

// Transmisor UART (Maquina de Moore)
// Estados: IDLE, START, DATA, STOP


module uart_tx
#(
    parameter DBIT    = 8,
    parameter SB_TICK = 16
)
(
    input  wire             clk,
    input  wire             reset,          // activo en alto
    input  wire             tx_start,       // hace el pedido de transmision
    input  wire             s_tick,         // tick de 16x baud
    input  wire [DBIT-1:0]  din,            // byte a transmitir
    output reg              tx_done_tick,   // pulso de 1 ciclo -> byte enviado
    output wire             tx              
);

    localparam [3:0] IDLE  = 4'b0001,
                     START = 4'b0010,
                     DATA  = 4'b0100,
                     STOP  = 4'b1000;

    reg [3:0]      state_reg,  state_next;
    reg [4:0]      s_reg,      s_next;
    reg [3:0]      n_reg,      n_next;
    reg [DBIT-1:0] b_reg,      b_next;
    reg            tx_reg,     tx_next;

    always @(posedge clk) begin
        if (reset) begin
            state_reg <= IDLE;
            s_reg     <= 5'b0;
            n_reg     <= 4'b0;
            b_reg     <= {DBIT{1'b0}};
            tx_reg    <= 1'b1;          // linea en reposo = 1
        end
        else begin
            state_reg <= state_next;
            s_reg     <= s_next;
            n_reg     <= n_next;
            b_reg     <= b_next;
            tx_reg    <= tx_next;
        end
    end

    always @(*) begin
        state_next   = state_reg;
        s_next       = s_reg;
        n_next       = n_reg;
        b_next       = b_reg;
        tx_next      = tx_reg;
        tx_done_tick = 1'b0;

        case (state_reg)
            IDLE: begin
                tx_next = 1'b1;
                if (tx_start) begin
                    state_next = START;
                    s_next     = 5'b0;
                    b_next     = din;       // captura el dato
                end
            end

            START: begin
                tx_next = 1'b0;             // bit de start
                if (s_tick) begin
                    if (s_reg == 5'd15) begin
                        state_next = DATA;
                        s_next     = 5'b0;
                        n_next     = 4'b0;
                    end
                    else
                        s_next = s_reg + 1'b1;
                end
            end

            DATA: begin
                tx_next = b_reg[0];         // LSB primero
                if (s_tick) begin
                    if (s_reg == 5'd15) begin
                        s_next = 5'b0;
                        b_next = b_reg >> 1;
                        if (n_reg == (DBIT - 1))
                            state_next = STOP;
                        else
                            n_next = n_reg + 1'b1;
                    end
                    else
                        s_next = s_reg + 1'b1;
                end
            end

            STOP: begin
                tx_next = 1'b1;             // bit de stop
                if (s_tick) begin
                    if (s_reg == (SB_TICK - 1)) begin
                        state_next   = IDLE;
                        tx_done_tick = 1'b1;
                    end
                    else
                        s_next = s_reg + 1'b1;
                end
            end

            default: begin                  // Recuperacion ante fallos
                state_next = IDLE;
                tx_next    = 1'b1;
            end
        endcase
    end

    assign tx = tx_reg;

endmodule
