module Synchrony
  class RemoteIssue < ActiveResource::Base
    class Relation < ActiveResource::Base
      self.format = :xml
      self.element_name = 'relation'
      self.timeout = 5
    end

    self.format = :xml
    self.element_name = 'issue'
    self.timeout = 5
  end
end