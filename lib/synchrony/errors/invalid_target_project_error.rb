module Synchrony::Errors

  class InvalidTargetProjectError < StandardError

    def initialize(project, site)
      super("#{I18n.t('synchrony.settings.target_project')} with name '#{project}' does not exists on #{site}")
    end

  end

end