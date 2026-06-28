# frozen_string_literal: true

module Pith
  # A single message in an agent conversation.
  #
  # Pith works with one flat message type across every provider. The provider
  # layer is responsible for translating these into whatever wire shape a given
  # API expects (see Pith::Providers::Base#serialize_messages). Keeping a single
  # in-memory representation is what lets the agent loop stay provider-agnostic.
  #
  # Roles:
  #   :system    - instructions that steer the assistant
  #   :user      - input from the human (or upstream caller)
  #   :assistant - a model turn; may carry tool_calls instead of (or with) text
  #   :tool      - the result of running a tool, linked by tool_call_id
  class Message
    ROLES = %i[system user assistant tool].freeze

    attr_reader :role, :content, :tool_calls, :tool_call_id, :name

    def initialize(role:, content: nil, tool_calls: [], tool_call_id: nil, name: nil)
      role = role.to_sym
      unless ROLES.include?(role)
        raise ArgumentError, "unknown role #{role.inspect}, expected one of #{ROLES.inspect}"
      end

      @role = role
      @content = content
      @tool_calls = tool_calls || []
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

    def tool_calls?
      !@tool_calls.empty?
    end

    def to_h
      {
        role: role,
        content: content,
        tool_calls: tool_calls.map(&:to_h),
        tool_call_id: tool_call_id,
        name: name
      }.compact
    end
  end

  # A single tool invocation requested by the model.
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true) do
    # arguments is always a parsed Hash with string keys, mirroring the JSON the
    # model emitted. The agent symbolizes keys before handing them to the tool.
    def to_h
      { id: id, name: name, arguments: arguments }
    end
  end
end
