require 'active_resource'

Redmine::Plugin.register :redmine_synchrony do
  name 'Redmine Synchrony plugin'
  author 'Leo'
  description 'Plugin makes copies of issues and journals from another redmine instance via API.'
  version '0.0.1'
  url 'https://github.com/centosadmin/redmine_synchrony'
  author_url 'https://www.linkedin.com/in/yeleleo'
  settings :default => {'empty' => true}, :partial => 'settings/synchrony_settings'
end
