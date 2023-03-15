module Synchrony
  class Updater
    attr_reader :settings

    LIMIT = 50

    REMOTE_CLASSES = [
      RemoteTracker,
      RemoteIssue,
      RemoteIssueStatus,
      RemoteUser,
      RemoteIssuePriority,
      RemoteProject
    ]

    def initialize(settings)
      @settings = settings
      Rails.logger = Logger.new($stdout) unless Rails.env.test?
      I18n.locale = @settings['language'].to_sym if @settings['language'].present?
      prepare_remote_resources
      prepare_local_resources
    end

    def self.default_date
      Date.today
    end

    def sync_date
      (last_sync_date || Synchrony::Updater.default_date).yesterday
    end

    def last_sync_date
      Issue.pluck(:synchronized_at).compact.last
    end

    def sync_issues
      pull_issues
      push_issues
    end

    def pull_issues
      created_issues = 0
      updated_issues = 0

      remote_issues = RemoteIssue.all(
        params: {
          project_id: source_project.id,
          limit: LIMIT,
          status_id: '*',
          updated_on: ">=#{sync_date.strftime('%Y-%m-%d')}"
        }
      )

      remote_issues = remote_issues.select do |ri|
        remote_issue_synchronizable?(ri)
      end

      remote_issues_ids = remote_issues.map { |ri| ri.attributes['id'] }

      our_issues = Issue.where(
        synchronized_id: nil,
        synchrony_id: remote_issues_ids,
        project_id: target_project
      )

      remote_issues.each do |remote_issue|
        issue = our_issues.detect { |oi| oi.synchrony_id == remote_issue.id.to_i }

        if issue.present?
          remote_updated_on = Time.parse(remote_issue.updated_on)

          next if issue.synchronized_at == remote_updated_on

          issue_priority = our_issue_priorities.detect do |ip|
            ip.name == remote_issue.priority.attributes['name']
          end

          issue_status = our_issue_statuses.detect do |is|
            is.name == remote_issue.status.attributes['name']
          end

          update_journals(issue, remote_issue)

          attributes = issue.attributes
          remote_attributes = remote_issue.attributes

          attributes['synchronized_at'] = remote_updated_on
          attributes['subject']         = remote_attributes['subject']
          attributes['description']     = remote_attributes['description']
          attributes['start_date']      = remote_attributes['start_date']
          attributes['due_date']        = remote_attributes['due_date']
          attributes['done_ratio']      = remote_attributes['done_ratio']
          attributes['estimated_hours'] = remote_attributes['estimated_hours']
          attributes['status_id']       = issue_priority.id if issue_priority
          attributes['priority_id']     = issue_status.id if issue_status

          issue.update_columns(**attributes)
          updated_issues += 1
        else
          issue = create_issue(remote_issue)
          update_journals(issue, remote_issue)
          created_issues += 1
        end
      end

      Rails.logger.info 'Pull issues:'
      Rails.logger.info "Site '#{source_site}' issues created: #{created_issues}, issues updated: #{updated_issues}"
    end

    def push_issues
      created_issues = 0
      updated_issues = 0

      issues_subquery = <<-SQL.squish
        (
          SELECT
            issues.*
          FROM issues
          JOIN custom_values cv
            ON cv.customized_type = 'Issue'
            AND cv.customized_id = issues.id
            AND cv.value = '1'
          JOIN custom_fields cf
            ON cf.id = cv.custom_field_id
            AND cf.name = 'synchronizable'
          WHERE
            tracker_id = #{source_tracker.id}
            AND synchrony_id IS NULL
          GROUP BY issues.id
        ) AS issues
      SQL

      issues = Issue.includes(:status, :priority)
                    .select('issues.*')
                    .from(issues_subquery, :issues)

      return unless issues.any?

      now = Time.now

      issues.each do |issue|
        attributes = issue.attributes.except('id')

        remote_issue_priority = remote_issue_priorities.detect do |rp|
          rp['name'] == issue.priority.attributes['name']
        end

        remote_issue_status = remote_issue_statuses.detect do |rs|
          rs['name'] == issue.status.attributes['name']
        end

        next unless remote_issue_priority.present? && remote_issue_status.present?

        new_attributes = {
          'updated_on' => issue.updated_on
        }

        new_attributes['project_id']      = source_project.id
        new_attributes['tracker_id']      = source_tracker.id
        new_attributes['subject']         = attributes['subject']
        new_attributes['description']     = attributes['description']
        new_attributes['start_date']      = attributes['start_date']
        new_attributes['due_date']        = attributes['due_date']
        new_attributes['done_ratio']      = attributes['done_ratio']
        new_attributes['estimated_hours'] = attributes['estimated_hours']
        new_attributes['status_id']       = remote_issue_status['id']
        new_attributes['priority_id']     = remote_issue_priority['id']

        begin
          remote_issue = RemoteIssue.find(attributes['synchronized_id'])

          remote_issue.update_attributes(new_attributes)
          issue.update_columns(synchronized_at: now)

          updated_issues += 1
        rescue ActiveResource::ResourceNotFound
          new_remote_issue = RemoteIssue.new(new_attributes)

          if new_remote_issue.save
            update_journals(issue, new_remote_issue)
            issue.update_columns(synchronized_id: new_remote_issue.id, synchronized_at: now)
            created_issues += 1
          else
            Rails.logger.info "Issue #{issue.id} could not be synced: #{new_remote_issue.errors.full_messages}"
          end
        end
      end

      Rails.logger.info 'Push issues:'
      Rails.logger.info "Site '#{source_site}' issues created: #{created_issues}, issues_updated: #{updated_issues}"
    end

    private

    def remote_issue_synchronizable?(remote_issue)
      remote_issue.custom_fields.any? do |cf|
        cf.attributes['name'] == 'synchronizable' && cf.attributes['value'] == '1'
      end
    end

    def prepare_remote_resources
      REMOTE_CLASSES.each do |resource_class|
        resource_class.site = source_site
        resource_class.headers['X-Redmine-API-Key'] = api_key
      end

      begin
        unless source_tracker.present?
          raise Errors::InvalidSourceTrackerError.new(settings['source_tracker'], source_site)
        end
        unless source_project.present?
          raise Errors::InvalidSourceProjectError.new(settings['source_project'], source_site)
        end
      rescue SocketError
        raise Errors::InvalidSourceSiteError, source_site
      end
    end

    def prepare_local_resources
      raise Errors::InvalidSettingError, 'target_project' unless target_project.present?
      raise Errors::InvalidSettingError, 'target_tracker' unless target_tracker.present?

      target_project.trackers << target_tracker unless target_project.trackers.include?(target_tracker)
    end

    def source_site
      raise Errors::InvalidSettingError, 'source_site' unless settings['source_site'].present?

      @source_site ||= if settings['source_site'].end_with?('/')
                         settings['source_site']
                       else
                         "#{settings['source_site']}/"
                       end
    end

    def api_key
      raise Errors::InvalidSettingError, 'api_key' unless settings['api_key'].present?

      @api_key ||= settings['api_key']
    end

    def source_tracker
      raise Errors::InvalidSettingError, 'source_tracker' unless settings['source_tracker'].present?

      @source_tracker ||= RemoteTracker.all.find do |t|
        sanitize_input(t.name) == sanitize_input(settings['source_tracker'])
      end
    end

    def source_project
      raise Errors::InvalidSettingError, 'source_project' unless settings['source_project'].present?

      @source_project ||= RemoteProject.all.find do |t|
        sanitize_input(t.name) == sanitize_input(settings['source_project'])
      end
    end

    def sanitize_input(input)
      input.mb_chars.downcase.strip
    end

    def target_project
      @target_project ||= Project.find_by(id: settings['target_project'])
    end

    def target_tracker
      @target_tracker ||= Tracker.find_by(id: settings['target_tracker'])
    end

    def our_issue_priorities
      @our_issue_priorities ||= IssuePriority.all
    end

    def our_issue_statuses
      @our_issue_statuses ||= IssueStatus.all
    end

    def remote_issue_priorities
      @remote_issue_priorities ||= RemoteIssuePriority.all.map(&:attributes)
    end

    def remote_issue_statuses
      @remote_issue_statuses ||= RemoteIssueStatus.all.map(&:attributes)
    end

    def create_issue(remote_issue)
      description = "#{source_site}issues/#{remote_issue.id}\n\n________________\n\n#{remote_issue.description}"

      priority = our_issue_priorities.detect do |oip|
        oip.name == remote_issue.attributes['priority'].attributes['name']
      end

      status = our_issue_statuses.detect do |ois|
        ois.name == remote_issue.attributes['status'].attributes['name']
      end

      options = {
        synchrony_id: remote_issue.id,
        subject: remote_issue.subject,
        description: description,
        tracker: target_tracker,
        project: target_project,
        author: User.anonymous,
        synchronized_at: Time.parse(remote_issue.updated_on)
      }

      options[:priority_id] = priority.id if priority
      options[:status_id] = status.id     if status

      Issue.create(**options)
    end

    def update_journals(issue, remote_issue)
      remote_issue = RemoteIssue.find(remote_issue.id, params: { include: :journals })

      remote_issue.journals.each do |remote_journal|
        journal = issue.journals.where(synchrony_id: remote_journal.id).first
        unless journal.present?
          notes = "h3. \"#{remote_journal.user.name}\":#{source_site}users/#{remote_journal.user.id}:\n\n" +
                  "#{journal_details(remote_journal)}#{remote_journal.notes}"
          Journal.transaction do
            journal = issue.journals.create(user: User.anonymous, notes: notes, synchrony_id: remote_journal.id)
            Journal.where(id: journal.id).update_all(created_on: Time.parse(remote_journal.created_on))
          end
        end
        issue.journals.reload
      end
    end

    def journal_details(remote_journal)
      return '' if remote_journal.details.empty?

      remote_journal.details.map do |detail|
        if detail.property == 'attr' && %w[status_id assigned_to_id priority_id].include?(detail.name)
          send("details_for_#{detail.name}", detail)
        end
      end.reject(&:blank?).join("\n") + "\n\n"
    end

    def details_for_status_id(detail)
      result = ''

      old_status = remote_issue_statuses.detect { |ris| ris.id == detail.old_value }
      new_status = remote_issue_statuses.detect { |ris| ris.id == detail.new_value }

      if old_status || new_status
        result << "*#{I18n.t(:label_issue_status)}:* "
        result << old_status.name if old_status
        result << ' >> '
        result << new_status.name if new_status
      end

      result
    end

    def details_for_assigned_to_id(detail)
      result = ''

      old_user = RemoteUser.by_id(detail.old_value) if detail.old_value.present?
      new_user = RemoteUser.by_id(detail.new_value) if detail.new_value.present?

      if old_user || new_user
        result << "*#{I18n.t(:field_assigned_to)}:* "
        result << "#{old_user.firstname} #{old_user.lastname}" if old_user
        result << ' >> '
        result << "#{new_user.firstname} #{new_user.lastname}" if new_user
      end

      result
    end

    def details_for_priority_id(detail)
      result = ''

      old_priority = remote_issue_priorities.detect { |rip| rip.id == detail.old_value }
      new_priority = remote_issue_priorities.detect { |rip| rip.id == detail.new_value }

      if old_priority || new_priority
        result << "*#{I18n.t(:field_priority)}:* "
        result << old_priority.name if old_priority
        result << ' >> '
        result << new_priority.name if new_priority
      end

      result
    end
  end
end
