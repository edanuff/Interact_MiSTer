// 
// Interact SN76477 module
//
// Based on the Sound controller for ABC80 by H. Peter Anvin
// https://git.zytor.com/fpga/abc80/abc80.git/tree/sound.v
// Original work is copyright 2003-2015 H. Peter Anvin
// Original and this derived work are both licensed under the
// GNU General Public License Version 2
// https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
//
// The SN76477 is configured via external resistors and capacitors
// to specify the timing for sound generation.  The Interact uses
// a set of resister and capacitor values that are switched via
// memory-mapped registers.  The configuration information from
// the Interact Service Manual has been used to recreate the SN76477
// as it was used in the Interact.  The following settings are exposed
// to the Interact for configration via sound registers A and B:
//
// Attack
//   00 = 1.95 ms
//   01 = 5.85 ms
//   10 =   90 ms
//   11 =  270 ms
//
// Decay
//   00 =   21 ms
//   01 =  340 ms
//   10 =  213 ms
//   11 = 1020 ms
//
// SLF Frequency
//   00 = 173 Hz
//   10 =  35 Hz
//   01 =  16 Hz
//   11 =   3 Hz
//
// VCO Frequency
//   00 = 10,667 Hz
//   01 =    388 Hz
//
// Noise Filter
//    0 = White Noise
//    1 = Pink Noise
//
// VCO Select
//    0 = External
//    1 = SLF
//
// One Shot
//    0 = Sound/Enable Attack
//    1 = Begin Decay
//
//  Volume
//    0 = Normal volume
//    1 = 1/2 volume
//
// System Enable
//    0 = Enabled
//    1 = Inhibited
//
// VCO Enternal Control
//    0 = f^
//    1 = fv
//
// Envelope Select
//   00 = VCO
//   01 = One Shot
//   10 = Mixer Only
//   11 = VCO with alternating cycles
//
// Audio Mixer Select
//  000 = VCO
//  001 = Noise
//  010 = SLF/Noise
//  011 = SLF/VCO
//  100 = SLF
//  101 = VCO/Noise
//  110 = SLF/Noise/VCO
//  111 = Tape Sounds To Audio
//

`define vco_min 14'd1024
`define vco_max 14'd12499

// Model the 76477 SLF.  This returns a "sawtooth" value
// between (approximately) [1024,12499] which gives about
// the 10:1 range needed by the VCO.

module slf (
    input clk,  // 24.576 MHz
    input rst_n,
    input [8:0] slf_cycle,
    input [13:0] slf_max,
    output slf,  // SLF squarewave
    output reg [13:0] saw  // Sawtooth magnitude
);
  reg up = 1;
  reg [8:0] cyc_ctr;

  assign slf = up;
  assign saw = ctr;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      saw <= 0;
      cyc_ctr <= 0;
    end else begin
      if (cyc_ctr == 0) begin
        if (saw == `slf_max) up <= 0;
        else if (saw == `vco_min) up <= 1;

        if (up) saw <= saw + 1;
        else saw <= saw - 1;
      end else begin
        cyc_ctr <= cyc_ctr - 1'b1;
      end
      ;
    end
endmodule  // slf

//
// The VCO.  The output frequency = clk/pitch/2.
//
module vco (
    input clk,  // 24.576 MHz
    input [13:0] pitch,  // Pitch control
    output vco,  // VCO squarewave output
    output vco2  // VCO output with every other pulse suppressed
);
  reg [13:0] ctr = 0;
  reg [ 1:0] cycle;

  assign vco  = cycle[0];
  assign vco2 = cycle[0] & cycle[1];

  always @(posedge clk) begin
    if (ctr == 0) begin
      ctr   <= pitch;
      cycle <= cycle + 1;
    end else ctr <= ctr - 1;
  end  // always @ (posedge clk)
endmodule  // vco

//
// Noise (e.g. random number) generator.  The periodicity is ~2 Hz,
// which should be inaudible.
// 
module noise (
    input clk,  // 24.576 MHz
    input clk_en,  // One pulse every 21 us (48 kHz)
    output noise
);
  reg [15:0] lfsr = ~16'h0;  // Must be nonzero

  assign noise = lfsr[15];

  wire lfsr_zero = (lfsr == 0);

  always @(posedge clk) if (clk_en) lfsr <= {lfsr[14:0], lfsr_zero} ^ (lfsr[15] ? 16'h54b9 : 16'h0);
endmodule  // noise

