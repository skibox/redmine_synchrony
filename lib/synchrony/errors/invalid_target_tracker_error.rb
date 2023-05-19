module Synchrony::Errors

  class InvalidTargetTrackerError < StandardError

    def initialize(tracker, site)
      super("#{I18n.t('synchrony.settings.target_tracker')} with name '#{tracker}' does not exists on #{site}")
    end

  end

end