#!/usr/bin/env ruby

require 'open-uri'
require 'digest/sha2'
require 'timeout'
require 'uri'

module Fleeceminer

  ALLOWED_SOLUTION_CHARS = ('a'..'z').to_a + ('0'..'9').to_a
  OWNER_KEY = "steve"
  SOLUTION_PREFIX = "f1eece"
  NUM_WORKERS = 5
  CHECK_INTERVAL = 0.2 # seconds

  Request = Struct.new(:start, :attempt)
  Response = Struct.new(:start, :solution)

  class Worker
    def initialize(output, latest)
      @output = output
      @latest = latest
    end

    def try_solution(attempt)
      if solution = solve(@latest, attempt)
        @output.puts(solution)
        exit
      end
    end

    def solve(start, attempt)
      new_hash = [start, OWNER_KEY, attempt].join(",")
      if Digest::SHA2.hexdigest(new_hash).start_with?(SOLUTION_PREFIX)
        new_hash
      end
    end

  end

  class Supervisor
    def initialize
      @requests = Queue.new
      @responses = Queue.new
      @latest = nil
      @worker_pids = []
      @worker_streams = []
    end

    def run
      while true
        task_workers_with(fetch_latest)
        wait_for_solution
      end
    end

    def start_workers(latest)
      (0...NUM_WORKERS).each do |n|
        rd, wr = IO.pipe
        @worker_streams << rd
        @worker_pids << fork do
          STDERR.puts("Starting worker #{n}")
          worker = Worker.new(wr, latest)
          cur = 'a'
          while true
            worker.try_solution(cur) if (cur.bytes.first % NUM_WORKERS) == n
            cur = cur.succ
          end
        end
      end
    end

    def wait_for_solution
      if ready = IO.select(@worker_streams, [], [], CHECK_INTERVAL)
        ready.first.each do |worker_output|
          solution = worker_output.readline.strip
          if solution.start_with?(@latest)
            STDERR.write("SOLUTION! #{solution}")
            task_workers_with(solution)
            response = Net::HTTP.post_form(URI('https://fleececoin.herokuapp.com/coins'), "coin" => solution)
            STDERR.puts("Response #{response.code}:\n#{response.body}")
            return
          else
            STDERR.write("Warning: Stale solution received")
          end
        end
      end
    end

    def task_workers_with(latest)
      if @latest != latest
        @latest = latest
        STDERR.puts("New task: #{@latest}")
        @worker_pids.each { |p| Process.kill("HUP", p) }
        @worker_pids = []
        @worker_streams.each(&:close)
        @worker_streams = []
        start_workers(latest)
      else
        STDERR.puts("Solution unchanged")
      end
    end

    def fetch_latest
      open('https://fleececoin.herokuapp.com/current', &:read)
    end

  end
end


Fleeceminer::Supervisor.new.run if $0 == __FILE__
