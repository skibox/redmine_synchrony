module Synchrony
  class RemoteTracker < ActiveResource::Base
    self.format = :xml
    self.element_name = 'tracker'
    self.timeout = 5
  end
end