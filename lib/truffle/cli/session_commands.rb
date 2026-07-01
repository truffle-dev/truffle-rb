# frozen_string_literal: true

module Truffle
  module CLI
    module_function

    def fork_cli_session(args, cwd: Dir.pwd)
      if args.session_id && exact_session_id_path(args.session_id, args, cwd: cwd)
        raise Truffle::Error, "Session already exists with id '#{args.session_id}'"
      end

      source_path = resolve_session_reference(args.fork, args, cwd: cwd)
      raise Truffle::Error, "No session found matching '#{args.fork}'" unless source_path

      Truffle::Session.fork_from(
        source_path,
        cwd: cwd,
        dir: cli_session_dir(args, cwd),
        id: args.session_id
      )
    rescue ArgumentError => e
      raise Truffle::Error, e.message
    end

    def validate_session_path(path, cwd: Dir.pwd)
      header = Truffle::Session.read_header(path)
      raise Truffle::Error, "not a valid Truffle session: #{path}" unless header

      Truffle::SessionCwd.assert_exists(session_cwd: header[:cwd], fallback_cwd: cwd,
                                        session_file: path)
      path
    end

    def exact_session_id_path(session_id, args, cwd: Dir.pwd)
      Truffle::SessionId.assert_valid!(session_id)
      Truffle::Session.list(cwd: cwd, dir: cli_session_dir(args, cwd)).find do |summary|
        summary.id == session_id
      end&.path
    end

    def select_resume_session?(args, out: $stdout, input: $stdin, cwd: Dir.pwd)
      sessions = Truffle::Session.list(cwd: cwd, dir: cli_session_dir(args, cwd))
      if sessions.empty?
        out.puts "No sessions found for #{cwd}"
        return false
      end

      out.puts "Select a session to resume:"
      sessions.each_with_index do |summary, index|
        out.puts "#{index + 1}. #{resume_session_label(summary)}"
      end
      out.write "Session number: "

      selected = parse_resume_selection(input.gets, sessions.length)
      unless selected
        out.puts "No session selected"
        return false
      end

      args.session = sessions[selected - 1].path
      args.resume = false
      true
    end

    def resume_session_label(summary)
      stamp = summary.timestamp || summary.mtime.utc.iso8601(3)
      "#{summary.id}  #{stamp}"
    end

    def parse_resume_selection(line, count)
      value = line&.strip
      return nil if value.nil? || value.empty?
      return nil if %w[q quit exit cancel].include?(value.downcase)

      index = Integer(value, exception: false)
      return nil unless index&.between?(1, count)

      index
    end

    def validate_fork_args(args)
      return unless args.fork

      conflicts = []
      conflicts << "--session" if args.session
      conflicts << "--continue" if args.continue
      conflicts << "--resume" if args.resume
      conflicts << "--no-session" if args.no_session
      return if conflicts.empty?

      args.diagnostics << {
        type: :error,
        message: "--fork cannot be combined with #{conflicts.join(", ")}"
      }
    end

    def validate_resume_args(args)
      return unless args.resume

      conflicts = []
      conflicts << "--session" if args.session
      conflicts << "--continue" if args.continue
      conflicts << "--fork" if args.fork
      conflicts << "--no-session" if args.no_session
      return if conflicts.empty?

      args.diagnostics << {
        type: :error,
        message: "--resume cannot be combined with #{conflicts.join(", ")}"
      }
    end

    def validate_session_id_args(args)
      return unless args.session_id

      conflicts = []
      conflicts << "--session" if args.session
      conflicts << "--continue" if args.continue
      conflicts << "--resume" if args.resume
      if conflicts.any?
        args.diagnostics << {
          type: :error,
          message: "--session-id cannot be combined with #{conflicts.join(", ")}"
        }
        return
      end

      Truffle::SessionId.assert_valid!(args.session_id)
    rescue ArgumentError => e
      args.diagnostics << { type: :error, message: e.message }
    end

    def validate_session_name_args(args)
      return if args.name.nil?
      return unless Truffle::Session.sanitize_session_name(args.name).empty?

      args.diagnostics << { type: :error, message: "--name requires a non-empty value" }
    end

    def apply_cli_session_name(session, args)
      return unless session && args.name

      session.append_session_info(args.name)
      session.flush
    rescue ArgumentError => e
      raise Truffle::Error, e.message
    end

    private_class_method :fork_cli_session, :validate_session_path,
                         :exact_session_id_path, :select_resume_session?,
                         :resume_session_label, :parse_resume_selection,
                         :validate_fork_args, :validate_resume_args,
                         :validate_session_id_args, :validate_session_name_args,
                         :apply_cli_session_name
  end
end
