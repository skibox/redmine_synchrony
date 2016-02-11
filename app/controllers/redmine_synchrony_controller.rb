class RedmineSynchronyController < ApplicationController
  def sync_all
    require 'synchrony/updater'
    if Setting.plugin_redmine_synchrony['redmine'].present?
      Setting.plugin_redmine_synchrony['redmine'].each do |site_settings|
        Synchrony::Updater.new(site_settings).sync_issues
      end
    end
    redirect_to :back
  end
end
