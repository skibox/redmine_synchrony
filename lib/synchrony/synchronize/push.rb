module Synchrony
  module Synchronize
    class Push
      REMOTE_CLASSES = [
        RemoteTracker,
        RemoteIssue,
        RemoteIssueStatus,
        RemoteIssuePriority,
        RemoteProject,
        RemoteCustomField,
      ].freeze

      def initialize(issue)
        @issue = Issue
                 .includes(
                   :attachments, :journals,
                   project: :issues,
                 )
                 .find_by(id: issue.id)
      end

      def call
        return if not_synchronizable_new_record?

        Synchrony::Logger.info "====================================================="
        Synchrony::Logger.info "#{issue.project.name}: #{issue.subject} PUSHING ATTEMPT"
        Synchrony::Logger.info "..."

        if parsed_settings.blank?
          Synchrony::Logger.info "Synchronization settings are missing"
          return
        end

        if parsed_settings[:projects_set].blank? || parsed_settings[:projects_set].detect do |ps|
             ps[:local_project] == issue.project.name
           end.blank?
          Synchrony::Logger.info "Synchronization settings for Project '#{issue.project.name}' are missing"
          return
        end

        if parsed_settings[:local_site].blank?
          Synchrony::Logger.info "Please supply local site before synchronization"
          return
        end

        if parsed_settings[:target_site].blank?
          Synchrony::Logger.info "Please supply target site before synchronization"
          return
        end

        if parsed_settings[:api_key].blank? || parsed_settings[:api_key] == "-"
          Synchrony::Logger.info "Please supply API Key before synchronization"
          return
        end

        if remote_cf_for_author_id.blank?
          Synchrony::Logger.info "Please supply Remote CF for Author ID before synchronization"
          return
        end

        if remote_task_url_id.blank?
          Synchrony::Logger.info "Please supply Remote Task URL ID before synchronization"
          return
        end

        if synchronizable_switch_id.blank?
          Synchrony::Logger.info "Please supply Synchronizable Switch ID before synchronization"
          return
        end

        unless check_local_resource(:trackers_set, :target_tracker)
          Synchrony::Logger.info "Please supply all target trackers before synchronization"
          return
        end

        unless check_local_resource(:issue_statuses_set, :target_issue_status)
          Synchrony::Logger.info "Please supply all target issue statuses before synchronization"
          return
        end

        unless check_local_resource(:issue_priorities_set, :target_issue_priority)
          Synchrony::Logger.info "Please supply all target issue priorities before synchronization"
          return
        end

        unless check_local_resource(:custom_fields_set, :target_custom_field)
          Synchrony::Logger.info "Please supply all target custom fields before synchronization"
          return
        end

        if project_data[:sync] != "true"
          Synchrony::Logger.info "Synchronization is disabled for Project '#{project_data[:local_project]}'"
          return
        end

        if tracker_data[:sync] != "true"
          Synchrony::Logger.info "Synchronization is disabled for Tracker '#{tracker_data[:local_tracker]}'"
          return
        end

        if issue_status_data[:sync] != "true"
          Synchrony::Logger.info "Synchronization is disabled for Status '#{issue_status_data[:local_issue_status]}'"
          return
        end

        if issue_priority_data[:sync] != "true"
          Synchrony::Logger.info "Synchronization is disabled for Priority '#{issue_priority_data[:local_issue_priority]}'"
          return
        end

        if target_assigned_to_id.blank?
          Synchrony::Logger.info "User assigned to issue (#{issue.assigned_to.name}) didn't set a Remote User ID"
          return
        end

        if target_author_id.blank?
          Synchrony::Logger.info "Author (#{issue.author.name}) didn't set a Remote User ID"
          return
        end

        prepare_remote_resources

        Synchrony::Logger.info "SITE SETTINGS ARE PRESENT. PUSHING issue #{issue.subject}"
        Synchrony::Logger.info ""

        if not_synchronizable_old_record?
          Synchrony::Logger.info "Issue #{issue.subject} marked as non-synchronizable. Turning it off on remote."
          turn_off_remote_synchronization
        else
          push_issue
        end

        Synchrony::Logger.info "#{issue.project.name}: #{issue.subject} PUSH FINISHED"
        Synchrony::Logger.info "====================================================="
      rescue ActiveResource::TimeoutError => e
        Synchrony::Logger.info "Timeout error: #{e.message}"
      end

      attr_reader :issue

      private

      def parsed_settings
        @parsed_settings ||= Setting.plugin_redmine_synchrony&.deep_symbolize_keys
      end

      def not_synchronizable_new_record?
        !synchronizable? && new_record?
      end

      def not_synchronizable_old_record?
        !synchronizable? && !new_record?
      end

      def new_record?
        issue.created_on == issue.updated_on
      end

      def synchronizable?
        issue.custom_field_values.detect { |cf| cf.custom_field.name == "synchronizable" }&.value == "1"
      end

      def project_data
        parsed_settings[:projects_set].detect do |s|
          s[:local_project] == issue.project.name
        end
      end

      def tracker_data
        parsed_settings[:trackers_set].detect do |s|
          s[:local_tracker] == issue.tracker.name
        end
      end

      def issue_status_data
        parsed_settings[:issue_statuses_set].detect do |s|
          s[:local_issue_status] == issue.status.name
        end
      end

      def issue_priority_data
        parsed_settings[:issue_priorities_set].detect do |s|
          s[:local_issue_priority] == issue.priority.name
        end
      end

      def local_project
        @local_project ||= issue.project
      end

      def local_tracker
        @local_tracker ||= issue.tracker
      end

      def local_issue_status
        @local_issue_status ||= issue.status
      end

      def local_issue_priority
        @local_issue_priority ||= issue.priority
      end

      def target_project
        @target_project ||= RemoteProject.all.find do |t|
          sanitize_input(t.name) == sanitize_input(project_data[:target_project])
        end
      end

      def target_tracker
        @target_tracker ||= RemoteTracker.all.find do |t|
          sanitize_input(t.name) == sanitize_input(tracker_data[:target_tracker])
        end
      end

      def target_issue_status
        @target_issue_status ||= RemoteIssueStatus.all.find do |t|
          sanitize_input(t.name) == sanitize_input(issue_status_data[:target_issue_status])
        end
      end

      def target_issue_priority
        @target_issue_priority ||= RemoteIssuePriority.all.find do |t|
          sanitize_input(t.name) == sanitize_input(issue_priority_data[:target_issue_priority])
        end
      end

      def remote_custom_fields
        @remote_custom_fields ||= RemoteCustomField.all
      end

      def sanitize_input(input)
        input.mb_chars.strip
      end

      def target_assigned_to_id
        @target_assigned_to_id ||= fetch_remote_user_id(issue.assigned_to)
      end

      def target_author_id
        @target_author_id ||= fetch_remote_user_id(issue.author)
      end

      def remote_cf_for_author_id
        @remote_cf_for_author_id ||= parsed_settings[:remote_cf_for_author]
      end

      def remote_task_url_id
        @remote_task_url_id ||= parsed_settings[:remote_task_url]
      end

      def synchronizable_switch_id
        @synchronizable_switch_id ||= parsed_settings[:synchronizable_switch]
      end

      def fetch_remote_user_id(user)
        user&.custom_field_values&.detect { |cf| cf.custom_field.name == "Remote User ID" }&.value
      end

      def check_local_resource(set, target_field)
        parsed_settings[set]
          .select { |ps| ps[:sync] == "true" }
          .all? { |ps| ps[target_field].present? }
      end

      def prepare_remote_resources
        REMOTE_CLASSES.each do |resource_class|
          resource_class.site = target_site
          resource_class.headers['X-Redmine-API-Key'] = api_key
        end
      end

      def target_site
        @target_site ||= if parsed_settings[:target_site].end_with?("/")
                           parsed_settings[:target_site]
                         else
                           "#{parsed_settings[:target_site]}/"
                         end
      end

      def api_key
        @api_key ||= parsed_settings[:api_key]
      end

      def generate_issue_url
        "#{parsed_settings[:local_site]}/issues/#{issue.id}"
      end

      def turn_off_remote_synchronization
        attributes = {
          custom_fields: [
            { id: synchronizable_switch_id, value: "0" },
          ]
        }

        remote_issue = RemoteIssue.find(issue.synchrony_id)

        remote_issue.update_attributes(attributes)
      rescue ActiveResource::ResourceNotFound
        Synchrony::Logger.info "Remote issue #{issue.synchrony_id} not found. Skipping."
      end

      def push_issue
        custom_fields = [
          { id: remote_cf_for_author_id, value: target_author_id.to_i },
          { id: remote_task_url_id, value: generate_issue_url },
          { id: synchronizable_switch_id, value: "1" },
        ]

        custom_fields = parse_custom_fields(custom_fields)

        attributes = {
          subject:         issue.subject,
          description:     issue.description,
          start_date:      issue.start_date,
          due_date:        issue.due_date,
          done_ratio:      issue.done_ratio,
          estimated_hours: issue.estimated_hours,
          updated_on:      issue.updated_on,
          priority_id:     target_issue_priority.id,
          status_id:       target_issue_status.id,
          project_id:      target_project.id,
          tracker_id:      target_tracker.id,
          assigned_to_id:  target_assigned_to_id,
          custom_fields:   custom_fields,
        }

        Synchrony::Logger.info '---'
        Synchrony::Logger.info 'PUSHING attributes'
        Synchrony::Logger.info attributes

        begin
          remote_issue = RemoteIssue.find(issue.synchrony_id, params: { include: %i[journals attachments] })

          if remote_issue.update_attributes(attributes)
            issue.update_columns(synchronized_at: DateTime.current)

            notes = fetch_new_journal_entries(issue, remote_issue)

            if notes.any?
              notes.each do |note|
                remote_issue.update_attributes(notes: note[:text])

                r_i = RemoteIssue.find(remote_issue.id, params: { include: :journals })

                Journal.find_by(id: note[:id])&.update_columns(synchrony_id: r_i.journals.last.id)
              end
            end

            attachments = issue.attachments.select { |a| a.synchrony_id.blank? }

            if attachments.any?
              attachments.each do |attachment|
                file = File.open(attachment.diskfile)
                response = upload_file(file)

                if response.status == 201 && token = JSON.parse(response.body).dig("upload", "token")
                  remote_issue.update_attributes(
                    uploads: [
                      {
                        token:        token,
                        filename:     attachment.filename,
                        content_type: attachment.content_type,
                      }
                    ]
                  )

                  r_i = RemoteIssue.find(remote_issue.id, params: { include: :attachments })

                  Attachment.find_by(id: attachment.id)&.update_columns(synchrony_id: r_i.attachments.last.id)
                else
                  Synchrony::Logger.info "Attachment #{attachment.id} could not be synced:"
                  Synchrony::Logger.info "Status: #{response.status}"
                  Synchrony::Logger.info "Body: #{response.body}"

                  next
                end
              end
            end
          else
            Synchrony::Logger.info "Issue #{issue.id} could not be synced: #{remote_issue.errors.full_messages}"
          end
        rescue ActiveResource::ResourceNotFound
          new_remote_issue = RemoteIssue.new(attributes)

          if new_remote_issue.save!
            issue.update_columns(synchrony_id: new_remote_issue.id, synchronized_at: DateTime.current)
          else
            Synchrony::Logger.info "Issue #{issue.id} could not be synced: #{new_remote_issue.errors.full_messages}"
          end
        end
      rescue ActiveResource::ResourceInvalid => e
        Synchrony::Logger.info "Issue export failed with error: "
        Synchrony::Logger.info e.class
        Synchrony::Logger.info e.message
        Synchrony::Logger.info "Most propably because author was not added to project members on instance B."
      end

      def parse_custom_fields(custom_fields)
        issue.custom_field_values.each do |cfv|
          next unless custom_field_synchronizable?(cfv.custom_field)

          mapped_cf_data = parsed_settings[:custom_fields_set].detect do |set|
            cfv.custom_field.name == set[:local_custom_field]
          end

          remote_cf = remote_custom_fields.detect do |rcf|
            sanitize_input(rcf.name) == sanitize_input(mapped_cf_data[:target_custom_field])
          end

          if remote_cf.blank?
            Synchrony::Logger.info "Custom field #{cfv.custom_field.name} not found on remote instance. Skipping."
            Synchrony::Logger.info ""

            next
          end

          if remote_cf.attributes["possible_values"].present?
            possible_values = remote_cf.attributes["possible_values"].map { _1.attributes["value"] }

            if remote_cf.attributes["multiple"] == "true"
              if cfv.value.is_a?(Array)
                common_values = possible_values & cfv.value

                custom_fields << { id: remote_cf.id, value: common_values.any? ? common_values : nil }
              else
                Synchrony::Logger.info "Value for custom field #{cfv.custom_field.name} is not an array. Skipping."
                Synchrony::Logger.info ""

                next
              end
            elsif possible_values.include?(cfv.value)
              custom_fields << { id: remote_cf.id, value: cfv.value }
            else
              Synchrony::Logger.info "Value (#{cfv.value}) for custom field #{cfv.custom_field.name} is not in possible values. Skipping."
              Synchrony::Logger.info ""

              next
            end
          elsif remote_cf.attributes["field_format"] == "user" && remote_cf.attributes["multiple"] == "true"
            if cfv.value.is_a?(Array)
              users = User.where(id: cfv.value)
              value = users.map { |u| fetch_remote_user_id(u) }

              custom_fields << { id: remote_cf.id, value: value }
            else
              Synchrony::Logger.info "Value for custom field #{cfv.custom_field.name} is not an array. Skipping."
              Synchrony::Logger.info ""

              next
            end
          elsif remote_cf.attributes["field_format"] == "user"
            if cfv.value.is_a?(Array)
              Synchrony::Logger.info "Value for custom field #{cfv.custom_field.name} is an array. Skipping."
              Synchrony::Logger.info ""

              next
            else
              user = User.find(cfv.value)
              value = fetch_remote_user_id(user)

              custom_fields << { id: remote_cf.id, value: value }
            end
          elsif custom_field_string_validation?(remote_cf)
            regexp     = remote_cf.attributes["regexp"].presence
            min_length = remote_cf.attributes["min_length"].presence
            max_length = remote_cf.attributes["max_length"].presence

            regexp_matches     = regexp.blank? || (regexp.present? && cfv.value.match?(Regexp.new(regexp)))
            min_length_matches = min_length.blank? || (min_length.present? && cfv.value.length >= min_length.to_i)
            max_length_matches = max_length.blank? || (max_length.present? && cfv.value.length <= max_length.to_i)

            if regexp.present? && !regexp_matches
              Synchrony::Logger.info "Value for custom field #{cfv.custom_field.name} does not match regexp. Skipping."
              Synchrony::Logger.info ""
            end

            if min_length.present? && !min_length_matches
              Synchrony::Logger.info "Value for custom field #{cfv.custom_field.name} is too short. Skipping."
              Synchrony::Logger.info ""
            end

            if max_length.present? && !max_length_matches
              Synchrony::Logger.info "Value for custom field #{cfv.custom_field.name} is too long. Skipping."
              Synchrony::Logger.info ""
            end

            next if !regexp_matches || !min_length_matches || !max_length_matches

            custom_fields << { id: remote_cf.id, value: cfv.value }
          else
            custom_fields << { id: remote_cf.id, value: cfv.value }
          end
        end

        custom_fields
      end

      def custom_field_string_validation?(remote_cf)
        remote_cf.attributes["regexp"].present? ||
          remote_cf.attributes["min_length"].present? ||
          remote_cf.attributes["max_length"].present?
      end

      def custom_field_synchronizable?(custom_field)
        return false if base_custom_field?(custom_field)

        cf_data = parsed_settings[:custom_fields_set].detect do |set|
          custom_field.name == set[:local_custom_field]
        end

        cf_data[:sync] == "true"
      end

      def base_custom_field?(custom_field)
        ["synchronizable", "Remote User ID"].include?(custom_field.name)
      end

      def upload_file(file)
        conn = Faraday.new(url: upload_url) do |faraday|
          faraday.adapter :net_http
        end

        conn.post do |req|
          req.headers['Content-Type'] = 'application/octet-stream'
          req.headers["Content-Length"] = file.size.to_s
          req.headers["X-Redmine-API-Key"] = parsed_settings[:api_key]
          req.body = file
        end
      end

      def upload_url
        "#{parsed_settings[:target_site]}/uploads.json"
      end

      def fetch_new_journal_entries(issue, remote_issue)
        journal_notes = issue.journals.select do |j|
          j.synchrony_id.blank? && !j.private_notes && j.notes.present?
        end

        remote_journal_notes = remote_issue.journals.select do |j|
          j.notes.present? && j.private_notes == "false" && j.notes.exclude?(journal_mark)
        end

        return [] if journal_notes.empty?

        return journal_notes.map { |jn| parse_our_note(jn) } if remote_journal_notes.empty?

        journal_notes.filter_map do |journal|
          next if remote_journal_notes.any? { |rjn| rjn.notes.include?(journal.notes) }

          parse_our_note(journal)
        end
      end

      def parse_our_note(journal)
        {
          id:   journal.id,
          text: "*#{journal.user.firstname} #{journal.user.lastname}* #{journal_mark}#{journal.notes}"
        }
      end

      def journal_mark
        "napisał(a):\n\n"
      end
    end
  end
end
