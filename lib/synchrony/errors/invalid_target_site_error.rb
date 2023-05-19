module Synchrony::Errors

  class InvalidTargetSiteError < StandardError

    def initialize(target_site)
      super("Connection refused to #{target_site}. Please check '#{I18n.t('synchrony.settings.target_site')}'")
    end

  end

end