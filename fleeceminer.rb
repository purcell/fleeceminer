#!/usr/bin/env ruby

require 'open-uri'
require 'digest/sha2'
require 'timeout'
require 'uri'

module Fleeceminer

  OWNER_KEY = "steve"
  SOLUTION_PREFIX = "f1eece"
  NUM_WORKERS = 4
  CHECK_INTERVAL = 3.0 # seconds

  class Worker
    def initialize(output, latest)
      @output = output
      @latest = latest
    end

    def run(start, incr)
      cur = start
      prefix = "#{@latest},#{OWNER_KEY},"
      start_digest = Digest::SHA2.new
      start_digest << prefix
      while true
        digest = start_digest.dup.update(cur.to_s).hexdigest
        if digest.start_with?(SOLUTION_PREFIX)
          solution = prefix + cur.to_s
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
      while true
        task_workers_with(fetch_latest)
        wait_for_solution
      end
    end

    def start_workers(latest)
      STDERR.puts("New task: #{latest}")
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
            STDERR.puts('-' * 78)
            STDERR.puts("SOLUTION! #{solution}")
            task_workers_with(digest)
            response = Net::HTTP.post_form(URI('https://fleececoin.herokuapp.com/coins'), "coin" => solution)
            STDERR.puts("Response: #{response.code} #{response.body}")
            if response.code == 400 && response.body =~ /latest hash \((f1eece.*?)\)/
              # Quickly recover without doing another fetch
              task_workers_with($1)
            end
            return # Worker streams will have been closed by this stage
          else
            STDERR.puts("Warning: Stale solution received")
          end
        end
      end
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
      open('https://fleececoin.herokuapp.com/current', &:read)
    end

  end
end

Fleeceminer::Supervisor.new.run if $0 == __FILE__
