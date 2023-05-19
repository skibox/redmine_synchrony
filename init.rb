require 'active_resource'

if ENV["SYNC_ENABLED"] || Rails.env.production?
  Issue.class_eval do
    after_save :push_changes

    attr_accessor :skip_synchronization

    def push_changes
      return unless self.persisted?

      return if self.skip_synchronization

      Synchrony::Synchronize::Push.new(self).call
    end
  end

  Redmine::Plugin.register :redmine_synchrony do
    name 'Redmine Synchrony plugin'
    author 'Southbridge'
    description 'Plugin makes copies of issues and journals from another redmine instance via API.'
    version '0.0.5'
    url 'https://github.com/southbridgeio/redmine_synchrony'
    author_url 'https://southbridge.io'
    settings default: {'empty' => true}, partial: 'settings/synchrony_settings'
  end
end