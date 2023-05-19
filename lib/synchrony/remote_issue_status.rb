module Synchrony

  class RemoteIssueStatus < ActiveResource::Base
    self.format = :xml
    self.element_name = 'issue_status'
    self.timeout = 5

    def self.by_id(id)
      RemoteIssueStatus.all.find{ |s| s.id == id }
    end

    def self.by_name(name)
      priorities = RemoteIssueStatus.all
      priorities.find{ |s| s.name == name } if priorities.present?
    end
  end
end