//
// Mixer
//
module mixer (
    input slf,
    input vco,
    input noise,
    input envelope,
    input [2:0] mixer_ctl,
    output mixer_out
);
  reg out;

  assign mixer_out = out;

  always @(*)
    case (mixer_ctl)
      3'b000: out <= vco;
      3'b001: out <= noise;
      3'b010: out <= slf & noise;
      3'b011: out <= slf & vco;
      3'b100: out <= slf;
      3'b101: out <= vco & noise;
      3'b110: out <= slf & noise & vco;
      3'b111: out <= envelope;  // This will be tape noise.     
    endcase  // case( mixer_ctl )
endmodule  // mixer

//
// Envelope generator, consisting of one-shot generator,
// envelope select, and envelope generation (attack/decay.)
// Output is parallel digital.
//
module oneshot (
    input clk,  // 24.576 MHz
    input clk_en,  // One pulse every 21 us (48 kHz)
    input inhibit,
    output reg oneshot
);
  reg                        out = 0;
  reg                        inhibit1 = 0;
  reg                 [10:0] ctr = 0;

  wire ctr_or = |ctr;

  always @(posedge clk) begin
    inhibit1 <= inhibit;
    oneshot  <= ctr_or;

    if (~inhibit & inhibit1) ctr <= 11'd1624;  // ~26 ms
    else if (ctr_or & clk_en) ctr <= ctr - 1;
  end
endmodule  // oneshot

module envelope_select (
    input [1:0] envsel,
    input oneshot,
    input vco,
    input vco2,
    output reg envelope
);

  always @(*) begin
    case (envsel)
      2'b00: envelope <= vco;
      2'b01: envelope <= 1;
      2'b10: envelope <= oneshot;
      2'b11: envelope <= vco2;
    endcase  // case( envsel )
  end  // always @ (*)
endmodule  // envelope_select

module envelope_shape (
    input clk,  // 24.576 MHz
    input clk_en,  // One pulse every 21 us (48 kHz)
    input envelope,
    output reg [13:0] env_mag
);

  always @(posedge clk)
    if (clk_en) begin
      if (envelope) begin
        if (env_mag[13:11] != 3'b111) env_mag <= env_mag + 20;
      end else begin
        if (|env_mag) env_mag <= env_mag - 1;
      end
    end  // if ( clk_en )
endmodule  // envelope_shape

//
// Putting it all together...
//
module sound_generator (
    input clk_audio,  // 24.576 MHz
    input [2:0] mixer_ctl,
    input vco_sel,
    input vco_pitch,
    input [1:0] envsel,
    input inhibit,

    output [13:0] magnitude
);
  wire        w_slf;
  wire [13:0] saw;
  wire [13:0] vco_level;
  wire        w_vco;
  wire        w_vco2;
  wire        w_envelope;
  wire        w_noise;
  wire        w_oneshot;
  wire        w_mixer_out;

  wire [13:0] env_mag;
  wire        signal_on;

  // get 48Khz clk from 24.576 MHz audio clock
  reg  [ 8:0] clk_div_512;
  always @(posedge clk_audio) clk_div_512 <= clk_div_512 + 1;
  wire clk_en = clk_div_512[8];

  slf slf (
      .clk(clk),
      .clk_en(clk_en),
      .saw(saw),
      .slf(w_slf)
  );

  assign vco_level = vco_sel ? saw : vco_pitch ? `vco_max : `vco_min;

  vco vco (
      .clk  (clk),
      .pitch(vco_level),
      .vco  (w_vco),
      .vco2 (w_vco2)
  );

  noise noise (
      .clk(clk),
      .clk_en(clk_en),
      .noise(w_noise)
  );


  mixer mixer (
      .slf(w_slf),
      .vco(w_vco),
      .noise(w_noise),
      .envelope(w_envelope),
      .mixer_ctl(mixer_ctl),
      .mixer_out(w_mixer_out)
  );


  oneshot oneshot (
      .clk(clk),
      .clk_en(clk_en),
      .inhibit(inhibit),
      .oneshot(w_oneshot)
  );

  envelope_select envelope_select (
      .envsel(envsel),
      .oneshot(w_oneshot),
      .vco(w_vco),
      .vco2(w_vco2),
      .envelope(w_envelope)
  );

  envelope_shape envelope_shape (
      .clk(clk),
      .clk_en(clk_en),
      .envelope(w_envelope),
      .env_mag(env_mag)
  );


  assign signal_on = ~inhibit & w_mixer_out;
  assign magnitude = env_mag & {14{signal_on}};

endmodule  // sound_generator

