# frozen_string_literal: true

require "open3"

module Madcp
  class CliError < StandardError; end

  class CliClient
    attr_reader :bin

    def initialize(bin:, timeout: 30, max_chars: 12_000, env: {})
      @bin = bin
      @timeout = timeout
      @max_chars = max_chars
      @env = env
    end

    def run(args, truncate: true)
      raise CliError, "binary '#{@bin}' not found in PATH" unless bin_available?

      Open3.popen3(@env, @bin, *args) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }

        unless wait_thr.join(@timeout)
          Process.kill("KILL", wait_thr.pid)
          raise CliError, "timeout after #{@timeout}s: #{@bin} #{args.join(" ")}"
        end

        out = out_reader.value.to_s.strip
        err = err_reader.value.to_s.strip
        unless wait_thr.value.success?
          detail = err.empty? ? out : err
          raise CliError, "#{@bin} exited #{wait_thr.value.exitstatus}: #{detail[0, 800]}"
        end

        truncate ? truncate_output(out) : out
      end
    rescue Errno::ESRCH
      raise CliError, "process terminated while running #{@bin}"
    end

    private

    def bin_available?
      return File.executable?(@bin) if @bin.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, @bin))
      end
    end

    def truncate_output(text)
      return text if text.length <= @max_chars

      "#{text[0, @max_chars]}\n\n[... truncated, #{text.length - @max_chars} chars omitted]"
    end
  end
end
