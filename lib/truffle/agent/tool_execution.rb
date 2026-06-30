# frozen_string_literal: true

module Truffle
  # Tool-call execution for the agent loop, reopened from agent.rb. This is the
  # part of the loop that runs a turn's tool calls and applies the before/after
  # middleware, kept beside the loop the way pi separates its tool-execution code
  # (executeToolCalls / prepareToolCall / finalizeExecutedToolCall) from the main
  # agent. Everything here is private; #run drives it.
  class Agent
    private

    # Run each tool call the assistant requested, append its result to the
    # history as a tool message, and return the list of result strings.
    def run_tool_calls(tool_calls)
      tool_calls.map do |call|
        emit(:tool_call, call: call)
        result = execute(call)
        message = Message.tool(content: result, tool_call_id: call.id, name: call.name)
        append(message)
        emit(:tool_result, call: call, result: result, message: message)
        result
      end
    end

    def execute(call)
      tool = @toolbox[call.name]
      # An unknown tool is reported immediately, before either hook runs, the way
      # pi returns a not-found result before reaching beforeToolCall.
      return "Error: unknown tool '#{call.name}'" if tool.nil?

      args = call.arguments
      blocked = before_hook(call, args)
      # A vetoed call skips execution and the after hook, matching pi's immediate
      # block path: the reason becomes the tool result the model reads.
      return blocked if blocked

      after_hook(call, args, run_tool(tool, call, args))
    end

    # The before-tool-call hook. Returns the block reason string when the hook
    # vetoes this call ({ block: true }, with an optional :reason), or nil to
    # proceed. Ports pi's beforeToolCall: the hook sees the call, its arguments,
    # and the running messages, and a block stops the tool from running.
    def before_hook(call, args)
      return nil unless @before_tool_call

      decision = @before_tool_call.call(tool_call: call, args: args, messages: @messages)
      return nil unless decision && decision[:block]

      decision[:reason] || "Tool execution was blocked"
    end

    # Run the tool, folding a raise into the same error string the model used to
    # see. A tool raising should not kill the loop; it is reported back so the
    # model can recover or apologize, as in pi.
    def run_tool(tool, call, args)
      tool.call(args)
    rescue StandardError => e
      "Error running tool '#{call.name}': #{e.class}: #{e.message}"
    end

    # The after-tool-call hook. Lets the hook override the executed result by
    # returning { result: ... }; an omitted key keeps the original. Ports pi's
    # afterToolCall, narrowed to this port's single-string tool result (pi's
    # structured content/details/isError/terminate has no analog here). A hook
    # that raises becomes an error result, as in pi.
    def after_hook(call, args, result)
      return result unless @after_tool_call

      override = @after_tool_call.call(
        tool_call: call, args: args, result: result, messages: @messages
      )
      return result unless override

      override.fetch(:result, result)
    rescue StandardError => e
      "Error in after_tool_call for '#{call.name}': #{e.class}: #{e.message}"
    end
  end
end
