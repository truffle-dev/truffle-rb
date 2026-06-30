# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

# Covers Truffle::Mime, the magic-byte sniffer ported from pi's utils/mime.ts.
# Every fixture is an in-memory binary String built byte-for-byte, so the suite
# stays offline and the format edges (a lossless JPEG, an animated PNG, a BMP at
# an unsupported bit depth) are exercised without carrying real image files.
class TestMime < Minitest::Test
  def detect(bytes)
    Truffle::Mime.detect_supported_image_mime_type(bytes)
  end

  # An 8-byte PNG signature followed by an IHDR chunk, with any extra chunk
  # bytes appended after it (an acTL or IDAT chunk in the animation cases).
  def png_bytes(extra = "")
    buffer = +""
    buffer << [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].pack("C*")
    buffer << chunk("IHDR", 13) << extra
    buffer.b
  end

  # One PNG chunk: a 4-byte big-endian length, the 4-byte type tag, `data_size`
  # bytes of payload, and a 4-byte CRC, the layout animated_png? walks over.
  def chunk(type, data_size)
    buffer = +""
    buffer << [data_size].pack("N") << type << ("\x00" * data_size) << ("\x00" * 4)
    buffer
  end

  # A RIFF container with `form` as its four-byte form type ("WEBP" for an
  # image, "WAVE" for the audio lookalike that must be rejected).
  def riff(form)
    buffer = +"RIFF"
    buffer << [0].pack("V") << form
    buffer.b
  end

  # A 54-byte BMP header with a 40-byte BITMAPINFOHEADER. The defaults describe a
  # structurally valid 24-bit bitmap; each keyword pokes one field for an edge.
  def bmp_bytes(bpp: 24, planes: 1, dib: 40, file_size: 100, pixel_offset: 54)
    header = +"BM"
    header << [file_size].pack("V") << [0].pack("V") << [pixel_offset].pack("V")
    header << [dib].pack("V") << [0].pack("V") << [0].pack("V")
    header << [planes].pack("v") << [bpp].pack("v")
    header << ("\x00" * (54 - header.bytesize))
    header.b
  end

  def test_jpeg_signature_maps_to_image_jpeg
    assert_equal "image/jpeg", detect([0xff, 0xd8, 0xff, 0xe0].pack("C*"))
  end

  def test_lossless_jpeg_marker_0xf7_is_rejected
    # The fourth byte 0xf7 is the SOF55 lossless marker, which a model cannot
    # take, so detection returns nil even though the JPEG SOI prefix matches.
    assert_nil detect([0xff, 0xd8, 0xff, 0xf7].pack("C*"))
  end

  def test_still_png_maps_to_image_png
    assert_equal "image/png", detect(png_bytes)
  end

  def test_png_signature_without_a_valid_ihdr_length_is_rejected
    # Same signature, but the chunk length reads 12 rather than the fixed 13, so
    # the IHDR gate fails and the bytes are not a usable PNG.
    bad = +""
    bad << [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].pack("C*")
    bad << [0, 0, 0, 12].pack("C*") << "IHDR" << ("\x00" * 13)

    assert_nil detect(bad.b)
  end

  def test_animated_png_with_an_actl_chunk_before_idat_is_rejected
    # An acTL animation-control chunk ahead of the first IDAT marks an APNG,
    # which is not a still image, so detection returns nil.
    assert_nil detect(png_bytes(chunk("acTL", 8)))
  end

  def test_png_with_an_idat_before_any_actl_stays_a_still_png
    # The walk stops at the first IDAT and reports the PNG as still, the mirror
    # of the animated case that proves the acTL/IDAT ordering is what decides it.
    assert_equal "image/png", detect(png_bytes(chunk("IDAT", 4) + chunk("acTL", 8)))
  end

  def test_gif_signature_maps_to_image_gif
    assert_equal "image/gif", detect("GIF89a".b)
  end

  def test_three_byte_gif_lookalike_is_rejected
    assert_nil detect("GIX89a".b)
  end

  def test_riff_webp_maps_to_image_webp
    assert_equal "image/webp", detect(riff("WEBP"))
  end

  def test_riff_container_that_is_not_webp_is_rejected
    # A RIFF prefix with a WAVE form type is audio, not an image, so the second
    # four-byte marker is what gates the WEBP result.
    assert_nil detect(riff("WAVE"))
  end

  def test_valid_bmp_header_maps_to_image_bmp
    assert_equal "image/bmp", detect(bmp_bytes)
  end

  def test_bmp_with_an_unsupported_bit_depth_is_rejected
    # 7 is not one of the bit depths a real bitmap declares, so the whitelist
    # rejects it even though every other header field is consistent.
    assert_nil detect(bmp_bytes(bpp: 7))
  end

  def test_bmp_with_more_than_one_color_plane_is_rejected
    assert_nil detect(bmp_bytes(planes: 2))
  end

  def test_bmp_with_an_unknown_dib_header_size_is_rejected
    assert_nil detect(bmp_bytes(dib: 13))
  end

  def test_unrecognized_bytes_return_nil
    assert_nil detect("not an image at all".b)
  end

  def test_empty_buffer_returns_nil
    assert_nil detect("".b)
  end

  def test_from_file_sniffs_the_header_off_disk
    Tempfile.create(["fixture", ".png"]) do |file|
      file.binmode
      file.write(png_bytes)
      file.flush

      assert_equal "image/png", Truffle::Mime.detect_supported_image_mime_type_from_file(file.path)
    end
  end

  def test_from_file_returns_nil_for_a_non_image
    Tempfile.create(["fixture", ".txt"]) do |file|
      file.write("plain text, no signature")
      file.flush

      assert_nil Truffle::Mime.detect_supported_image_mime_type_from_file(file.path)
    end
  end
end
