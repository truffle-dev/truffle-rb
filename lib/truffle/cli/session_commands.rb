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

    private_class_method :fork_cli_session, :validate_session_path,
                         :exact_session_id_path, :validate_fork_args,
                         :validate_session_id_args
  end
end
