# frozen_string_literal: true

module Truffle
  class Agent
    # Ask the agent for a structured final answer, parse it as JSON, and validate
    # it against the schema before returning the parsed Ruby value. This keeps the
    # normal #run return value unchanged while giving embedding apps a direct path
    # to native provider structured output through the full agent loop.
    def run_structured(user_input, schema:, images: [], signal: nil, schema_name: nil,
                       strict: nil)
      run(user_input, images: images, signal: signal, schema: schema,
                      schema_name: schema_name, strict: strict)
      response = @last_response
      unless response && response.stop_reason != StopReason::ERROR
        raise Error, response&.error_message || "structured run did not produce a provider response"
      end

      parsed = parse_structured_response(response)
      errors = structured_schema_errors(schema, parsed)
      unless errors.empty?
        raise Error, "structured response did not match schema: #{errors.join("; ")}"
      end

      parsed
    end

    private

    def structured_options(schema, schema_name, strict)
      return {} unless schema

      options = { schema: schema }
      options[:schema_name] = schema_name if schema_name
      options[:strict] = strict unless strict.nil?
      options
    end

    def parse_structured_response(response)
      response.parsed
    rescue JSON::ParserError => e
      raise Error, "structured response was not valid JSON: #{e.message}"
    end

    def structured_schema_errors(schema, value)
      if schema.respond_to?(:errors)
        schema.errors(value)
      else
        Schema.from_h(Providers.schema_definition(schema)).errors(value)
      end
    end
  end
end
