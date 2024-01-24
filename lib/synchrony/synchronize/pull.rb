module Synchrony
  module Synchronize
    class Pull
      REMOTE_CLASSES = [
        RemoteTracker,
        RemoteIssue,
        RemoteIssueStatus,
        RemoteIssuePriority,
        RemoteProject,
      ].freeze

      def initialize(site_settings)
        @site_settings = site_settings.value.deep_symbolize_keys
      end

      def terminate(error_type:)
        Synchrony::Logger.info "TERMINATING"
        Synchrony::Logger.info ""

        raise Errors::InvalidSettingError, error_type
      end

      def call
        Synchrony::Logger.info "====================================================="
        Synchrony::Logger.info "PULLING ATTEMPT"
        Synchrony::Logger.info "..."

        if site_settings.blank?
          Synchrony::Logger.info "Synchronization settings are missing"
          Synchrony::Logger.info ""

          terminate(error_type: "settings")
        end

        if site_settings[:local_site].blank?
          Synchrony::Logger.info "Please supply local site before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "local_site")
        end

        if site_settings[:target_site].blank?
          Synchrony::Logger.info "Please supply target site before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "target_site")
        end

        if site_settings[:api_key].blank?
          Synchrony::Logger.info "Please supply API Key before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "api_key")
        end

        if local_synchronizable_switch.blank?
          Synchrony::Logger.info "Please supply Local issue Synchronizable Switch ID before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "local_synchronizable_switch")
        end

        if local_last_sync_successful.blank?
          Synchrony::Logger.info "Please supply Local last sync successful before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "local_last_sync_successful")
        end

        if local_remote_url.blank?
          Synchrony::Logger.info "Please supply Local remote URL before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "local_remote_url")
        end

        if local_initial_project.blank?
          Synchrony::Logger.info "Please supply Local initial project before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "local_initial_project")
        end

        if remote_synchronizable_switch_id.blank?
          Synchrony::Logger.info "Please supply Remote Synchronizable Switch ID before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "remote_synchronizable_switch")
        end

        unless check_local_resource(:trackers_set, :target_tracker)
          Synchrony::Logger.info "Please supply all target trackers before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "target_trackers")
        end

        unless check_local_resource(:issue_statuses_set, :target_issue_status)
          Synchrony::Logger.info "Please supply all target issue statuses before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "target_issue_statuses")
        end

        unless check_local_resource(:issue_priorities_set, :target_issue_priority)
          Synchrony::Logger.info "Please supply all target issue priorities before synchronization"
          Synchrony::Logger.info ""

          terminate(error_type: "target_issue_priorities")
        end

        Synchrony::Logger.info "SITE SETTINGS ARE PRESENT. PULLING ISSUES FROM #{site_settings[:target_site]}:"

        prepare_remote_resources

        pull_issues
        Synchrony::Logger.info "PULLING FINISHED"
        Synchrony::Logger.info "====================================================="
      rescue ActiveResource::TimeoutError => e
        Synchrony::Logger.info "Timeout error: #{e.message}"
      rescue StandardError => e
        Synchrony::Logger.info "================"
        Synchrony::Logger.info "HTTP 500"
        Synchrony::Logger.info "PULL ERROR"
        Synchrony::Logger.info e.message
        Synchrony::Logger.info "Backtrace:"
        e.backtrace.each { |line| Synchrony::Logger.info line }
        raise SynchronyError.new("Error during synchronization. Please check synchrony.log for details.")
      end

      private

      attr_reader :site_settings

      def check_local_resource(set, target_field)
        site_settings[set]
          .select { |ps| ps[:sync] == "true" }
          .all? { |ps| ps[target_field].present? }
      end

      def remote_projects
        @remote_projects ||= RemoteProject.all
      end

      def remote_issue_statuses
        @remote_issue_statuses ||= RemoteIssueStatus.all
      end

      def remote_issue_priorities
        @remote_issue_priorities ||= RemoteIssuePriority.all
      end

      def our_issue_priorities
        @our_issue_priorities ||= IssuePriority.all
      end

      def our_issue_statuses
        @our_issue_statuses ||= IssueStatus.all
      end

      def our_users
        @our_users ||= User.all
      end

      def our_projects
        @our_projects ||= Project.where(name: site_settings[:projects_set].pluck(:local_project))
      end

      def our_trackers
        @our_trackers ||= Tracker.all
      end

      def our_custom_fields
        @our_custom_fields ||= CustomField.all
      end

      def remote_user_id_cf
        @remote_user_id_cf ||= CustomField.find_by(
          name: "Remote User ID",
        )
      end

      def principal_custom_values
        @principal_custom_values ||= CustomValue
                                      .where(
                                        customized_type: "Principal",
                                        custom_field_id: remote_user_id_cf,
                                      )
                                      .where.not(value: nil)
      end

      def local_synchronizable_switch
        @local_synchronizable_switch ||= IssueCustomField.find_by(id: site_settings[:local_synchronizable_switch])
      end

      def local_remote_url
        @local_remote_url ||= IssueCustomField.find_by(id: site_settings[:local_remote_url])
      end

      def local_last_sync_successful
        @local_last_sync_successful ||= IssueCustomField.find_by(id: site_settings[:local_last_sync_successful])
      end

      def local_initial_project
        @local_initial_project ||= IssueCustomField.find_by(id: site_settings[:local_initial_project])
      end

      def project_data(issue)
        site_settings[:projects_set].detect do |s|
          s[:target_project] == issue.project.name
        end
      end

      def tracker_data(issue)
        site_settings[:trackers_set].detect do |s|
          s[:target_tracker] == issue.tracker.name
        end
      end

      def issue_status_data(issue)
        site_settings[:issue_statuses_set].detect do |s|
          s[:target_issue_status] == issue.status.name
        end
      end

      def issue_priority_data(issue)
        site_settings[:issue_priorities_set].detect do |s|
          s[:target_issue_priority] == issue.priority.name
        end
      end

      def custom_field_data(custom_field)
        site_settings[:custom_fields_set]&.detect do |s|
          s[:target_custom_field].to_s == custom_field.id.to_s
        end
      end

      def custom_field_data_by_id(custom_field_id)
        site_settings[:custom_fields_set]&.detect do |s|
          s[:target_custom_field] == custom_field_id
        end
      end

      def local_default_issue_priority_id
        site_settings[:local_default_issue_priority]
      end

      def local_default_issue_status_id
        site_settings[:local_default_issue_status]
      end

      def local_default_user_id
        site_settings[:local_default_assignee]
      end

      def local_default_tracker_id
        site_settings[:local_default_tracker]
      end

      def local_default_project_id
        site_settings[:local_default_project]
      end

      def remote_synchronizable_switch_id
        site_settings[:remote_synchronizable_switch]
      end

      def sanitize_input(input)
        input.mb_chars.strip
      end

      def prepare_remote_resources
        REMOTE_CLASSES.each do |resource_class|
          resource_class.site = target_site
          resource_class.headers['X-Redmine-API-Key'] = api_key
        end
      end

      def target_site
        @target_site ||= if site_settings[:target_site].end_with?('/')
                           site_settings[:target_site]
                         else
                           "#{site_settings[:target_site]}/"
                         end
      end

      def api_key
        @api_key ||= site_settings[:api_key]
      end

      def remote_issue_synchronizable?(remote_issue)
        remote_issue.custom_fields.any? do |cf|
          cf.attributes["id"] == remote_synchronizable_switch_id && cf.attributes['value'] == '1'
        end
      end

      def local_issue_synchronizable?(local_issue)
        local_issue.custom_field_values.detect { |cf| cf.custom_field == local_synchronizable_switch }&.value == "1"
      end

      def pull_issues
        target_projects_data = site_settings[:projects_set].select { |ps| ps[:sync] == "true" }.pluck(:target_project).uniq

        target_projects_data.each do |target_project|
          if target_project.blank?
            Synchrony::Logger.info "Synchronization settings for Project '#{target_project}' are missing"
            Synchrony::Logger.info ""

            next
          end

          Synchrony::Logger.info "Pulling issues from project '#{target_project}'"
          Synchrony::Logger.info ""

          created_issues = 0
          updated_issues = 0

          target_project_id = remote_projects.detect { |rp| rp.name == target_project }&.id

          if target_project_id.blank?
            Synchrony::Logger.info "Project #{target_project} not found on #{site_settings[:target_site]}"
            Synchrony::Logger.info ""
            next
          end

          min_updated_on = (DateTime.current - 8.minutes).strftime('%Y-%m-%dT%H:%M:%SZ')

          project_remote_issues = RemoteIssue.all(
            params: {
              project_id: target_project_id,
              f:          ["updated_on", ""],
              op:         { updated_on: ">=" },
              v:          { updated_on: [min_updated_on] },
              sort:       "updated_on:desc",
              limit:      100,
            }
          )

          project_remote_issues = project_remote_issues.select do |ri|
            remote_issue_synchronizable?(ri)
          end

          if project_remote_issues.blank?
            Synchrony::Logger.info "Project '#{target_project}' has no synchronizable issues"
            Synchrony::Logger.info "---"

            next
          end

          remote_issues_ids = project_remote_issues.map { |ri| ri.attributes["id"] }

          our_issues = Issue
                       .includes(
                         :project, :journals,
                       )
                       .where(
                         synchrony_id: remote_issues_ids,
                       )

          project_remote_issues.each do |remote_issue|
            remote_attributes = remote_issue.attributes.symbolize_keys

            Synchrony::Logger.info "Pulling issue #{remote_attributes[:subject]}"

            project_data = project_data(remote_issue)
            if project_data[:sync] != "true"
              Synchrony::Logger.info "Synchronization is disabled for Project '#{project_data[:local_project]}'"
              Synchrony::Logger.info ""
              next
            end

            tracker_data = tracker_data(remote_issue)
            if tracker_data && tracker_data[:sync] != "true"
              Synchrony::Logger.info "Synchronization is disabled for Tracker '#{tracker_data[:local_tracker]}'"
              Synchrony::Logger.info ""
              next
            end

            issue_status_data = issue_status_data(remote_issue)
            if issue_status_data && issue_status_data[:sync] != "true"
              Synchrony::Logger.info "Synchronization is disabled for Status '#{issue_status_data[:local_issue_status]}'"
              Synchrony::Logger.info ""
              next
            end

            issue_priority_data = issue_priority_data(remote_issue)
            if issue_priority_data && issue_priority_data[:sync] != "true"
              Synchrony::Logger.info "Synchronization is disabled for Priority '#{issue_priority_data[:local_issue_priority]}'"
              Synchrony::Logger.info ""
              next
            end

            our_issue = our_issues.detect { |oi| oi.synchrony_id == remote_issue.id.to_i }

            if our_issue && !local_issue_synchronizable?(our_issue)
              Synchrony::Logger.info "Synchronization is disabled for local issue '#{our_issue.subject}'"
              Synchrony::Logger.info ""
              next
            end

            # Priority matching
            issue_priority = our_issue_priorities.detect do |oip|
              oip.name == issue_priority_data&.dig(:local_issue_priority)
            end
            issue_priority_id = issue_priority&.id || local_default_issue_priority_id

            # Status matching
            issue_status = our_issue_statuses.detect do |ois|
              ois.name == issue_status_data&.dig(:local_issue_status)
            end
            issue_status_id = issue_status&.id || local_default_issue_status_id

            # Tracker matching
            tracker = our_trackers.detect do |ot|
              ot.name == tracker_data&.dig(:local_tracker)
            end
            tracker_id = tracker&.id || local_default_tracker_id

            # Assignee matching
            assigned_to = principal_custom_values.detect do |pcv|
              pcv.value == remote_issue.try(:assigned_to)&.id.to_s
            end
            assigned_to_id = assigned_to&.customized_id || local_default_user_id

            # Author matching
            author = principal_custom_values.detect do |pcv|
              pcv.value == remote_issue.author.id.to_s
            end

            author_id = author&.customized_id || local_default_user_id

            # Project matching
            project_by_tracker = site_settings[:"tracker-projects_set"].detect do |tps|
              tps[:target_tracker] == tracker_data&.dig(:target_tracker)
            end

            if project_by_tracker.blank?
              Synchrony::Logger.info "TRACKER_DATA: #{tracker_data.inspect}"
            end

            project_id = if project_by_tracker.blank?
              local_default_project_id
            else
              project_by_tracker[:local_project]
            end

            remote_updated_on = Time.zone.parse(remote_issue.updated_on)

            custom_fields = [
              { id: local_synchronizable_switch.id, value: "1" },
              { id: local_remote_url.id, value: "#{site_settings[:target_site]}/issues/#{remote_issue.id}" },
              { id: local_initial_project.id, value: project_id }
            ]

            # Custom fields matching

            excluded_remote_custom_field_ids = [
              site_settings[:remote_cf_for_author],
              site_settings[:remote_synchronizable_switch],
              site_settings[:remote_task_url],
            ]

            remote_issue.custom_fields.each do |remote_cf|
              next if excluded_remote_custom_field_ids.include?(remote_cf.id.to_s)

              our_custom_field = our_custom_fields.detect do |ocf|
                ocf.name == custom_field_data(remote_cf)&.dig(:local_custom_field)
              end

              Synchrony::Logger.info "Syncing custom field '#{remote_cf.name}'"

              if our_custom_field.blank?
                Synchrony::Logger.info "Custom field from remote '#{remote_cf.name}' not found on #{site_settings[:local_site]}. Skipping."
                Synchrony::Logger.info ""

                next
              end

              unless custom_field_synchronizable?(our_custom_field)
                Rails.logger.info "Custom field '#{our_custom_field.name}' is not synchronizable. Skipping."

                next
              end

              if our_custom_field.possible_values.present?
                if our_custom_field.multiple
                  if remote_cf.value.is_a?(Array)
                    common_values = our_custom_field.possible_values & remote_cf.value

                    custom_fields << { id: our_custom_field.id, value: common_values.any? ? common_values : nil }
                  else
                    Synchrony::Logger.info "Local custom field #{our_custom_field.name} is an array."
                    Synchrony::Logger.info "Skipping due to non-array value #{remote_cf.value}"
                    Synchrony::Logger.info ""

                    next
                  end
                elsif our_custom_field.possible_values.include?(remote_cf.value)
                  custom_fields << { id: our_custom_field.id, value: remote_cf.value }
                elsif our_custom_field.possible_values.exclude?(remote_cf.value)
                  Synchrony::Logger.info "Value (#{remote_cf.value}) for custom field #{remote_cf.name} is not in possible values. Skipping."
                  Synchrony::Logger.info ""

                  next
                else
                  Synchrony::Logger.info "Local custom field #{our_custom_field.name} is not an array."
                  Synchrony::Logger.info "Skipping due to array value #{remote_cf.value}"
                  Synchrony::Logger.info ""

                  next
                end
              elsif our_custom_field.field_format == "user" && our_custom_field.multiple
                if remote_cf.value.is_a?(Array)
                  principals = principal_custom_values.select do |pcv|
                    remote_cf.value.include?(pcv.value)
                  end

                  user_ids = principals.map(&:customized_id).compact

                  users = User.where(id: user_ids)

                  custom_fields << { id: our_custom_field.id, value: users.pluck(:id) }
                else
                  Synchrony::Logger.info "Remote value for custom field #{remote_cf.name} is not an array. Skipping."
                  Synchrony::Logger.info ""

                  next
                end
              elsif our_custom_field.field_format == "user"
                if remote_cf.value.is_a?(Array)
                  Synchrony::Logger.info "Remote value for custom field #{remote_cf.name} is an array. Skipping."
                  Synchrony::Logger.info ""

                  next
                else
                  principal = principal_custom_values.detect do |pcv|
                    remote_cf.value == pcv.value
                  end

                  user = User.find_by(id: principal&.customized_id)

                  next if user.blank?

                  custom_fields << { id: our_custom_field.id, value: user.id }
                end
              elsif custom_field_string_validation?(our_custom_field)
                regexp     = our_custom_field.regexp.presence
                min_length = our_custom_field.min_length.presence
                max_length = our_custom_field.max_length.presence

                regexp_matches     = regexp.blank? || (regexp.present? && remote_cf.value.match?(Regexp.new(regexp)))
                min_length_matches = min_length.blank? || (min_length.present? && remote_cf.value.length >= min_length.to_i)
                max_length_matches = max_length.blank? || (max_length.present? && remote_cf.value.length <= max_length.to_i)

                if regexp.present? && !regexp_matches
                  Synchrony::Logger.info "Value for custom field #{remote_cf.name} does not match regexp. Skipping."
                  Synchrony::Logger.info ""
                end

                if min_length.present? && !min_length_matches
                  Synchrony::Logger.info "Value for custom field #{remote_cf.name} is too short. Skipping."
                  Synchrony::Logger.info ""
                end

                if max_length.present? && !max_length_matches
                  Synchrony::Logger.info "Value for custom field #{remote_cf.name} is too long. Skipping."
                  Synchrony::Logger.info ""
                end

                next if !regexp_matches || !min_length_matches || !max_length_matches

                custom_fields << { id: our_custom_field.id, value: remote_cf.value }
              else
                custom_fields << { id: our_custom_field.id, value: remote_cf.value }
              end
            end

            attributes = {}

            attributes[:skip_synchronization] = true
            attributes[:synchronized_at]      = remote_updated_on
            attributes[:subject]              = remote_attributes[:subject]
            attributes[:description]          = remote_attributes[:description]
            attributes[:start_date]           = remote_attributes[:start_date]
            attributes[:due_date]             = remote_attributes[:due_date]
            attributes[:done_ratio]           = remote_attributes[:done_ratio]
            attributes[:estimated_hours]      = remote_attributes[:estimated_hours]
            attributes[:project_id]           = project_id
            attributes[:tracker_id]           = tracker_id
            attributes[:status_id]            = issue_status_id
            attributes[:priority_id]          = issue_priority_id
            attributes[:assigned_to_id]       = assigned_to_id
            attributes[:custom_fields]        = custom_fields

            attributes[:author_id] = author_id if our_issue.blank?

            if our_issue.present?
              if our_issue.synchronized_at == remote_updated_on
                Synchrony::Logger.info "Issue '#{remote_attributes[:subject]}' is up to date."
                Synchrony::Logger.info ""

                next
              end

              Synchrony::Logger.info "New attributes:"
              Synchrony::Logger.info "#{attributes.except(:custom_fields).inspect}"
              Synchrony::Logger.info "Custom fields:"
              Synchrony::Logger.info "#{custom_fields.inspect}"

              begin
                update_journals(our_issue, remote_issue)
                update_attachments(our_issue, remote_issue)

                our_issue.update!(**attributes)
                our_issue.update_columns(project_id: attributes[:project_id])
              rescue ActiveRecord::RecordInvalid
                Synchrony::Logger.info "Issue assignee replaced with default user."
                Synchrony::Logger.info "Please add user #{our_issue.assigned_to.name} " \
                                       "to project members"
                Synchrony::Logger.info ""

                attributes[:assigned_to_id] = local_default_user_id
                our_issue.update!(**attributes)
              rescue ActiveRecord::StaleObjectError
                Synchrony::Logger.info "Issue was updated by another user. Skipping."
                Synchrony::Logger.info ""

                next
              end
              updated_issues += 1
            else
              attributes[:synchrony_id] = remote_issue.id

              new_issue = Issue.new(**attributes)

              Synchrony::Logger.info "New attributes:"
              Synchrony::Logger.info "#{attributes.except(:custom_fields).inspect}"
              Synchrony::Logger.info "Custom fields:"
              Synchrony::Logger.info "#{custom_fields.inspect}"

              begin
                new_issue.save!
              rescue ActiveRecord::RecordInvalid
                Synchrony::Logger.info "Issue author and assignee replaced with default user."
                Synchrony::Logger.info "Please add user #{new_issue.author.name} and #{new_issue.assigned_to.name} " \
                                       "to project members"
                Synchrony::Logger.info ""

                new_issue.author_id = local_default_user_id
                new_issue.assigned_to_id = local_default_user_id
                new_issue.save!
              rescue ActiveRecord::StaleObjectError
                Synchrony::Logger.info "Issue was updated by another user. Skipping."
                Synchrony::Logger.info ""

                next
              end

              update_journals(new_issue, remote_issue)
              update_attachments(new_issue, remote_issue)

              created_issues += 1
            end

            Synchrony::Logger.info "Issue '#{remote_attributes[:subject]}' pulled successfully!"
            Synchrony::Logger.info ""
          end

          Synchrony::Logger.info "Project '#{target_project}' issues created: #{created_issues}, " \
                                 "issues updated: #{updated_issues}"
          Synchrony::Logger.info "---"
        end
      end

      def custom_field_synchronizable?(custom_field)
        return false if base_custom_field?(custom_field)

        cf_data = site_settings[:custom_fields_set].detect do |set|
          custom_field.name == set[:local_custom_field]
        end

        cf_data[:sync] == "true"
      end

      def base_custom_field?(custom_field)
        [
          local_synchronizable_switch.name,
          local_remote_url.name,
          remote_user_id_cf.name,
          local_last_sync_successful.name,
          local_initial_project.name,
        ].include?(custom_field.name)
      end

      def custom_field_string_validation?(custom_field)
        custom_field.regexp.present? ||
          custom_field.min_length.present? ||
          custom_field.max_length.present?
      end

      def update_journals(issue, remote_issue)
        remote_issue = RemoteIssue.find(remote_issue.id, params: { include: :journals })

        remote_issue.journals.each do |remote_journal|
          next if remote_journal.details.any? { |d| d.attributes["property"] == "attachment" }

          journal = issue.journals.detect { |j| j.synchrony_id.to_s == remote_journal.id.to_s }

          next if journal.present?

          notes = remote_journal.notes

          author = principal_custom_values.detect do |pcv|
            pcv.value == remote_journal.user.id.to_s
          end
          author_id = author&.customized_id || local_default_user_id

          Journal.transaction do
            journal = issue.journals.create!(user_id: author_id, notes: notes, synchrony_id: remote_journal.id)

            remote_journal.details.each do |detail|
              attrs = detail.attributes

              next if attrs["property"] == "attachment"

              options = {
                property:  attrs["property"],
                prop_key:  attrs["name"],
                old_value: attrs["old_value"],
                value:     attrs["new_value"],
              }

              if options[:property] == "cf"
                our_custom_field = our_custom_fields.detect do |ocf|
                  ocf.name == custom_field_data_by_id(options[:prop_key])&.dig(:local_custom_field)
                end

                if our_custom_field.blank?
                  Synchrony::Logger.info "Custom field with ID #{options[:prop_key]} not found. Skipping."
                  Synchrony::Logger.info ""

                  next
                end

                options[:prop_key] = our_custom_field.id

                if our_custom_field.field_format == "user"
                  old_principal = principal_custom_values.detect do |pcv|
                    options[:old_value] == pcv.customized_id&.to_s
                  end

                  new_principal = principal_custom_values.detect do |pcv|
                    options[:value] == pcv.customized_id&.to_s
                  end

                  old_user = User.find_by(id: old_principal&.value)
                  new_user = User.find_by(id: new_principal&.value)

                  if old_user.blank? && options[:old_value].present?
                    Synchrony::Logger.info "Previous user with Remote User ID #{options[:old_value]} didn't set it. Skipping."
                    Synchrony::Logger.info ""

                    next
                  end

                  if new_user.blank? && options[:value].present?
                    Synchrony::Logger.info "New user with Remote User ID #{options[:value]} didn't set it. Skipping."
                    Synchrony::Logger.info ""

                    next
                  end

                  options[:old_value] = old_user&.id
                  options[:value] = new_user&.id
                end
              end

              case options[:prop_key]
              when "assigned_to_id"
                old_value = principal_custom_values.detect do |pcv|
                  pcv.value == options[:old_value]
                end

                options[:old_value] = old_value&.customized_id || local_default_user_id

                new_value = principal_custom_values.detect do |pcv|
                  pcv.value == options[:value]
                end

                options[:value] = new_value&.customized_id || local_default_user_id
              when "status_id"
                previous_issue_status = remote_issue_statuses.detect do |ris|
                  ris.id.to_s == options[:old_value]
                end

                mapped_issue_status = site_settings[:issue_statuses_set].detect do |s|
                  s[:target_issue_status] == previous_issue_status.name
                end

                parsed_previous_issue_status = our_issue_statuses.detect do |ois|
                  ois.name == mapped_issue_status&.dig(:local_issue_status)
                end

                options[:old_value] = if parsed_previous_issue_status.present?
                                        parsed_previous_issue_status.id.to_s
                                      else
                                        Synchrony::Logger.info "Previous issue status '#{previous_issue_status.name}' not found. " \
                                                               "Replaced with default status."

                                        local_default_issue_status_id
                                      end

                new_issue_status = remote_issue_statuses.detect do |ris|
                  ris.id.to_s == options[:value]
                end

                mapped_issue_status = site_settings[:issue_statuses_set].detect do |s|
                  s[:target_issue_status] == new_issue_status.name
                end

                parsed_new_issue_status = our_issue_statuses.detect do |ois|
                  ois.name == mapped_issue_status&.dig(:local_issue_status)
                end

                options[:value] = if parsed_new_issue_status.present?
                                    parsed_new_issue_status.id.to_s
                                  else
                                    Synchrony::Logger.info "New issue status '#{new_issue_status.name}' not found. " \
                                                           "Replaced with default status."

                                    local_default_issue_status_id
                                  end

              when "priority_id"
                previous_issue_priority = remote_issue_priorities.detect do |rip|
                  rip.id.to_s == options[:old_value]
                end

                mapped_issue_priority = site_settings[:issue_priorities_set].detect do |s|
                  s[:target_issue_priority] == previous_issue_priority.name
                end

                parsed_previous_issue_priority = our_issue_priorities.detect do |oip|
                  oip.name == mapped_issue_priority&.dig(:local_issue_priority)
                end

                options[:old_value] = if parsed_previous_issue_priority.present?
                                        parsed_previous_issue_priority.id.to_s
                                      else
                                        Synchrony::Logger.info "Previous issue priority '#{previous_issue_priority.name}' not found. " \
                                                               "Replaced with default priority."

                                        local_default_issue_priority_id
                                      end

                new_issue_priority = remote_issue_priorities.detect do |rip|
                  rip.id.to_s == options[:value]
                end

                mapped_issue_priority = site_settings[:issue_priorities_set].detect do |s|
                  s[:target_issue_priority] == new_issue_priority.name
                end

                parsed_new_issue_priority = our_issue_priorities.detect do |oip|
                  oip.name == mapped_issue_priority&.dig(:local_issue_priority)
                end

                options[:value] = if parsed_new_issue_priority.present?
                                    parsed_new_issue_priority.id.to_s
                                  else
                                    Synchrony::Logger.info "New issue priority '#{new_issue_priority.name}' not found. " \
                                                           "Replaced with default priority."

                                    local_default_issue_priority_id
                                  end
              end

              journal.details.create!(**options)
            end

            journal.update_columns(created_on: Time.zone.parse(remote_journal.created_on))
          end
        end

        issue.journals.reload
      end

      def update_attachments(our_issue, remote_issue)
        remote_issue = RemoteIssue.find(remote_issue.id, params: { include: [:attachments, :journals] })

        attachments = remote_issue.attributes["attachments"].map(&:attributes)

        attachments.each do |attachment|
          a = Attachment.find_or_initialize_by(synchrony_id: attachment["id"])

          next if a.persisted?

          content_uri = URI.parse(attachment['content_url'].gsub(/\(|\)/) { |g| CGI.escape(g) }).path
          content_url = "#{site_settings[:target_site]}#{content_uri}"

          file_path = Rails.root.join("tmp/temp_files/redmine_attachment_#{attachment['id']}")

          Synchrony::Logger.info "Downloading file #{file_path}"
          Synchrony::Logger.info ""

          conn = Faraday.new(url: content_url) do |faraday|
            faraday.response :logger,
                             Synchrony::Logger,
                             { headers: true, bodies: true, errors: true, log_level: :debug }
          end

          response = conn.get do |req|
            req.headers["X-Redmine-API-Key"] = site_settings[:api_key]
            req.options.timeout              = 5
          end

          Synchrony::Logger.info "-------------------------------"
          Synchrony::Logger.info ""

          if response.status == 200
            file = File.open(file_path, "w+b")
            file.write(response.body)

            author = principal_custom_values.detect do |pcv|
              pcv.value == attachment["author"].id.to_s
            end
            author_id = author&.customized_id || local_default_user_id

            Issue.transaction do
              a.author_id   = author_id
              a.file        = file
              a.filename    = attachment["filename"]
              a.description = attachment["description"]

              a.save!

              our_issue.attachments << a

              attachment_journal = remote_issue.journals.detect do |j|
                j.details.any? do |d|
                  d.property == "attachment" &&
                    d.old_value.nil? &&
                    d.new_value == a.filename
                end
              end

              if attachment_journal
                existing_journal = our_issue.journals.detect do |j|
                  j.synchrony_id.to_s == attachment_journal.id
                end

                journal = existing_journal || our_issue.journals.create!(
                  user_id:      author_id,
                  notes:        attachment_journal.notes,
                  synchrony_id: attachment_journal.id
                )

                journal.details.create!(
                  property:  "attachment",
                  prop_key:  a.id,
                  old_value: nil,
                  value:     a.filename,
                )

                journal.update_columns(created_on: Time.zone.parse(attachment_journal.created_on)) if existing_journal.blank?
              end

              attachment_path = Rails.root.join("files/#{a.disk_directory}/#{a.disk_filename}")

              # workaround for file permissions
              FileUtils.mv(
                file_path,
                attachment_path,
                force: true,
              )

              FileUtils.chmod 0o644, attachment_path
            end
          else
            Synchrony::Logger.info "Response status: #{response.status}"
            Synchrony::Logger.info "Response body: #{response.body}"
            Synchrony::Logger.info ""
            Synchrony::Logger.info "Failed to download/save attachment: #{attachment.inspect} " \
                                   "remote_id: #{remote_issue.id} to issue: #{our_issue.id}"
            Synchrony::Logger.info ""

            next
          end
        end
      end
    end
  end
end
