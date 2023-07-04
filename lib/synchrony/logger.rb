module Synchrony
  class Logger < ::Logger
    include Singleton

    def initialize
      super(Rails.root.join('log/synchrony.log'))
      self.formatter = formatter
      self
    end

    def formatter
      proc do |severity, time, _progname, msg|
        formatted_severity = sprintf("%-5s", severity.to_s)
        formatted_time = time.strftime("%Y-%m-%d %H:%M:%S")
        "[#{formatted_severity} #{formatted_time} #{$$}] #{msg.to_s.strip}\n"
      end
    end

    class << self
      delegate :error, :debug, :fatal, :info, :warn, :add, :log, :to => :instance
    end
  end
end