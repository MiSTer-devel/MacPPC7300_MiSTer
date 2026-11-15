//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The board's ADC (the DE10-nano's LTC2308) as AWACS's sound input
//
//  The audio-in jack of the I/O board (or the ADC add-on) reaches the
//  LTC2308's channels 0 (left, the tip) and 1 (right). At each tick (AWACS's
//  88,200 Hz) the two are converted one after the other, and the samples are
//  left on left / right, signed, until the next tick's replace them: AWACS
//  averages them over its frame (MacPPC7300_awacs).
//
//  The framework's own controller (sys/ltc2308.sv) is not used: it clocks
//  the chip at half its clock (50 MHz at this machine's 100, the chip's
//  limit being 40) and takes its rate from a constant clock, where the CPU's
//  is 70 or 100 MHz. This one counts clocks, the counts chosen for 100 MHz
//  (at 70 everything is 1.43 times as long, and still fits a tick: two
//  conversions take 526 clocks, 5.3 or 7.6 us of the tick's 11.3):
//    CONVST high for the conversion, 170 clocks (1.7 us; the chip's
//      maximum is 1.6), so that it falls only after the conversion's end
//    6 clocks for SDO to leave high impedance (30 ns at most)
//    12 bits, SCK 3 clocks low and 2 high (20 or 14 MHz): SDO taken as SCK
//      rises, 30 ns after the fall that shifted it (the chip's delay is
//      12.5 ns at most); SDI changed as SCK falls
//    30 clocks for the next channel's acquisition (240 ns at least)
//
//  The 6-bit word sent with a conversion's result sets the channel of the
//  NEXT conversion (single-ended, unipolar: 1, the channel's bit 0, bits 2-1,
//  1, 0), so the tick's first conversion (channel 0's, set by the last
//  tick's second) sends channel 1's word and the second channel 0's.
//
//  The chip reads 0 to 4.096 V and the boards wire the jack straight to it,
//  so the signal must be given a DC level near the middle of that range
//  before the jack (a capacitor and two resistors: docs/MacPPC7300_sound.md,
//  "The audio-in jack"); a source plugged straight in rests at 0 V and
//  loses its negative half, which nothing here can restore. Each channel's
//  level is followed slowly (a 2,048-sample time constant: 7 Hz) and taken
//  off; what is left, 13 bits signed, is the sample's top.
//  The first three rounds after the input is turned on only set the level.
//
//  mode (quasi-static): 0 off (no conversions, both samples 0), 1 mono
//  (channel 0 on both), 2 or 3 stereo.
//
//============================================================================

module MacPPC7300_adc
(
	input  logic        clk,
	input  logic        reset,
	input  logic        tick,            // 88,200 Hz: a conversion of each channel
	input  logic [1:0]  mode,

	// the LTC2308's pins
	output logic        adc_convst,
	output logic        adc_sck,
	output logic        adc_sdi,         // to the chip
	input  logic        adc_sdo,         // from the chip

	output logic signed [15:0] left,
	output logic signed [15:0] right
);

localparam logic [7:0] T_CONV = 8'd170, T_EN = 8'd6, T_LOW = 8'd3, T_HIGH = 8'd2, T_ACQ = 8'd30;
localparam logic [5:0] CFG_CH0 = 6'b100010, CFG_CH1 = 6'b110010;

typedef enum logic [2:0] {S_IDLE, S_CONV, S_LOW, S_HIGH, S_ACQ} state_t;
state_t      st;
logic [7:0]  cnt;                        // clocks left in the state, less 1
logic [3:0]  bits;                       // bits still to take
logic        ch;                         // the channel whose result this conversion gives
logic [5:0]  cfg;
logic [11:0] sh;
logic        got;                        // sh holds ch's sample
logic [1:0]  warm;                       // rounds that only set the levels
logic [23:0] bias_l, bias_r;             // the DC level, 12 bits and 12 of fraction

assign adc_sdi = cfg[5];

wire on = mode != 2'd0;

wire [23:0]        bias     = ch ? bias_r : bias_l;
wire signed [24:0] bias_err = $signed({1'b0, sh, 12'h0}) - $signed({1'b0, bias});
wire [23:0]        bias_nxt = bias + 24'(bias_err >>> 11);
wire signed [12:0] centered = $signed({1'b0, sh}) - $signed({1'b0, bias[23:12]});
wire signed [15:0] sample   = {centered, 3'b000};

always_ff @(posedge clk) begin
	got <= 1'b0;

	case (st)
		S_IDLE: if (tick && on) begin
			st         <= S_CONV;
			ch         <= 1'b0;
			cfg        <= CFG_CH1;
			adc_convst <= 1'b1;
			cnt        <= T_CONV - 8'd1;
		end
		S_CONV: begin
			if (cnt == 8'd0) begin
				adc_convst <= 1'b0;
				bits       <= 4'd12;
				cnt        <= T_EN - 8'd1;
				st         <= S_LOW;
			end
			else cnt <= cnt - 8'd1;
		end
		S_LOW: begin
			if (cnt == 8'd0) begin
				adc_sck <= 1'b1;
				sh      <= {sh[10:0], adc_sdo};
				bits    <= bits - 4'd1;
				cnt     <= T_HIGH - 8'd1;
				st      <= S_HIGH;
			end
			else cnt <= cnt - 8'd1;
		end
		S_HIGH: begin
			if (cnt == 8'd0) begin
				adc_sck <= 1'b0;
				cfg     <= {cfg[4:0], 1'b0};
				if (bits == 4'd0) begin
					got <= 1'b1;
					cnt <= T_ACQ - 8'd1;
					st  <= S_ACQ;
				end
				else begin
					cnt <= T_LOW - 8'd1;
					st  <= S_LOW;
				end
			end
			else cnt <= cnt - 8'd1;
		end
		S_ACQ: begin
			if (cnt == 8'd0) begin
				if (!ch) begin
					st         <= S_CONV;
					ch         <= 1'b1;
					cfg        <= CFG_CH0;
					adc_convst <= 1'b1;
					cnt        <= T_CONV - 8'd1;
				end
				else st <= S_IDLE;
			end
			else cnt <= cnt - 8'd1;
		end
		default: st <= S_IDLE;
	endcase

	if (got) begin
		if (warm != 2'd3) begin
			if (ch) begin bias_r <= {sh, 12'h0}; warm <= warm + 2'd1; end
			else    bias_l <= {sh, 12'h0};
		end
		else if (ch) begin
			bias_r <= bias_nxt;
			if (mode != 2'd1) right <= sample;
		end
		else begin
			bias_l <= bias_nxt;
			left   <= sample;
			if (mode == 2'd1) right <= sample;
		end
	end

	if (!on) begin
		warm  <= 2'd0;
		left  <= 16'sd0;
		right <= 16'sd0;
	end

	if (reset) begin
		st         <= S_IDLE;
		cnt        <= 8'd0;
		bits       <= 4'd0;
		ch         <= 1'b0;
		cfg        <= 6'd0;
		sh         <= 12'd0;
		got        <= 1'b0;
		warm       <= 2'd0;
		bias_l     <= 24'd0;
		bias_r     <= 24'd0;
		adc_convst <= 1'b0;
		adc_sck    <= 1'b0;
		left       <= 16'sd0;
		right      <= 16'sd0;
	end
end

endmodule
