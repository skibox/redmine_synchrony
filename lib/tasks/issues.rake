namespace :redmine_synchrony do

  desc 'Synchronize issues from remote redmine'
  task :issues => :environment do
    site_settings = Setting.find_by(name: "plugin_redmine_synchrony")
    Synchrony::Synchronize::Pull.new(site_settings).call
  end
end