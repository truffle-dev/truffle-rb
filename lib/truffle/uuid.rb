# frozen_string_literal: true

require "securerandom"

module Truffle
  # UUID generation for the session store, ported from the ids pi mints in its
  # session manager. pi uses a uuidv7 for the session id and the first eight hex
  # of a random uuid for each entry id. Both are reproduced here against the
  # standard library so the harness keeps no runtime gem dependency.
  module UUID
    module_function

    # A UUIDv7 (RFC 9562): a 48-bit Unix-millisecond timestamp in the high bits,
    # then the version and variant markers, then random bits. The leading
    # timestamp makes ids sort in creation order, which is why pi uses it for the
    # session id (sessions list newest-first without reading mtimes). The layout
    # is built byte by byte: bytes 0-5 hold the timestamp big-endian, byte 6's
    # high nibble is the version (7), and byte 8's two high bits are the variant
    # (0b10); the rest is random.
    def v7(now: Time.now)
      ms = (now.to_f * 1000).floor
      rand = SecureRandom.random_bytes(10).unpack("C*")
      bytes = [
        (ms >> 40) & 0xff, (ms >> 32) & 0xff, (ms >> 24) & 0xff,
        (ms >> 16) & 0xff, (ms >> 8) & 0xff, ms & 0xff,
        0x70 | (rand[0] & 0x0f), rand[1],
        0x80 | (rand[2] & 0x3f), *rand[3..9]
      ]
      format_uuid(bytes)
    end

    # A short entry id: the first eight hex characters of a random UUID, retried
    # on the rare collision against ids already in use (pi's generateId). The
    # `taken` argument answers #include?(id); after 100 collisions it falls back
    # to a full UUID, as pi does.
    def short(taken)
      100.times do
        id = SecureRandom.uuid.delete("-")[0, 8]
        return id unless taken.include?(id)
      end
      SecureRandom.uuid
    end

    # Render 16 bytes as the canonical 8-4-4-4-12 hyphenated form.
    def format_uuid(bytes)
      hex = bytes.map { |byte| format("%02x", byte) }.join
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end
  end
end
