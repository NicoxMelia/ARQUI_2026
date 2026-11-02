# Arquitectura del datapath

Pipeline de 5 etapas (IF, ID, EX, MEM, WB) con forwarding, detección de riesgo load-use y flush de saltos. Los anchos y campos de los latches están en [`interfaz_core.md`](interfaz_core.md), sección 3.

```mermaid
flowchart LR
    subgraph IF["IF"]
        PC["PC"]
        ADD4["PC + 4"]
        MUXPC{"mux PC"}
        IMEM[("imem<br/>1024 x 32")]
    end
    IFID[/"IF/ID<br/>pc, instr"/]

    subgraph ID["ID"]
        DEC["Control<br/>(decodificador)"]
        IMM["Generador<br/>de inmediatos"]
        RF[("Banco de<br/>registros<br/>32 x 32")]
        HZ["Hazard unit<br/>(load-use)"]
    end
    IDEX[/"ID/EX<br/>pc, rs1_val, rs2_val, imm,<br/>rs1, rs2, rd, funct3, alu_op, ctrl"/]

    subgraph EX["EX"]
        FWD["Forwarding unit"]
        MUXA{"mux A"}
        MUXB{"mux B"}
        ALU["ALU"]
        BR["Comparador beq/bne<br/>+ PC + imm / rs1 + imm"]
    end
    EXMEM[/"EX/MEM<br/>alu_result, store_data,<br/>rd, funct3, ctrl"/]

    subgraph MEM["MEM"]
        DMEM[("dmem<br/>1024 x 32")]
    end
    MEMWB[/"MEM/WB<br/>rdata, alu_result,<br/>rd, funct3, ctrl"/]

    subgraph WB["WB"]
        EXT["Extensión lb/lh/lbu/lhu"]
        MUXWB{"mux WB"}
    end

    PC --> IMEM --> IFID
    PC --> ADD4 --> MUXPC --> PC
    IFID --> DEC
    IFID --> IMM
    IFID --> RF
    DEC --> IDEX
    IMM --> IDEX
    RF --> IDEX
    IFID --> HZ
    IDEX --> FWD
    IDEX --> MUXA --> ALU
    IDEX --> MUXB --> ALU
    IDEX --> BR
    ALU --> EXMEM
    ALU --> BR
    EXMEM --> DMEM
    EXMEM --> MEMWB
    DMEM --> MEMWB
    MEMWB --> EXT --> MUXWB
    MUXWB --> RF

    %% Forwarding: EX/MEM y MEM/WB hacia las entradas de EX
    EXMEM -. "fwd alu_result" .-> MUXA
    EXMEM -. "fwd alu_result" .-> MUXB
    MUXWB -. "fwd resultado WB" .-> MUXA
    MUXWB -. "fwd resultado WB" .-> MUXB
    FWD -. "selecciona" .-> MUXA
    FWD -. "selecciona" .-> MUXB

    %% Hazard unit: stall del PC e IF/ID, burbuja en ID/EX
    IDEX -. "mem_read, rd" .-> HZ
    HZ -. "stall" .-> PC
    HZ -. "stall" .-> IFID
    HZ -. "burbuja" .-> IDEX

    %% Saltos resueltos en EX (D5)
    BR -. "salto tomado: destino" .-> MUXPC
    BR -. "flush" .-> IFID
    BR -. "flush" .-> IDEX
```

## Resumen de las unidades de control

| Unidad | Entradas | Salidas | Regla |
|---|---|---|---|
| Forwarding | `rs1`, `rs2` de ID/EX; `rd` y `reg_write` de EX/MEM y MEM/WB | selectores de mux A y B (y de `store_data`) | Prioridad a EX/MEM sobre MEM/WB; nunca se forwardea `x0`. |
| Hazard (load-use) | `mem_read` y `rd` de ID/EX; `rs1`, `rs2` de la instrucción en ID | stall de PC e IF/ID, burbuja en ID/EX | Si la instrucción en EX es un load y su `rd` coincide con un operando de la que está en ID: 1 ciclo de stall. |
| Saltos | `branch`, `jal`, `jalr`, comparación en EX | `PC <- destino`, flush de IF/ID e ID/EX | Se resuelve en EX (D5): 2 instrucciones descartadas por salto tomado. |
| HALT | `ebreak` o ilegal en ID (no descartado) | `halted`/`illegal`, PC congelado | Las instrucciones anteriores terminan de drenar; `pipeline_empty` marca el final. |

El banco de registros resuelve internamente el caso escritura-lectura del mismo registro en el mismo ciclo (D6), por lo que no hace falta forwarding desde WB hacia ID.

## Control desde la Debug Unit

`ce` habilita PC, los cuatro latches, el banco de registros y las escrituras de la dmem; no hay ningún otro clock en el core (D1). Las lecturas de debug (`dbg_reg_*`, `dbg_dmem_*`) usan puertos aparte y la escritura de la imem entra por su propio puerto, ambos independientes de `ce`.
