module Synchrony
  class RemoteProject < ActiveResource::Base
    self.format = :xml
    self.element_name = 'project'
  end
end