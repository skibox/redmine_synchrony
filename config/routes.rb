# Plugin's routes
# See: http://guides.rubyonrails.org/routing.html

get 'redmine_synchrony/pull', :to => 'redmine_synchrony#pull', :as => 'redmine_synchrony_pull'
