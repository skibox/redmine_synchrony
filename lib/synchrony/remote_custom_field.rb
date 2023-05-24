module Synchrony
  class RemoteCustomField < ActiveResource::Base
    self.format = :xml
    self.element_name = 'custom_field'
    self.timeout = 5
  end
end