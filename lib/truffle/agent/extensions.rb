# frozen_string_literal: true

module Truffle
  # Extension helpers for Agent, kept out of agent.rb so the main loop stays
  # readable. Loaded extension tools are defaults; application tools win on name
  # conflicts.
  class Agent
    # Build the toolbox a resumed agent runs with, checking that every tool the
    # dumped agent relied on is among the ones supplied now. The session stores
    # only names; the implementations are rebound here. A required tool that was
    # not supplied is an error, not a silent gap, since the model may call it.
    def self.rebind_toolbox(required_names, supplied, extensions: nil)
      toolbox = Toolbox.new(Extensions.tool_definitions(extensions))
      supplied_tools = supplied.is_a?(Toolbox) ? supplied : Toolbox.new(supplied)
      supplied_tools.each { |tool| toolbox.add(tool) }
      missing = Array(required_names) - toolbox.names
      unless missing.empty?
        raise Error, "session needs tool(s) not supplied to load: #{missing.join(", ")}"
      end

      toolbox
    end
    private_class_method :rebind_toolbox

    private

    def toolbox_for(tools, extensions)
      toolbox = Toolbox.new(Extensions.tool_definitions(extensions))
      supplied = tools.is_a?(Toolbox) ? tools : Toolbox.new(tools)
      supplied.each { |tool| toolbox.add(tool) }
      toolbox
    end

    def dispatch_extension_handlers(event, payload)
      errors = Extensions.dispatch_handlers(@extensions, event, payload)
      @extension_errors.concat(errors)
    end
  end
end
