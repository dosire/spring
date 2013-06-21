require "socket"
require "thread"
require "spring/application"

module Spring
  class ApplicationManager
    attr_reader :pid, :child, :app_env, :spring_env, :server

    def initialize(server, app_env)
      @server     = server
      @app_env    = app_env
      @spring_env = Env.new
      @mutex      = Mutex.new
    end

    # We're not using @mutex.synchronize to avoid the weird "<internal:prelude>:10"
    # line which messes with backtraces in e.g. rspec
    def synchronize
      @mutex.lock
      yield
    ensure
      @mutex.unlock
    end

    def start
      start_child
      start_wait_thread
    end

    # Restarting is a background operation. If it fails, we don't want
    # any terminal output. The user will see the output when they next
    # try to run a command.
    def restart
      @pid = nil
      start_child(true)
    end

    def alive?
      @pid
    end

    def with_child
      synchronize do
        if alive?
          begin
            yield
          rescue Errno::ECONNRESET, Errno::EPIPE
            # The child has died but has not been collected by the wait thread yet,
            # so start a new child and try again.
            start
            yield
          end
        else
          start
          yield
        end
      end
    end

    # Returns the pid of the process running the command, or nil if the application process died.
    def run(client)
      with_child do
        child.send_io client
        child.gets
        puts "sent client to #{@pid}"
      end

      child.gets.chomp.to_i # get the pid
    rescue Errno::ECONNRESET, Errno::EPIPE
      puts "error while sending client to application"
      nil
    ensure
      client.close
    end

    def stop
      Process.kill('TERM', pid) if pid
    end

    private

    def start_child(silence = false)
      server.application_starting

      @child, child_socket = UNIXSocket.pair
      @pid = fork {
        [STDOUT, STDERR].each { |s| s.reopen('/dev/null', 'w') } if silence

        (ObjectSpace.each_object(IO).to_a - [STDOUT, STDERR, STDIN, child_socket])
          .reject(&:closed?)
          .each(&:close)

        ENV['RAILS_ENV'] = ENV['RACK_ENV'] = app_env

        ProcessTitleUpdater.run { |distance|
          "spring app    | #{spring_env.app_name} | started #{distance} ago | #{app_env} mode"
        }

        Application.new(child_socket).start
      }
      puts "started #{app_env} on #{@pid}"
      child_socket.close
    end

    def start_wait_thread
      @wait_thread = Thread.new {
        Thread.current.abort_on_exception = true

        while alive?
          _, status = Process.wait2(pid)

          # In the forked child, this will block forever, so we won't
          # return to the next iteration of the loop.
          synchronize { restart if !alive? && status.success? }
        end
      }
    end
  end
end
