# pure ruby implementation of DEFLATE (inflate only) for educational purpose
# see RFC 1951 and puff.c in zlib source
# WtfPLv2, Y. Guillot, 2020

class Deflate
	def self.inflate(text)
		new(text).inflate
	end

	MAXBITS = 15
	MAXLCODES = 286
	MAXDCODES = 30
	MAXCODES = MAXLCODES + MAXDCODES
	FIXLCODES = 288
	ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

	attr_accessor :stream, :bytepos, :bitpos
	def initialize(text)
		@stream = text.unpack("C*")
		@bytepos = 0
		@bitpos = 0
	end

	def inflate
		out = []
		preset_dict_len = 0	# length of text decoded but not part of the actual output
		loop do
			raise "eos before final block" if eos

			# 3 header bits
			bfinal = (readbit == 1)	# set iff last block of data
			btype = readbits(2)	# compression type: 0 no compression, 01 fixed huffman, 10 dynamic huffman, 11 error
			puts "block header: final #{bfinal} type #{btype} offset #{@bytepos}/#{@bitpos}" if $DEBUG

			case btype
			when 0
				# no compression
				skip_to_next_byte	# skip remaining bits in current byte
				len = read_len_nlen	# decode copy length
				puts "uncompressed #{len}" if $DEBUG
				out.concat @stream[@bytepos, len]	# copy
				@bytepos += len
			when 1
				# compression with fixed huffman code
				puts "static dict block" if $DEBUG
				@static_dicts ||= gen_static_code_trees
				decompress(@static_dicts, out)
			when 2
				# compression with dynamic huffman code
				puts "dynamic dict block" if $DEBUG
				dicts = read_dynamic_code_trees
				puts "data offset #{@bytepos}/#{@bitpos}" if $DEBUG
				decompress(dicts, out)
			when 3
				# reserved btype
				raise "invalid btype 3"
			end

			break if bfinal
		end
		puts "end offset #{@bytepos}/#{@bitpos}" if $DEBUG

		if !eos
			skip_to_next_byte
			puts "leftover: #{@stream.length - @bytepos} #{@stream[@bytepos, 16].pack('C*').inspect}" if $DEBUG and !eos
		end
		out[preset_dict_len..-1].pack("C*")
	end

	# read many bits
	# not used for huffman-encoded data, where bit order is reversed
	def readbits(n)
		out = 0
		n.times { |pos| out |= readbit << pos }
		out
	end

	# read one bit
	def readbit
		if @bitpos >= 8
			@bitpos = 0
			@bytepos += 1
		end
		@bitpos += 1
		return 0 if eos
		@stream[@bytepos][@bitpos-1]
	end

	# check end of stream
	def eos
		@bytepos >= @stream.length
	end

	# discard bits until next byte boundary
	def skip_to_next_byte
		if @bitpos > 0
			nbits = 8 - @bitpos
			val = readbits(nbits)
			puts "discard #{nbits} bits #{val}" if $DEBUG
			if @bitpos == 8
				@bitpos = 0
				@bytepos += 1
			end
		end
	end

	# decode + check length of uncompressed data
	def read_len_nlen
		raise "eos in blen" if @bytepos + 4 >= @stream.length

		len  = @stream[@bytepos] | (@stream[@bytepos+1] << 8)
		@bytepos += 2

		# one's complement of len
		nlen = @stream[@bytepos] | (@stream[@bytepos+1] << 8)
		@bytepos += 2

		raise "bad len nlen" if nlen ^ len != 0xffff

		len
	end

	# decompress a block of huffman-encoded codes according to the decoding dicts
	def decompress(dicts, out)
		while !eos
			curlit = read_huff(dicts[:lit])
			puts "cur lit #{curlit}" if $DEBUG
			case curlit
			when 0..255
				puts "litteral #{curlit.chr.inspect}" if $DEBUG
				out << curlit
			when 256
				puts "end of block" if $DEBUG
				break
			when 257..285
				length = curlit_to_length(curlit)
				dist_symbol = read_huff(dicts[:dist])
				puts "distance symbol #{dist_symbol}" if $DEBUG
				distance = dist_to_distance(dist_symbol)
				puts "repeat dist #{distance} len #{length}" if $DEBUG
				raise "distance too large #{distance} > #{out.length}" if distance > out.length
				pat = out[-distance, length]
				if length > pat.length
					# repeat end of out ([1, 2, 3] dist 1 len 4 => [1, 2, 3, 3, 3, 3, 3])
					pat *= (length / pat.length) + 1
					pat = pat[0, length]
				end
				puts "repeat #{pat.pack('C*').inspect}" if $DEBUG
				out.concat pat
			else
				# 286, 287 encodable but invalid
				raise "invalid curlit #{curlit}"
			end
		end
	end

	# read one huffman encoded code according to the decoding dict
	def read_huff(dict)
		val = 0 	# current value (huffman encoded)
		len = 0		# size in bits of current value
		first = 0	# first code of length len
		index = 0	# index of first code of length len in symbol table

		while len <= MAXBITS
			len += 1
			val |= readbit
			count = dict[:count][len]
			if val - count < first
				puts "decoded huffman value #{val} len #{len}" if $DEBUG
				return dict[:symbol][index + val - first]
			end
			index += count
			first += count
			first <<= 1
			val <<= 1
		end
		raise "bad huffman value #{val}"
	end

	# build a huffman decoding dict from the length in bits of each symbol
	# [:count][0] is the number of symbols not covered by the dict (incomplete dict)
	def construct_dict(lens)
		out = { :count => [0]*(MAXBITS+1), :symbol => [] }

		lens.each { |l|
			out[:count][l] += 1
		}

		# empty dict ok
		return out if out[:count][0] == lens.length

		# check for oversubscribed dict
		left = 1
		(1..MAXBITS).each { |l|
			left <<= 1
			left -= out[:count][l]
			raise "oversubscribed dict" if left < 0
		}

		# offset of first symbol of length l
		offs = [0, 0]
		(1...MAXBITS).each { |l|
			offs[l+1] = offs[l] + out[:count][l]
		}

		lens.each_with_index { |l, sym|
			if l > 0
				offs[l] += 1
				out[:symbol][offs[l]-1] = sym
			end
		}

		out
	end

	# build the decoding dict used for 'static' compressed blocks
	def gen_static_code_trees
		# lit value   0 - 143, 8 bits,  00110000 ->  10111111
		# lit value 144 - 255, 9 bits, 110010000 -> 111111111
		# lit value 256 - 279, 7 bits,   0000000 ->   0010111
		# lit value 280 - 287, 8 bits,  11000000 ->  11000111
		lens = []
		FIXLCODES.times { |sym|
			case sym
			when   0..143; lens << 8
			when 144..255; lens << 9
			when 256..279; lens << 7
			when 280..287; lens << 8
			end
		}
		lit = construct_dict(lens)

		dist = construct_dict([5] * MAXDCODES)

		{ :lit => lit, :dist => dist }
	end

	# decode and build the decoding dict used for dynamic blocks
	def read_dynamic_code_trees
		nlen = readbits(5) + 257
		ndist = readbits(5) + 1
		ncode = readbits(4) + 4
		puts "dynamic code len lens #{nlen} #{ndist} #{ncode}" if $DEBUG
		raise "bad ndlens #{nlen} #{ndist}" if nlen > MAXLCODES or ndist > MAXDCODES

		# build intermediate dict to decode the real dicts
		lens = [0] * ORDER.length
		ncode.times { |i| lens[ORDER[i]] = readbits(3) }
		puts "dynamic code tmp #{lens.inspect}" if $DEBUG

		lencode = construct_dict(lens)

		i = 0
		while i < nlen + ndist
			sym = read_huff(lencode)
			if sym < 16
				lens[i] = sym
				i += 1
			else
				# repeat instruction
				case sym
				when 16	# repeat last length 3-6 times
					raise "no last len" if i == 0
					len = lens[i-1]
					sym = 3 + readbits(2)
				when 17	# repeat '0' 3-10 times
					len = 0
					sym = 3 + readbits(3)
				else	# repeat '0' 11-138 times
					len = 0
					sym = 11 + readbits(7)
				end
				raise "too many length #{i} #{sym}" if i + sym > nlen + ndist
				sym.times {
					lens[i] = len
					i += 1
				}
			end
		end

		puts "dynamic code lens #{lens[0, nlen].inspect} #{lens[nlen, ndist].inspect}" if $DEBUG

		raise "no end of block symbol in dyn dict" if lens[256] == 0

		lit  = construct_dict(lens[0, nlen])
		dist = construct_dict(lens[nlen, ndist])

		{ :lit => lit, :dist => dist }
	end

	# interpret a length symbol
	def curlit_to_length(curlit)
		case curlit
		when 257..260
			# 257 => 3, 260 => 6
			curlit - 254
		when 261..284
			# 261 => 7, 264 => 10
			# 265 => 11-12 (+1bit), 268 => 17-18
			# 281 => 131-162 (+5bits)
			val = curlit - 261
			extrabits = val/4
			pow = 2**extrabits
			3 + 4*pow + (val&3)*pow + readbits(extrabits)
		when 285
			# 285 => 258
			258
		when 286, 287
			raise "invalid curlit #{curlit}"
		end
	end

	# interpret a distance symbol
	def dist_to_distance(val)
		case val
		when 0, 1
			# 0 => 1, 3 => 4
			val + 1
		when 2..29
			# 2 => 3, 3 => 4
			# 4-5 +1bit => 5-8, 6-7 +2bit => 9-16, ...
			# 28-29 +13bit => 16385-32768
			extrabits = (val/2) - 1
			pow = 2**extrabits
			1 + 2*pow + (val&1)*pow + readbits(extrabits)
		when 30, 31
			raise "invalid distance #{val}"
		end
	end
end

if $0 == __FILE__
	if ARGV.empty?
		testbuf = "KLJNIM\03"	# abcdef
		p Deflate.inflate(testbuf)
		testbuf = "sIM\xcbI,IU\0\x11\0"	# "Deflate late" (from a stackoverflow post)
		p Deflate.inflate(testbuf)
	end

	while ARGV.first
		raw = File.open(ARGV.shift, 'rb') { |fd| fd.read }
		unz = Deflate.inflate(raw)
		if $stdout.tty?
			p unz
		else
			$stdout.write unz
		end
	end
end
