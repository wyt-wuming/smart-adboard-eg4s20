
//==============================================================================
//  文件名  : sd_card_sec_read_write.v
//  模块名  : sd_card_sec_read_write
//  功能    : 扇区读写状态机（CMD17 单块读 / CMD24 单块写）
//  时钟域  : sd_card_clk（100MHz）
//  说明    : 参考例程模块
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一 · 2026）
//==============================================================================

module sd_card_sec_read_write
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 0           // spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
	output reg       sd_init_done,
	input            sd_sec_read,
	input[31:0]      sd_sec_read_addr,
	output[7:0]      sd_sec_read_data,
	output           sd_sec_read_data_valid,
	output           sd_sec_read_end,
	input            sd_sec_write,
	input[31:0]      sd_sec_write_addr,
	input[7:0]       sd_sec_write_data,
	output           sd_sec_write_data_req,
	output           sd_sec_write_end,

	output reg[15:0] spi_clk_div,
	output reg       cmd_req,
	input            cmd_req_ack,
	input            cmd_req_error,
	output reg[47:0] cmd,
	output reg[7:0]  cmd_r1,
	output reg[15:0] cmd_data_len,
	output reg       block_read_req,
	input            block_read_valid,
	input[7:0]       block_read_data,
	input            block_read_req_ack,
	output reg       block_write_req,
	output[7:0]      block_write_data,
	input            block_write_data_rd,
	input            block_write_req_ack
);

localparam S_IDLE               = 0;
localparam S_CMD0               = 1;
localparam S_CMD8               = 2;
localparam S_CMD55              = 3;
localparam S_CMD41              = 4;
localparam S_CMD17              = 5;
localparam S_READ               = 6;
localparam S_CMD24              = 7;
localparam S_WRITE              = 8;
localparam S_ERR                = 14;
localparam S_WRITE_END          = 15;
localparam S_READ_END           = 16;
localparam S_WAIT_READ_WRITE    = 17;
localparam S_CMD16              = 18;

reg[4:0]                       state;
reg[31:0]                      sec_addr;

// ★ 上电等待计数器（2026-10-06 加）
//   SD 卡规范要求：上电稳定至少 1ms 之后才能收第一条命令，且要给它 74 个以上时钟。
//   原来复位一放开就立刻发 CMD0，遇到"卡还处在上次通信中断的中间态"时，
//   卡会一直不应答 → 初始化永远完不成 → 数码管位5 恒为 0、图片/音乐/字幕全没有。
//   这种状态靠按键复位救不回来（卡本身没有重新上电），必须断电才行。
//   这里先等约 100ms 再开始初始化，让卡有时间稳定下来。
localparam [27:0] PWR_WAIT_MAX = 28'd10_000_000;      // 100ms @100MHz
reg [27:0]                    pwr_wait;
assign sd_sec_read_data_valid = (state == S_READ) && block_read_valid;
assign sd_sec_read_data = block_read_data;
assign sd_sec_read_end = (state == S_READ_END);
assign sd_sec_write_data_req = (state == S_WRITE) && block_write_data_rd;
assign block_write_data = sd_sec_write_data;
assign sd_sec_write_end = (state == S_WRITE_END);

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		cmd_req <= 1'b0;
		cmd_data_len <= 16'd0;
		cmd_r1 <= 8'd0;
		cmd <= 48'd0;
		spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
		block_write_req <= 1'b0;
		block_read_req <= 1'b0;
		sec_addr <= 32'd0;
		sd_init_done <= 1'b0;
		pwr_wait <= 28'd0;
	end
	else
		case(state)
			S_IDLE:
			begin
				sd_init_done <= 1'b0;
				spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
				// ★ 先等约 100ms 让 SD 卡上电稳定，再开始初始化
				if (pwr_wait < PWR_WAIT_MAX)
					pwr_wait <= pwr_wait + 28'd1;
				else
					state <= S_CMD0;
			end
			S_CMD0:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD8;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd0,8'h00,8'h00,8'h00,8'h00,8'h95};
				end
			end
			S_CMD8:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD55;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd4;
					cmd_r1 <= 8'h01;
					cmd <= {8'd8,8'h00,8'h00,8'h01,8'haa,8'h87};
				end
			end
			S_CMD55:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD41;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd55,8'h00,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD41:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD16;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd41,8'h40,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD16:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WAIT_READ_WRITE;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd16,32'd512,8'hff};
				end
			end			
			S_WAIT_READ_WRITE:
			begin
				if(sd_sec_write ==  1'b1)
				begin
					state <= S_CMD24;
					sec_addr <= sd_sec_write_addr;
				end
				else if(sd_sec_read == 1'b1)
				begin
					state <= S_CMD17;
					sec_addr <= sd_sec_read_addr;
				end

				spi_clk_div <= 16'd0;
			end
			S_CMD24:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WRITE;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd24,sec_addr,8'hff};

				end
			end
			S_WRITE:
			begin
				if(block_write_req_ack == 1'b1)
				begin
					block_write_req <= 1'b0;
					state <= S_WRITE_END;
				end
				else
					block_write_req <= 1'b1;
			end
			S_CMD17:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_READ;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd17,sec_addr,8'hff};
				end
			end
			S_READ:
			begin
				if(block_read_req_ack)
				begin
					state <= S_READ_END;
					block_read_req <= 1'b0;
				end
				else
				begin
					block_read_req <= 1'b1;
				end
			end
			S_WRITE_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			S_READ_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule