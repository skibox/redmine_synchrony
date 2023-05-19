module Synchrony
  class RemoteIssue < ActiveResource::Base
    self.format = :xml
    self.element_name = 'issue'
    self.timeout = 5
  end
end