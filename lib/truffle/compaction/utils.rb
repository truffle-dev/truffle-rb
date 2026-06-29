# frozen_string_literal: true

require "set"
require "json"
require_relative "../message"

module Truffle
  module Compaction
    # The file-tracking and conversation-serialization helpers of compaction, a
    # faithful port of pi's compaction/utils.ts. A compaction folds the files its
    # dropped history touched into the summary as metadata tags, and renders the
    # kept messages into the plain-text body the summarizing model reads.
    #
    # These functions reopen the Compaction module so the public surface stays
    # flat (Compaction.serialize_conversation, Compaction.compute_file_lists, ...);
    # the split is organizational, matching pi's separate utils file. They lean on
    # safe_json, defined alongside the decision layer in compaction.rb.

    # The files a stretch of compacted history touched, grouped by how a tool
    # touched them: read holds files a read tool saw, written holds full-file
    # writes, edited holds in-place edits. Each field is a Set of path strings.
    # Mirrors pi's FileOperations.
    FileOperations = Struct.new(:read, :written, :edited, keyword_init: true)

    # A tool result is clipped before it goes into a summary prompt, so one noisy
    # command output cannot crowd out the conversation. pi's TOOL_RESULT_MAX_CHARS.
    TOOL_RESULT_MAX_CHARS = 2000

    # pi's ESTIMATED_IMAGE_CHARS: an image is charged a flat character budget,
    # since its real token cost is not in the text.
    ESTIMATED_IMAGE_CHARS = 4800

    module_function

    # Characters one content block contributes to the token estimate (used by the
    # decision layer's estimate_tokens). A tool call is its name plus the JSON of
    # its arguments, matching pi's safeJsonStringify(arguments) accounting.
    def block_chars(block)
      case block.type
      when :text then block.text.length
      when :thinking then block.thinking.length
      when :image then ESTIMATED_IMAGE_CHARS
      when :tool_call then block.name.length + safe_json(block.arguments).length
      else 0
      end
    end
    private_class_method :block_chars

    # JSON for a value, with a stable placeholder when it cannot be serialized.
    # Port of pi's safeJsonStringify. pi keeps a copy in both utils.ts and
    # compaction.ts; the shared Compaction module needs only this one.
    def safe_json(value)
      JSON.generate(value)
    rescue StandardError
      "[unserializable]"
    end
    private_class_method :safe_json

    # An empty file-operation accumulator. Port of pi's createFileOps.
    def create_file_ops
      FileOperations.new(read: Set.new, written: Set.new, edited: Set.new)
    end

    # Record the file operations an assistant turn performed into file_ops. Only
    # an assistant message carries tool calls, so other roles add nothing. Each
    # read, write, or edit call with a non-empty string path adds that path to the
    # matching set; other tools and missing or non-string paths are ignored. pi
    # drops a falsey path, which includes the empty string, so an empty path is
    # not recorded here either. Port of pi's extractFileOpsFromMessage.
    def extract_file_ops_from_message(message, file_ops)
      return unless message.role == :assistant

      message.content.grep(ToolCall).each do |call|
        args = call.arguments
        next unless args.is_a?(Hash)

        path = args["path"]
        next unless path.is_a?(String) && !path.empty?

        record_file_op(file_ops, call.name, path)
      end
    end

    # Sorted read-only and modified file lists from accumulated operations. A file
    # that was written or edited is modified; a file only ever read is read-only.
    # A path that was both read and modified counts only as modified, so the two
    # lists never overlap. Both are sorted. Port of pi's computeFileLists.
    def compute_file_lists(file_ops)
      modified = file_ops.edited | file_ops.written
      read_only = (file_ops.read - modified).sort
      { read_files: read_only, modified_files: modified.sort }
    end

    # Render the read-only and modified file lists as the metadata tags appended
    # to a compaction summary. Each non-empty list becomes a <read-files> or
    # <modified-files> block; with neither list populated the result is the empty
    # string. The leading blank line separates the tags from the summary body.
    # Port of pi's formatFileOperations.
    def format_file_operations(read_files, modified_files)
      sections = []
      sections << "<read-files>\n#{read_files.join("\n")}\n</read-files>" unless read_files.empty?
      unless modified_files.empty?
        sections << "<modified-files>\n#{modified_files.join("\n")}\n</modified-files>"
      end
      return "" if sections.empty?

      "\n\n#{sections.join("\n\n")}"
    end

    # Render the messages a cut keeps into the plain-text conversation body the
    # summarizing model reads. Each message becomes one or more labeled parts
    # joined by a blank line: a user turn is its text, an assistant turn is up to
    # three parts (thinking, then text, then tool calls) in that fixed order, and a
    # tool result is its text clipped to TOOL_RESULT_MAX_CHARS. Empty turns and the
    # system prompt contribute nothing. Port of pi's serializeConversation.
    def serialize_conversation(messages)
      parts = []
      messages.each { |message| append_serialized(parts, message) }
      parts.join("\n\n")
    end

    # Clip text to max_chars, appending a note of how many characters were dropped.
    # A text at or under the budget is returned unchanged. Port of pi's
    # truncateForSummary.
    def truncate_for_summary(text, max_chars)
      return text if text.length <= max_chars

      dropped = text.length - max_chars
      "#{text[0, max_chars]}\n\n[... #{dropped} more characters truncated]"
    end

    # Add one tool call's path to the set its tool name maps to. A tool that is
    # not one of read/write/edit touches no file set.
    def record_file_op(file_ops, name, path)
      case name
      when "read" then file_ops.read << path
      when "write" then file_ops.written << path
      when "edit" then file_ops.edited << path
      end
    end
    private_class_method :record_file_op

    # Append the labeled parts for one message to the running parts list. The
    # system prompt and empty turns add nothing, matching pi's role switch.
    def append_serialized(parts, message)
      case message.role
      when :user then append_text_part(parts, "[User]", message)
      when :assistant then append_assistant(parts, message)
      when :tool then append_tool_result(parts, message)
      end
    end
    private_class_method :append_serialized

    # A single labeled part from a message's joined text, skipped when empty. Used
    # for the user turn; the tool result clips first and so has its own helper.
    def append_text_part(parts, label, message)
      text = message.text
      parts << "#{label}: #{text}" if text && !text.empty?
    end
    private_class_method :append_text_part

    # The assistant turn's parts: thinking, then text, then tool calls, each
    # emitted only when present and always in that order regardless of block order.
    def append_assistant(parts, message)
      thinking = message.content.grep(Content::Thinking).map(&:thinking)
      text = message.content.grep(Content::Text).map(&:text)
      tool_calls = message.content.grep(ToolCall).map { |call| serialize_tool_call(call) }

      parts << "[Assistant thinking]: #{thinking.join("\n")}" unless thinking.empty?
      parts << "[Assistant]: #{text.join("\n")}" unless text.empty?
      parts << "[Assistant tool calls]: #{tool_calls.join("; ")}" unless tool_calls.empty?
    end
    private_class_method :append_assistant

    # One tool call rendered as name(k=json(v), ...), the arguments in insertion
    # order. Mirrors pi's Object.entries(args) walk. safe_json lives with the
    # decision layer in compaction.rb; both files share this one module method.
    def serialize_tool_call(call)
      args = call.arguments.map { |key, value| "#{key}=#{safe_json(value)}" }.join(", ")
      "#{call.name}(#{args})"
    end
    private_class_method :serialize_tool_call

    # The tool result part, its text clipped to the per-result budget and skipped
    # when empty.
    def append_tool_result(parts, message)
      text = message.text
      return if text.nil? || text.empty?

      parts << "[Tool result]: #{truncate_for_summary(text, TOOL_RESULT_MAX_CHARS)}"
    end
    private_class_method :append_tool_result
  end
end
