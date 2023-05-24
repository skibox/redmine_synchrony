class RedmineSynchronyController < ApplicationController
  def pull
    site_settings = Setting.find_by(name: "plugin_redmine_synchrony")
    Synchrony::Synchronize::Pull.new(site_settings).call if site_settings.present?

    redirect_to :back
  end
end
