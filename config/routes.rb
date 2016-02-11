# Plugin's routes
# See: http://guides.rubyonrails.org/routing.html
get 'redmine_synchrony/sync_all', :to => 'redmine_synchrony#sync_all', :as => 'redmine_synchrony_sync_all'
