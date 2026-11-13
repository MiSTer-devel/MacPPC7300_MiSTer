// MacPPC7300_adc + MacPPC7300_awacs's in path against a behavioural LTC2308
`timescale 1ns/1ps
module adc_tb;
logic clk = 0, reset = 1;
real  half = 5.0;                         // 100 MHz; 7.143 for 70
always #(half) clk = ~clk;

int   tick_div = 1134;                    // 88,200 Hz at 100 MHz
int   tc = 0;
logic tick = 0;
always @(posedge clk) begin
	tick <= 0;
	if (tc == tick_div - 1) begin tc <= 0; tick <= 1; end else tc <= tc + 1;
end

logic [1:0] mode = 2'd2;
wire convst, sck, sdi;
logic sdo;
wire signed [15:0] left, right;
MacPPC7300_adc adc (.clk, .reset, .tick, .mode, .adc_convst(convst), .adc_sck(sck), .adc_sdi(sdi), .adc_sdo(sdo),
                    .left, .right);

// ---- the chip: the word clocked in on SCK's rises sets the next conversion's channel; the
// result leaves MSB first, the next bit 12.5 ns after each SCK fall; Hi-Z while CONVST is high
logic [11:0] level [2] = '{12'd1000, 12'd3000};
logic [5:0]  cw = 6'b100010, cw_in;
logic [11:0] res;
int          nb;
realtime     t_conv, t_fall, t_rise;
int          errors = 0;
always @(posedge convst) begin
	// S/D, O/S, S1, S0, UNI, SLP
	if (cw[5] !== 1'b1 || cw[3:0] !== 4'b0010) begin $display("ERROR: config %b", cw); errors++; end
	res    = level[cw[4]];
	nb     = 0;
	t_conv = $realtime;
	sdo    = 1'bx;
end
always @(negedge convst) begin
	if ($realtime - t_conv < 1600.0) begin $display("ERROR: CONVST fell %0t after rising", $realtime - t_conv); errors++; end
	sdo <= #30 res[11];
end
always @(posedge sck) begin
	if (convst) begin $display("ERROR: SCK during the conversion"); errors++; end
	if ($realtime - t_fall < 10.0) begin $display("ERROR: SCK low %0t", $realtime - t_fall); errors++; end
	t_rise = $realtime;
	if (nb < 6) cw_in = {cw_in[4:0], sdi};
	if (nb == 5) cw = cw_in;
	nb++;
end
always @(negedge sck) begin
	if ($realtime - t_rise < 10.0) begin $display("ERROR: SCK high %0t", $realtime - t_rise); errors++; end
	t_fall = $realtime;
	res = {res[10:0], 1'b0};
	sdo <= #12.5 res[11];
end

// ---- AWACS, the in channel taking bytes as they come
logic sel = 0, we = 0, in_active = 0;
logic [3:0] rn = 0;
logic [31:0] wdata = 0;
wire  [31:0] rq;
wire  di_valid, do_ready, frame_tick;
wire  [7:0] di_data;
wire  [15:0] ol, or_;
logic di_take = 0;
MacPPC7300_awacs awacs (.clk, .reset, .snd_tick(tick), .sel, .we, .rn, .wdata, .be(4'hF), .rq,
	.out_active(1'b0), .do_ready, .do_data(8'h0), .do_put(1'b0),
	.in_active, .di_valid, .di_data, .di_take, .in_left(left), .in_right(right),
	.left(ol), .right(or_), .frame_tick);

logic [7:0] fb [4];
int fn = 0, frames = 0;
logic signed [15:0] fl, fr;
always @(posedge clk) begin
	di_take <= di_valid && !di_take;
	if (di_take) begin
		fb[fn] = di_data;
		if (fn == 3) begin
			fn = 0;
			fl = {fb[0], fb[1]};
			fr = {fb[2], fb[3]};
			frames++;
		end
		else fn++;
	end
end

task automatic set_rate(input [2:0] code);
	@(posedge clk); sel <= 1; we <= 1; rn <= 0; wdata <= {16'h0, 5'h0, code, 8'h0};   // little-endian: bits 10-8
	wdata <= {8'h00, 5'h0, code, 16'h0};
	@(posedge clk); sel <= 0; we <= 0;
endtask

task automatic check(input string what, input int el, input int er, input int tol);
	if (fl < el - tol || fl > el + tol || fr < er - tol || fr > er + tol) begin
		$display("ERROR: %s: frame %0d, %0d; expected %0d, %0d", what, fl, fr, el, er);
		errors++;
	end
	else $display("ok: %s: frame %0d, %0d (%0d frames)", what, fl, fr, frames);
endtask

initial begin
	if ($test$plusargs("slow")) begin half = 7.143; tick_div = 794; end
	repeat (10) @(posedge clk);
	reset = 0;
	in_active = 1;
	repeat (20) @(posedge tick);           // the levels settle on 1000 and 3000
	check("at rest", 0, 0, 0);
	level[0] = 12'd1100; level[1] = 12'd2900;
	repeat (6) @(posedge tick);
	check("stereo, 44,100 Hz", 800, -800, 12);
	if (frames < 11 || frames > 13) begin $display("ERROR: %0d frames in 26 ticks", frames); errors++; end
	mode = 2'd1;
	repeat (6) @(posedge tick);
	check("mono", 800, 800, 20);
	mode = 2'd2;
	set_rate(3'd7);                        // 7,350 Hz: 12 ticks a frame
	frames = 0;
	repeat (48) @(posedge tick);
	check("stereo, 7,350 Hz", 800, -800, 40);
	if (frames < 3 || frames > 5) begin $display("ERROR: %0d frames in 48 ticks", frames); errors++; end
	// the level follows: after 8,000 more rounds (4 time constants) the step is nearly gone
	repeat (8000) @(posedge tick);
	check("level followed", 0, 0, 30);
	mode = 2'd0;
	repeat (24) @(posedge tick);
	check("off", 0, 0, 0);
	if (errors == 0) $display("PASS"); else begin $display("FAIL: %0d errors", errors); $fatal; end
	$finish;
end
endmodule
