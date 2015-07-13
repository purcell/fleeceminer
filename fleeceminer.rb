#!/usr/bin/env ruby

require 'open-uri'
require 'digest/sha2'
require 'timeout'
require 'uri'

module Fleeceminer

  OWNER_KEY = "steve"
  SOLUTION_PREFIX = "f1eece"
  NUM_WORKERS = 4
  CHECK_INTERVAL = 2.9 # seconds

  class Worker
    def initialize(output, latest)
      @output = output
      @latest = latest
    end

    def run(start, incr)
      cur = start
      prefix = "#{@latest},#{OWNER_KEY},"
      while true
        solution = prefix + cur.to_s
        if (digest = Digest::SHA2.hexdigest(solution)).start_with?(SOLUTION_PREFIX)
          @output.puts([solution, digest].join('|'))
          exit
        end
        cur += incr
      end
    end
  end

  class Supervisor
    def initialize
      @latest = nil
      @worker_pids = []
      @worker_streams = []
    end

    def run
      just_found_one = false
      while true
        task_workers_with(fetch_latest) unless just_found_one
        just_found_one = wait_for_solution
      end
    end

    def start_workers(latest)
      STDERR.puts("Tasking workers with #{latest}")
      (0...NUM_WORKERS).each do |n|
        rd, wr = IO.pipe
        @worker_streams << rd
        @worker_pids << fork do
          Worker.new(wr, latest).run(n, NUM_WORKERS)
        end
      end
    end

    def wait_for_solution
      if ready = IO.select(@worker_streams, [], [], CHECK_INTERVAL)
        ready.first.each do |worker_output|
          solution, digest = worker_output.readline.strip.split("|")
          if solution.start_with?(@latest)
            STDERR.puts("SOLUTION! #{solution}")
            task_workers_with(digest)
            response = Net::HTTP.post_form(URI('https://fleececoin.herokuapp.com/coins'), "coin" => solution)
            STDERR.puts("Response #{response.code}:\n#{response.body}")
            if response.code == 400 && response.body =~ /latest hash \((f1eece.*?)\)/
              # Quickly recover without doing another fetch
              task_workers_with($1)
            end
            return response.code == 200
          else
            STDERR.puts("Warning: Stale solution received")
          end
        end
      end
      false
    end

    def task_workers_with(latest)
      return if @latest == latest
      @latest = latest
      @worker_pids.each { |p| Process.kill("HUP", p) }
      @worker_pids = []
      @worker_streams.each(&:close)
      @worker_streams = []
      start_workers(latest)
    end

    def fetch_latest
      STDERR.puts("Fetching latest")
      open('https://fleececoin.herokuapp.com/current', &:read)
    end

  end
end

Fleeceminer::Supervisor.new.run if $0 == __FILE__
