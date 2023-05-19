module Synchrony
  class RemoteProject < ActiveResource::Base
    self.format = :xml
    self.element_name = 'project'
    self.timeout = 5
  end
end