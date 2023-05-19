module Synchrony
  class RemoteWatcher < ActiveResource::Base
    self.format = :xml
    self.element_name = 'watcher'
    self.timeout = 5
  end
end