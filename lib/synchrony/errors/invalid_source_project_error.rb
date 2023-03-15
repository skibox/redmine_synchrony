module Synchrony::Errors

  class InvalidSourceProjectError < StandardError

    def initialize(project, site)
      super("#{I18n.t('synchrony.settings.source_project')} with name '#{project}' does not exists on #{site}")
    end

  end

end