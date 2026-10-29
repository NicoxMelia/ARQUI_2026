`timescale 1ns / 1ps
// Receptor UART (Maquina de MOORE)
// Secuencia de estados: IDLE, START, DATA, STOP

// Cambios respecto de TP2:
//  - En el medio del bit de start se vuelve a mirar la linea: si ya volvio a 1
//    era un glitch y se vuelve a IDLE sin recibir nada.
//  - En el medio del bit de stop se verifica que la linea este en 1. Si esta en 0
//    el byte se descarta (no hay rx_done_tick) y se da un pulso en frame_err_tick.
//  - El start se detecta por flanco de bajada (1 -> 0) y no por nivel. Despues de
//    un error de trama la linea sigue en 0 hasta el final del stop; por nivel se
//    tomaria eso como un start nuevo y el receptor quedaria desincronizado.

module uart_rx
#(
    parameter DBIT    = 8,      // bits de datos
    parameter SB_TICK = 16      // ticks de stop
)
(
    input  wire                 clk,
    input  wire                 reset,          // activo en alto
    input  wire                 rx,
    input  wire                 s_tick,         // tick de 16x baud
    output reg                  rx_done_tick,   // pulso de 1 ciclo: indica que esta el byte listo
    output reg                  frame_err_tick, // pulso de 1 ciclo: el bit de stop llego en 0
    output wire [DBIT-1:0]      dout            // byte recibido
);

    // Codificacion one-hot
    localparam [3:0] IDLE  = 4'b0001,
                     START = 4'b0010,
                     DATA  = 4'b0100,
                     STOP  = 4'b1000;

    reg [3:0]      state_reg,  state_next;
    reg [4:0]      s_reg,      s_next;     // contador de ticks (desde 0 hacia 31)
    reg [3:0]      n_reg,      n_next;     // contador de bits de datos
    reg [DBIT-1:0] b_reg,      b_next;     // shift register
    reg            rx_prev;                // rx del ciclo anterior (flanco de start)

    // Registros de estado (memoria)
    always @(posedge clk) begin
        if (reset) begin
            state_reg <= IDLE;
            s_reg     <= 5'b0;
            n_reg     <= 4'b0;
            b_reg     <= {DBIT{1'b0}};
            rx_prev   <= 1'b1;
        end
        else begin
            state_reg <= state_next;
            s_reg     <= s_next;
            n_reg     <= n_next;
            b_reg     <= b_next;
            rx_prev   <= rx;
        end
    end

    // Logica de proximo estado y de salida
    always @(*) begin
        // Valores por defecto para evitar latches
        state_next     = state_reg;
        s_next         = s_reg;
        n_next         = n_reg;
        b_next         = b_reg;
        rx_done_tick   = 1'b0;
        frame_err_tick = 1'b0;

        case (state_reg)
            IDLE: begin
                if (rx_prev & ~rx) begin    // flanco de bajada -> bit de start
                    state_next = START;
                    s_next     = 5'b0;
                end
            end

            START: begin
                if (s_tick) begin
                    if (s_reg == 5'd7) begin    // medio del bit de start
                        if (rx)                     // la linea volvio a 1: era un glitch
                            state_next = IDLE;
                        else begin
                            state_next = DATA;
                            s_next     = 5'b0;
                            n_next     = 4'b0;
                        end
                    end
                    else
                        s_next = s_reg + 1'b1;
                end
            end

            DATA: begin
                if (s_tick) begin
                    if (s_reg == 5'd15) begin   // medio del bit de datos
                        s_next = 5'b0;
                        b_next = {rx, b_reg[DBIT-1:1]};  // LSB primero
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
                if (s_tick) begin
                    if (s_reg == (SB_TICK - 1)) begin   // medio del bit de stop
                        state_next = IDLE;
                        if (rx)
                            rx_done_tick   = 1'b1;
                        else
                            frame_err_tick = 1'b1;      // stop en 0: error de trama
                    end
                    else
                        s_next = s_reg + 1'b1;
                end
            end

            // si cae a un estado invalido vuelve al estado idle
            default: state_next = IDLE;
        endcase
    end

    assign dout = b_reg;

endmodule
