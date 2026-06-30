/*
 * Copyright (c) 2026 accelerator/Compute Tile contributors
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Tiny Tapeout-sized Compute Tile bring-up island.
//
// The interface is constrained by Tiny Tapeout:
// - ui_in:   8-bit command/immediate byte.
// - uo_out:  8-bit status/result byte.
// - uio_*:   8-bit shared data lane, only driven for read-style commands.
module compute_tile_tiny_tapeout_core #(
    parameter integer UART_CLKS_PER_BIT = 104
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire [7:0] ui_in,
    input  wire [7:0] uio_in,
    output wire [7:0] uo_out,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);

  localparam [2:0] OPC_STATUS      = 3'b000;
  localparam [2:0] OPC_GATE        = 3'b001;
  localparam [2:0] OPC_LOAD_A      = 3'b010;
  localparam [2:0] OPC_LOAD_B      = 3'b011;
  localparam [2:0] OPC_COMPUTE     = 3'b100;
  localparam [2:0] OPC_READ_RESULT = 3'b101;
  localparam [2:0] OPC_FAULT       = 3'b110;
  localparam [2:0] OPC_SELF_TEST   = 3'b111;

  localparam [4:0] IMM_UNLOCK = 5'h1a;
  localparam [4:0] IMM_LOCK   = 5'h05;
  localparam [4:0] IMM_UART_ON  = 5'h0e;
  localparam [4:0] IMM_UART_OFF = 5'h0f;

  localparam [7:0] KEY_UNLOCK = 8'ha5;
  localparam [7:0] KEY_LOCK   = 8'h5a;
  localparam [7:0] KEY_UART_MODE = 8'hc7;

  localparam [7:0] CAPABILITY = 8'b0111_1111;
  localparam [7:0] LOCKED_ERR = 8'he1;
  localparam [7:0] FAULT_ERR  = 8'he2;
  localparam [7:0] PASS_CODE  = 8'hc3;
  localparam [7:0] FAIL_CODE  = 8'h3c;

  localparam integer UART_HALF_CLKS = UART_CLKS_PER_BIT / 2;
  localparam [31:0] UART_BIT_LAST = UART_CLKS_PER_BIT - 1;
  localparam [31:0] UART_HALF_LAST = UART_HALF_CLKS - 1;
  localparam [1:0] UART_RX_IDLE  = 2'd0;
  localparam [1:0] UART_RX_START = 2'd1;
  localparam [1:0] UART_RX_DATA  = 2'd2;
  localparam [1:0] UART_RX_STOP  = 2'd3;

  localparam [1:0] UART_LOAD_NONE  = 2'd0;
  localparam [1:0] UART_LOAD_A     = 2'd1;
  localparam [1:0] UART_LOAD_B     = 2'd2;
  localparam [1:0] UART_LOAD_FAULT = 2'd3;

  localparam [7:0] UART_ACK_A     = 8'h41;
  localparam [7:0] UART_ACK_B     = 8'h42;
  localparam [7:0] UART_ACK_FAULT = 8'h46;
  localparam [7:0] UART_BAD_CMD   = 8'h3f;

  wire [2:0] opcode = ui_in[7:5];
  wire [4:0] imm    = ui_in[4:0];
  wire [1:0] sel    = ui_in[1:0];

  reg        unlocked_q;
  reg        result_valid_q;
  reg        error_sticky_q;
  reg        compute_disabled_q;
  reg        self_test_pass_q;
  reg [7:0]  operand_a_q;
  reg [7:0]  operand_b_q;
  reg [7:0]  result_q;
  reg [7:0]  trace_q;
  reg [7:0]  op_count_q;
  reg [7:0]  cycle_count_q;
  reg [7:0]  error_count_q;
  reg [7:0]  last_cmd_q;

  reg        boot_sampled_q;
  reg        uart_mode_q;
  reg [1:0]  uart_load_state_q;

  reg        uart_rx_meta_q;
  reg        uart_rx_sync_q;
  reg [1:0]  uart_rx_state_q;
  reg [15:0] uart_rx_count_q;
  reg [3:0]  uart_rx_bit_q;
  reg [7:0]  uart_rx_shift_q;
  reg        uart_rx_ready_q;
  reg [7:0]  uart_rx_byte_q;

  reg        uart_tx_q;
  reg        uart_tx_busy_q;
  reg        uart_tx_pending_q;
  reg [7:0]  uart_tx_pending_byte_q;
  reg [7:0]  uart_tx_shift_q;
  reg [15:0] uart_tx_count_q;
  reg [3:0]  uart_tx_bit_q;

  reg [7:0]  uo_out_r;
  reg [7:0]  uio_out_r;

  wire public_cmd = (opcode == OPC_STATUS) || (opcode == OPC_GATE);
  wire protected_cmd = !public_cmd;
  wire protected_allowed = !protected_cmd || unlocked_q;
  wire read_style_cmd = (opcode == OPC_STATUS) ||
                        (opcode == OPC_READ_RESULT) ||
                        (opcode == OPC_SELF_TEST);

  wire [7:0] uo_out_uart_mux = {uo_out_r[7:5], uart_tx_q, uo_out_r[3:0]};

  assign uo_out = ena ? (uart_mode_q ? uo_out_uart_mux : uo_out_r) : 8'h00;
  assign uio_out = ena ? uio_out_r : 8'h00;
  assign uio_oe = (ena && read_style_cmd) ? 8'hff : 8'h00;

  function [7:0] compute_result;
    input [2:0] op;
    input [7:0] a;
    input [7:0] b;
    reg [7:0] dot4;
    begin
      dot4 = (a[3:0] * b[3:0]) + (a[7:4] * b[7:4]);
      case (op)
        3'd0: compute_result = a + b;
        3'd1: compute_result = a * b;
        3'd2: compute_result = (a > b) ? a : b;
        3'd3: compute_result = a[7] ? 8'h00 : a;
        3'd4: compute_result = dot4;
        3'd5: compute_result = a ^ b;
        default: compute_result = a + b;
      endcase
    end
  endfunction

  function [7:0] trace_next;
    input [7:0] trace;
    input [7:0] cmd;
    input [7:0] data;
    begin
      trace_next = {trace[6:0], trace[7]} ^ cmd ^ data ^ 8'h5a;
    end
  endfunction

  function self_test_ok;
    begin
      self_test_ok = (compute_result(3'd0, 8'h12, 8'h34) == 8'h46) &&
                     (compute_result(3'd1, 8'h07, 8'h06) == 8'h2a) &&
                     (compute_result(3'd4, 8'h21, 8'h43) == 8'h0b) &&
                     (compute_result(3'd3, 8'h80, 8'h55) == 8'h00);
    end
  endfunction

  wire [7:0] status_byte = {
    ^trace_q,
    ena,
    self_test_pass_q,
    compute_disabled_q,
    error_sticky_q,
    result_valid_q,
    unlocked_q,
    1'b1
  };

  always @* begin
    uo_out_r = status_byte;
    uio_out_r = 8'h00;

    case (opcode)
      OPC_STATUS: begin
        uo_out_r = status_byte;
        case (sel)
          2'd0: uio_out_r = CAPABILITY;
          2'd1: uio_out_r = trace_q;
          2'd2: uio_out_r = op_count_q;
          default: uio_out_r = error_count_q;
        endcase
      end
      OPC_GATE: begin
        uo_out_r = unlocked_q ? 8'h55 : 8'h0f;
      end
      OPC_LOAD_A,
      OPC_LOAD_B,
      OPC_FAULT: begin
        uo_out_r = status_byte;
      end
      OPC_COMPUTE: begin
        if (!protected_allowed) begin
          uo_out_r = LOCKED_ERR;
        end else if (compute_disabled_q) begin
          uo_out_r = FAULT_ERR;
        end else begin
          uo_out_r = compute_result(imm[2:0], operand_a_q, operand_b_q);
        end
      end
      OPC_READ_RESULT: begin
        if (!protected_allowed) begin
          uo_out_r = LOCKED_ERR;
          uio_out_r = LOCKED_ERR;
        end else begin
          uo_out_r = result_q;
          case (sel)
            2'd0: uio_out_r = result_q;
            2'd1: uio_out_r = trace_q;
            2'd2: uio_out_r = cycle_count_q;
            default: uio_out_r = last_cmd_q;
          endcase
        end
      end
      OPC_SELF_TEST: begin
        if (!protected_allowed) begin
          uo_out_r = LOCKED_ERR;
          uio_out_r = LOCKED_ERR;
        end else begin
          uo_out_r = self_test_pass_q ? PASS_CODE : FAIL_CODE;
          uio_out_r = self_test_pass_q ? PASS_CODE : FAIL_CODE;
        end
      end
      default: begin
        uo_out_r = status_byte;
      end
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      unlocked_q <= 1'b0;
      result_valid_q <= 1'b0;
      error_sticky_q <= 1'b0;
      compute_disabled_q <= 1'b0;
      self_test_pass_q <= 1'b0;
      operand_a_q <= 8'h00;
      operand_b_q <= 8'h00;
      result_q <= 8'h00;
      trace_q <= 8'h4e;
      op_count_q <= 8'h00;
      cycle_count_q <= 8'h00;
      error_count_q <= 8'h00;
      last_cmd_q <= 8'h00;
      boot_sampled_q <= 1'b0;
      uart_mode_q <= 1'b0;
      uart_load_state_q <= UART_LOAD_NONE;
      uart_rx_meta_q <= 1'b1;
      uart_rx_sync_q <= 1'b1;
      uart_rx_state_q <= UART_RX_IDLE;
      uart_rx_count_q <= 16'd0;
      uart_rx_bit_q <= 4'd0;
      uart_rx_shift_q <= 8'h00;
      uart_rx_ready_q <= 1'b0;
      uart_rx_byte_q <= 8'h00;
      uart_tx_q <= 1'b1;
      uart_tx_busy_q <= 1'b0;
      uart_tx_pending_q <= 1'b0;
      uart_tx_pending_byte_q <= 8'h00;
      uart_tx_shift_q <= 8'h00;
      uart_tx_count_q <= 16'd0;
      uart_tx_bit_q <= 4'd0;
    end else if (ena) begin
      cycle_count_q <= cycle_count_q + 8'h01;
      last_cmd_q <= ui_in;
      uart_rx_meta_q <= ui_in[3];
      uart_rx_sync_q <= uart_rx_meta_q;
      uart_rx_ready_q <= 1'b0;

      if (!boot_sampled_q) begin
        uart_mode_q <= ui_in[3];
        boot_sampled_q <= 1'b1;
      end

      if (uart_mode_q) begin
        case (uart_rx_state_q)
          UART_RX_IDLE: begin
            if (!uart_rx_sync_q) begin
              uart_rx_state_q <= UART_RX_START;
              uart_rx_count_q <= UART_HALF_LAST[15:0];
            end
          end
          UART_RX_START: begin
            if (uart_rx_count_q == 16'd0) begin
              if (!uart_rx_sync_q) begin
                uart_rx_state_q <= UART_RX_DATA;
                uart_rx_count_q <= UART_BIT_LAST[15:0];
                uart_rx_bit_q <= 4'd0;
              end else begin
                uart_rx_state_q <= UART_RX_IDLE;
              end
            end else begin
              uart_rx_count_q <= uart_rx_count_q - 16'd1;
            end
          end
          UART_RX_DATA: begin
            if (uart_rx_count_q == 16'd0) begin
              uart_rx_shift_q <= {uart_rx_sync_q, uart_rx_shift_q[7:1]};
              uart_rx_count_q <= UART_BIT_LAST[15:0];
              if (uart_rx_bit_q == 4'd7) begin
                uart_rx_state_q <= UART_RX_STOP;
              end else begin
                uart_rx_bit_q <= uart_rx_bit_q + 4'd1;
              end
            end else begin
              uart_rx_count_q <= uart_rx_count_q - 16'd1;
            end
          end
          UART_RX_STOP: begin
            if (uart_rx_count_q == 16'd0) begin
              uart_rx_state_q <= UART_RX_IDLE;
              if (uart_rx_sync_q) begin
                uart_rx_byte_q <= uart_rx_shift_q;
                uart_rx_ready_q <= 1'b1;
              end
            end else begin
              uart_rx_count_q <= uart_rx_count_q - 16'd1;
            end
          end
          default: begin
            uart_rx_state_q <= UART_RX_IDLE;
          end
        endcase

        if (uart_tx_busy_q) begin
          if (uart_tx_count_q == 16'd0) begin
            uart_tx_count_q <= UART_BIT_LAST[15:0];
            if (uart_tx_bit_q < 4'd8) begin
              uart_tx_q <= uart_tx_shift_q[0];
              uart_tx_shift_q <= {1'b0, uart_tx_shift_q[7:1]};
              uart_tx_bit_q <= uart_tx_bit_q + 4'd1;
            end else if (uart_tx_bit_q == 4'd8) begin
              uart_tx_q <= 1'b1;
              uart_tx_bit_q <= 4'd9;
            end else begin
              uart_tx_q <= 1'b1;
              uart_tx_busy_q <= 1'b0;
            end
          end else begin
            uart_tx_count_q <= uart_tx_count_q - 16'd1;
          end
        end else if (uart_tx_pending_q) begin
          uart_tx_q <= 1'b0;
          uart_tx_shift_q <= uart_tx_pending_byte_q;
          uart_tx_count_q <= UART_BIT_LAST[15:0];
          uart_tx_bit_q <= 4'd0;
          uart_tx_busy_q <= 1'b1;
          uart_tx_pending_q <= 1'b0;
        end else begin
          uart_tx_q <= 1'b1;
        end
      end else begin
        uart_rx_state_q <= UART_RX_IDLE;
        uart_rx_count_q <= 16'd0;
        uart_rx_bit_q <= 4'd0;
        uart_load_state_q <= UART_LOAD_NONE;
        uart_tx_q <= 1'b1;
        uart_tx_busy_q <= 1'b0;
        uart_tx_pending_q <= 1'b0;
      end

      if (protected_cmd && !unlocked_q) begin
        error_sticky_q <= 1'b1;
        error_count_q <= error_count_q + 8'h01;
        trace_q <= trace_next(trace_q, ui_in, LOCKED_ERR);
      end else begin
        case (opcode)
          OPC_STATUS: begin
          end
          OPC_GATE: begin
            if ((imm == IMM_UNLOCK) && (uio_in == KEY_UNLOCK)) begin
              unlocked_q <= 1'b1;
              trace_q <= trace_next(trace_q, ui_in, uio_in);
            end else if ((imm == IMM_LOCK) && (uio_in == KEY_LOCK)) begin
              unlocked_q <= 1'b0;
              trace_q <= trace_next(trace_q, ui_in, uio_in);
            end else if ((imm == IMM_UART_ON) && (uio_in == KEY_UART_MODE)) begin
              uart_mode_q <= 1'b1;
              trace_q <= trace_next(trace_q, ui_in, uio_in);
            end else if ((imm == IMM_UART_OFF) && (uio_in == KEY_UART_MODE)) begin
              uart_mode_q <= 1'b0;
              trace_q <= trace_next(trace_q, ui_in, uio_in);
            end else begin
              error_sticky_q <= 1'b1;
              error_count_q <= error_count_q + 8'h01;
              trace_q <= trace_next(trace_q, ui_in, 8'hee);
            end
          end
          OPC_LOAD_A: begin
            operand_a_q <= uio_in;
            result_valid_q <= 1'b0;
            trace_q <= trace_next(trace_q, ui_in, uio_in);
          end
          OPC_LOAD_B: begin
            operand_b_q <= uio_in;
            result_valid_q <= 1'b0;
            trace_q <= trace_next(trace_q, ui_in, uio_in);
          end
          OPC_COMPUTE: begin
            if (compute_disabled_q) begin
              error_sticky_q <= 1'b1;
              error_count_q <= error_count_q + 8'h01;
              trace_q <= trace_next(trace_q, ui_in, FAULT_ERR);
            end else begin
              result_q <= compute_result(imm[2:0], operand_a_q, operand_b_q);
              result_valid_q <= 1'b1;
              op_count_q <= op_count_q + 8'h01;
              trace_q <= trace_next(
                trace_q,
                ui_in,
                compute_result(imm[2:0], operand_a_q, operand_b_q)
              );
            end
          end
          OPC_READ_RESULT: begin
          end
          OPC_FAULT: begin
            compute_disabled_q <= uio_in[0];
            if (uio_in[1]) begin
              error_sticky_q <= 1'b1;
              error_count_q <= error_count_q + 8'h01;
            end
            if (uio_in[7]) begin
              error_sticky_q <= 1'b0;
              error_count_q <= 8'h00;
            end
            trace_q <= trace_next(trace_q, ui_in, uio_in);
          end
          OPC_SELF_TEST: begin
            self_test_pass_q <= self_test_ok();
            result_q <= self_test_ok() ? PASS_CODE : FAIL_CODE;
            result_valid_q <= 1'b1;
            op_count_q <= op_count_q + 8'h01;
            trace_q <= trace_next(trace_q, ui_in, self_test_ok() ? PASS_CODE : FAIL_CODE);
          end
          default: begin
          end
        endcase
      end

      if (uart_mode_q && uart_rx_ready_q) begin
        if (uart_load_state_q != UART_LOAD_NONE) begin
          if (!unlocked_q) begin
            error_sticky_q <= 1'b1;
            error_count_q <= error_count_q + 8'h01;
            trace_q <= trace_next(trace_q, uart_rx_byte_q, LOCKED_ERR);
            uart_tx_pending_byte_q <= LOCKED_ERR;
            uart_tx_pending_q <= 1'b1;
          end else begin
            case (uart_load_state_q)
              UART_LOAD_A: begin
                operand_a_q <= uart_rx_byte_q;
                result_valid_q <= 1'b0;
                trace_q <= trace_next(trace_q, 8'h41, uart_rx_byte_q);
                uart_tx_pending_byte_q <= UART_ACK_A;
                uart_tx_pending_q <= 1'b1;
              end
              UART_LOAD_B: begin
                operand_b_q <= uart_rx_byte_q;
                result_valid_q <= 1'b0;
                trace_q <= trace_next(trace_q, 8'h42, uart_rx_byte_q);
                uart_tx_pending_byte_q <= UART_ACK_B;
                uart_tx_pending_q <= 1'b1;
              end
              UART_LOAD_FAULT: begin
                compute_disabled_q <= uart_rx_byte_q[0];
                if (uart_rx_byte_q[1]) begin
                  error_sticky_q <= 1'b1;
                  error_count_q <= error_count_q + 8'h01;
                end
                if (uart_rx_byte_q[7]) begin
                  error_sticky_q <= 1'b0;
                  error_count_q <= 8'h00;
                end
                trace_q <= trace_next(trace_q, 8'h46, uart_rx_byte_q);
                uart_tx_pending_byte_q <= UART_ACK_FAULT;
                uart_tx_pending_q <= 1'b1;
              end
              default: begin
                uart_tx_pending_byte_q <= UART_BAD_CMD;
                uart_tx_pending_q <= 1'b1;
              end
            endcase
          end
          uart_load_state_q <= UART_LOAD_NONE;
        end else begin
          case (uart_rx_byte_q)
            8'h3f, 8'h53, 8'h73: begin // ?, S, s
              uart_tx_pending_byte_q <= status_byte;
              uart_tx_pending_q <= 1'b1;
            end
            8'h43, 8'h63: begin // C, c
              uart_tx_pending_byte_q <= CAPABILITY;
              uart_tx_pending_q <= 1'b1;
            end
            8'h52, 8'h72: begin // R, r
              uart_tx_pending_byte_q <= unlocked_q ? result_q : LOCKED_ERR;
              uart_tx_pending_q <= 1'b1;
            end
            8'h54, 8'h74: begin // T, t
              uart_tx_pending_byte_q <= trace_q;
              uart_tx_pending_q <= 1'b1;
            end
            8'h4f, 8'h6f: begin // O, o
              uart_tx_pending_byte_q <= op_count_q;
              uart_tx_pending_q <= 1'b1;
            end
            8'h45, 8'h65: begin // E, e
              uart_tx_pending_byte_q <= error_count_q;
              uart_tx_pending_q <= 1'b1;
            end
            8'h55, 8'h75: begin // U, u
              unlocked_q <= 1'b1;
              trace_q <= trace_next(trace_q, uart_rx_byte_q, 8'h55);
              uart_tx_pending_byte_q <= 8'h55;
              uart_tx_pending_q <= 1'b1;
            end
            8'h4c, 8'h6c: begin // L, l
              unlocked_q <= 1'b0;
              trace_q <= trace_next(trace_q, uart_rx_byte_q, 8'h0f);
              uart_tx_pending_byte_q <= 8'h0f;
              uart_tx_pending_q <= 1'b1;
            end
            8'h41, 8'h61: begin // A, a
              uart_load_state_q <= UART_LOAD_A;
              uart_tx_pending_byte_q <= UART_ACK_A;
              uart_tx_pending_q <= 1'b1;
            end
            8'h42, 8'h62: begin // B, b
              uart_load_state_q <= UART_LOAD_B;
              uart_tx_pending_byte_q <= UART_ACK_B;
              uart_tx_pending_q <= 1'b1;
            end
            8'h46, 8'h66: begin // F, f
              uart_load_state_q <= UART_LOAD_FAULT;
              uart_tx_pending_byte_q <= UART_ACK_FAULT;
              uart_tx_pending_q <= 1'b1;
            end
            8'h50, 8'h70: begin // P, p
              self_test_pass_q <= self_test_ok();
              result_q <= self_test_ok() ? PASS_CODE : FAIL_CODE;
              result_valid_q <= 1'b1;
              op_count_q <= op_count_q + 8'h01;
              trace_q <= trace_next(trace_q, uart_rx_byte_q, self_test_ok() ? PASS_CODE : FAIL_CODE);
              uart_tx_pending_byte_q <= self_test_ok() ? PASS_CODE : FAIL_CODE;
              uart_tx_pending_q <= 1'b1;
            end
            8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35: begin // 0..5
              if (!unlocked_q) begin
                error_sticky_q <= 1'b1;
                error_count_q <= error_count_q + 8'h01;
                trace_q <= trace_next(trace_q, uart_rx_byte_q, LOCKED_ERR);
                uart_tx_pending_byte_q <= LOCKED_ERR;
                uart_tx_pending_q <= 1'b1;
              end else if (compute_disabled_q) begin
                error_sticky_q <= 1'b1;
                error_count_q <= error_count_q + 8'h01;
                trace_q <= trace_next(trace_q, uart_rx_byte_q, FAULT_ERR);
                uart_tx_pending_byte_q <= FAULT_ERR;
                uart_tx_pending_q <= 1'b1;
              end else begin
                result_q <= compute_result(uart_rx_byte_q[2:0], operand_a_q, operand_b_q);
                result_valid_q <= 1'b1;
                op_count_q <= op_count_q + 8'h01;
                trace_q <= trace_next(
                  trace_q,
                  uart_rx_byte_q,
                  compute_result(uart_rx_byte_q[2:0], operand_a_q, operand_b_q)
                );
                uart_tx_pending_byte_q <= compute_result(uart_rx_byte_q[2:0], operand_a_q, operand_b_q);
                uart_tx_pending_q <= 1'b1;
              end
            end
            default: begin
              error_sticky_q <= 1'b1;
              error_count_q <= error_count_q + 8'h01;
              trace_q <= trace_next(trace_q, uart_rx_byte_q, UART_BAD_CMD);
              uart_tx_pending_byte_q <= UART_BAD_CMD;
              uart_tx_pending_q <= 1'b1;
            end
          endcase
        end
      end
    end
  end

endmodule
