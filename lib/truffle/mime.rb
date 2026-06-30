# frozen_string_literal: true

module Truffle
  # Magic-byte detection for the image formats the harness can send to a model.
  # A port of pi's coding-agent utils/mime.ts: it sniffs the leading bytes of a
  # buffer and returns one of the supported MIME types, or nil for anything it
  # does not recognize or cannot send (a lossless JPEG, an animated PNG). The
  # checks read raw bytes from a binary String, so no image library is pulled in.
  module Mime
    # The number of leading bytes pi reads from a file before sniffing. Every
    # signature this module inspects lives well inside this window.
    SNIFF_BYTES = 4100

    # The eight-byte PNG file signature, shared by the IHDR and animation checks.
    PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].freeze

    # The bit depths a BMP DIB header may declare for a real bitmap.
    BMP_BITS_PER_PIXEL = [1, 4, 8, 16, 24, 32].freeze

    module_function

    # The MIME type for the image in `buffer` (a binary String), or nil when the
    # bytes are not one of the supported, sendable formats. A JPEG whose fourth
    # byte is 0xf7 is a lossless JPEG, which the model cannot take, so it is nil;
    # an animated PNG is likewise nil. PNG, GIF, WEBP, and a structurally valid
    # BMP map to their MIME types.
    def detect_supported_image_mime_type(buffer)
      buffer = buffer.b unless buffer.encoding == Encoding::BINARY
      if starts_with?(buffer, [0xff, 0xd8, 0xff])
        return byte(buffer, 3) == 0xf7 ? nil : "image/jpeg"
      end
      if starts_with?(buffer, PNG_SIGNATURE)
        return png?(buffer) && !animated_png?(buffer) ? "image/png" : nil
      end
      return "image/gif" if starts_with_ascii?(buffer, 0, "GIF")
      if starts_with_ascii?(buffer, 0, "RIFF") && starts_with_ascii?(buffer, 8, "WEBP")
        return "image/webp"
      end
      return "image/bmp" if starts_with_ascii?(buffer, 0, "BM") && bmp?(buffer)

      nil
    end

    # The MIME type for the image stored at `path`, sniffed from the leading
    # bytes, or nil. Reads at most SNIFF_BYTES bytes so a large image is not
    # slurped whole just to read its header.
    def detect_supported_image_mime_type_from_file(path)
      buffer = File.binread(path, SNIFF_BYTES) || +""
      detect_supported_image_mime_type(buffer)
    end

    # A PNG is real when the IHDR chunk follows the signature with the fixed
    # length 13 and the "IHDR" type tag, the way pi gates on the header chunk.
    def png?(buffer)
      buffer.bytesize >= 16 && read_u32_be(buffer, PNG_SIGNATURE.length) == 13 &&
        starts_with_ascii?(buffer, 12, "IHDR")
    end

    # True when an acTL animation-control chunk appears before the first IDAT,
    # which is how an APNG is told apart from a still PNG. Walks the chunk list
    # from just after the signature, stopping at the first IDAT or a length that
    # would run past the buffer.
    def animated_png?(buffer)
      offset = PNG_SIGNATURE.length
      while offset + 8 <= buffer.bytesize
        chunk_length = read_u32_be(buffer, offset)
        type_offset = offset + 4
        return true if starts_with_ascii?(buffer, type_offset, "acTL")
        return false if starts_with_ascii?(buffer, type_offset, "IDAT")

        next_offset = offset + 8 + chunk_length + 4
        return false if next_offset <= offset || next_offset > buffer.bytesize

        offset = next_offset
      end
      false
    end

    # True when the BMP header is internally consistent: the declared file size
    # and pixel-data offset agree with a known DIB header size, and the bitmap
    # declares one color plane at a supported bit depth. Mirrors pi's isBmp.
    def bmp?(buffer)
      return false if buffer.bytesize < 26

      declared_file_size = read_u32_le(buffer, 2)
      pixel_data_offset = read_u32_le(buffer, 10)
      dib_header_size = read_u32_le(buffer, 14)
      return false if declared_file_size != 0 && declared_file_size < 26
      return false if pixel_data_offset < 14 + dib_header_size
      return false if declared_file_size != 0 && pixel_data_offset >= declared_file_size

      planes, bits = bmp_planes_and_depth(buffer, dib_header_size)
      return false if planes.nil?

      planes == 1 && BMP_BITS_PER_PIXEL.include?(bits)
    end

    # The color-plane count and bit depth for a BMP, read from the field offsets
    # that match its DIB header size: the 12-byte BITMAPCOREHEADER puts them at
    # 22/24, the 40-to-124-byte family at 26/28. Returns [nil, nil] for any other
    # header size or a buffer too short to hold the fields.
    def bmp_planes_and_depth(buffer, dib_header_size)
      if dib_header_size == 12
        [read_u16_le(buffer, 22), read_u16_le(buffer, 24)]
      elsif dib_header_size.between?(40, 124)
        return [nil, nil] if buffer.bytesize < 30

        [read_u16_le(buffer, 26), read_u16_le(buffer, 28)]
      else
        [nil, nil]
      end
    end

    # The byte at `offset`, or 0 past the end, the way pi's reads coalesce an
    # out-of-range index to zero.
    def byte(buffer, offset)
      buffer.getbyte(offset) || 0
    end

    # True when the buffer opens with exactly these byte values.
    def starts_with?(buffer, bytes)
      return false if buffer.bytesize < bytes.length

      bytes.each_index.all? { |i| buffer.getbyte(i) == bytes[i] }
    end

    # True when the buffer holds `text` as raw ASCII at `offset`.
    def starts_with_ascii?(buffer, offset, text)
      return false if buffer.bytesize < offset + text.length

      text.each_char.with_index.all? do |char, i|
        buffer.getbyte(offset + i) == char.ord
      end
    end

    # A little-endian unsigned 16-bit integer at `offset`.
    def read_u16_le(buffer, offset)
      byte(buffer, offset) + (byte(buffer, offset + 1) << 8)
    end

    # A big-endian unsigned 32-bit integer at `offset`. The high byte is scaled
    # by 0x1000000 rather than shifted, matching pi so the result never overflows
    # into a signed value.
    def read_u32_be(buffer, offset)
      (byte(buffer, offset) * 0x1000000) + (byte(buffer, offset + 1) << 16) +
        (byte(buffer, offset + 2) << 8) + byte(buffer, offset + 3)
    end

    # A little-endian unsigned 32-bit integer at `offset`.
    def read_u32_le(buffer, offset)
      byte(buffer, offset) + (byte(buffer, offset + 1) << 8) +
        (byte(buffer, offset + 2) << 16) + (byte(buffer, offset + 3) * 0x1000000)
    end

    private_class_method :png?, :animated_png?, :bmp?, :bmp_planes_and_depth,
                         :byte, :starts_with?, :starts_with_ascii?,
                         :read_u16_le, :read_u32_be, :read_u32_le
  end
end
