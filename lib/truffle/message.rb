# frozen_string_literal: true

module Truffle
  # A single message in an agent conversation.
  #
  # Truffle works with one flat message type across every provider. The provider
  # layer translates these into whatever wire shape a given API expects (see
  # Truffle::Providers::Base#serialize_messages). One in-memory representation is
  # what lets the agent loop stay provider-agnostic.
  #
  # A message's content is a list of typed blocks (Truffle::Content::Text,
  # ::Thinking, ::Image, and ToolCall), the way pi models content. A bare String
  # is wrapped as one Text block, so the common case stays a one-liner, and the
  # model's tool calls live in the same list rather than in a side channel.
  #
  # Roles:
  #   :system    - instructions that steer the assistant
  #   :user      - input from the human (or upstream caller)
  #   :assistant - a model turn; may carry text, thinking, and tool-call blocks
  #   :tool      - the result of running a tool, linked by tool_call_id
  class Message
    ROLES = %i[system user assistant tool].freeze

    attr_reader :role, :content, :tool_call_id, :name

    def initialize(role:, content: nil, tool_calls: [], tool_call_id: nil, name: nil)
      role = role.to_sym
      unless ROLES.include?(role)
        raise ArgumentError, "unknown role #{role.inspect}, expected one of #{ROLES.inspect}"
      end

      @role = role
      @content = normalize_content(content) + Array(tool_calls)
      @tool_call_id = tool_call_id
      @name = name
    end

    def self.system(content)
      new(role: :system, content: content)
    end

    def self.user(content)
      new(role: :user, content: content)
    end

    def self.assistant(content: nil, tool_calls: [])
      new(role: :assistant, content: content, tool_calls: tool_calls)
    end

    # A tool result message, linked back to the assistant tool call by id.
    def self.tool(content:, tool_call_id:, name: nil)
      new(role: :tool, content: content, tool_call_id: tool_call_id, name: name)
    end

    # Rebuild a Message from the Hash that #to_h produced, the inverse used when a
    # session is read back from disk. Keys may be symbols (a direct #to_h) or
    # strings (after a JSON round-trip). The content list is rebuilt block by
    # block, tool calls included, so a turn restores to the same shape it had in
    # memory. Tool-call blocks pass straight through normalize_content (they
    # already answer #type), so they land back in the content list in order.
    def self.from_h(hash)
      h = hash.transform_keys(&:to_s)
      blocks = Array(h["content"]).map { |block| Content.from_h(block) }
      new(role: h["role"], content: blocks, tool_call_id: h["tool_call_id"], name: h["name"])
    end

    # The tool calls the model requested this turn, lifted out of the content
    # blocks so the agent loop can dispatch them.
    def tool_calls
      @content.grep(ToolCall)
    end

    def tool_calls?
      @content.any?(ToolCall)
    end

    # The plain text of the message: every Text block joined, or nil when the
    # turn carried no text (a pure tool call, for example).
    def text
      texts = @content.grep(Content::Text)
      return nil if texts.empty?

      texts.map(&:text).join
    end

    def to_h
      {
        role: role,
        content: @content.map(&:to_h),
        tool_call_id: tool_call_id,
        name: name
      }.compact
    end

    private

    # Accepts a typed block, a bare String (wrapped as one Text block), an Array
    # mixing the two, or nil (no content). Anything else becomes a Text block via
    # to_s, so the loop never holds a content value it cannot render.
    def normalize_content(content)
      case content
      when nil then []
      when Array then content.map { |block| coerce_block(block) }
      else [coerce_block(content)]
      end
    end

    def coerce_block(block)
      return block if block.respond_to?(:type)

      Content::Text.new(text: block.to_s)
    end
  end

  # A single tool invocation requested by the model. It is a content block, so it
  # answers #type and #to_h alongside the others in Truffle::Content.
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true) do
    # arguments is always a parsed Hash with string keys, mirroring the JSON the
    # model emitted. The agent symbolizes keys before handing them to the tool.
    def type
      :tool_call
    end

    def to_h
      { type: :tool_call, id: id, name: name, arguments: arguments }
    end
  end
end
