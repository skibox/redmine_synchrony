module Synchrony
  module Synchronize
    class Push
      REMOTE_CLASSES = [
        RemoteTracker,
        RemoteIssue,
        RemoteIssueStatus,
        RemoteIssuePriority,
        RemoteProject,
        RemoteIssue::Relation,
        RemoteIssue::Watcher,
      ].freeze

      def initialize(issue)
        @issue ||= Issue
                    .includes(
                      :status, :priority,
                      :attachments, :journals, 
                      relations_to: :issue_to,
                      relations_from: :issue_from,
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

        if local_synchronizable_switch.blank?
          Synchrony::Logger.info "Please supply Local issue Synchronizable Switch ID before synchronization"
          Synchrony::Logger.info ""

          return
        end

        if local_remote_url.blank?
          Synchrony::Logger.info "Please supply Local remote URL before synchronization"
          Synchrony::Logger.info ""

          return
        end

        if local_last_sync_successful.blank?
          Synchrony::Logger.info "Please supply Local last sync successful before synchronization"
          Synchrony::Logger.info ""

          return
        end

        if remote_synchronizable_switch_id.blank?
          Synchrony::Logger.info "Please supply Remote Synchronizable Switch ID before synchronization"
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

        if issue_status_data.blank?
          Synchrony::Logger.info "Issue Status '#{issue.status.name}' not found in configuration"
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
          Synchrony::Logger.info "User assigned to issue (#{issue.assigned_to.name}) didn't set a Remote User ID."
          Synchrony::Logger.info "Setting to Local default assignee Remote ID."
          Synchrony::Logger.info ""

          remote_default_user_id = fetch_default_remote_user_id

          if remote_default_user_id.blank?
            Synchrony::Logger.info "..."
            Synchrony::Logger.info "Local default assignee also didn't set a Remote User ID... Skipping."
            return
          end

          @target_assigned_to_id = remote_default_user_id
        end

        if target_author_id.blank?
          Synchrony::Logger.info "Author (#{issue.author.name}) didn't set a Remote User ID."
          Synchrony::Logger.info "Setting to Local default assignee Remote ID"
          Synchrony::Logger.info ""

          remote_default_author_id = fetch_default_remote_user_id

          if remote_default_author_id.blank?
            Synchrony::Logger.info "..."
            Synchrony::Logger.info "Local default assignee also didn't set a Remote User ID... Skipping."
            return
          end

          @target_author_id = remote_default_author_id
        end

        prepare_remote_resources

        Synchrony::Logger.info "SITE SETTINGS ARE PRESENT. PUSHING issue #{issue.subject}"
        Synchrony::Logger.info ""

        if not_synchronizable_old_record?
          Synchrony::Logger.info "Issue #{issue.subject} marked as non-synchronizable. Turning it off on remote."
          turn_off_remote_synchronization
        else
          ActiveRecord::Base.transaction { push_issue }
        end

        Synchrony::Logger.info "#{issue.project.name}: #{issue.subject} PUSH FINISHED"
        Synchrony::Logger.info "====================================================="
      rescue ActiveResource::TimeoutError => e
        Synchrony::Logger.info "Timeout error: #{e.message}"
      rescue StandardError => e
        Synchrony::Logger.info "================"
        Synchrony::Logger.info "HTTP 500"
        Synchrony::Logger.info "PUSH ERROR"
        Synchrony::Logger.info e.message
        Synchrony::Logger.info "Backtrace:"
        e.backtrace.each { |line| Synchrony::Logger.info line }
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

      def local_synchronizable_switch
        @local_synchronizable_switch ||= IssueCustomField.find_by(id: parsed_settings[:local_synchronizable_switch])
      end

      def local_remote_url
        @local_remote_url ||= IssueCustomField.find_by(id: parsed_settings[:local_remote_url])
      end

      def local_last_sync_successful
        @local_last_sync_successful ||= IssueCustomField.find_by(id: parsed_settings[:local_last_sync_successful])
      end

      def synchronizable?
        issue.custom_field_values.detect { |cf| cf.custom_field == local_synchronizable_switch }&.value == "1"
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
          s[:local_issue_priority_id] == issue.priority.id.to_s
        end
      end

      def local_users
        @local_users ||= User.all
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

      def principal_custom_values
        @principal_custom_values ||= CustomValue
                                      .where(
                                        customized_type: "Principal",
                                        custom_field_id: remote_user_id_cf,
                                      )
                                      .where.not(value: nil)
      end

      def remote_user_id_cf
        @remote_user_id_cf ||= CustomField.find_by(
          name: "Remote User ID",
        )
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

      def fetch_default_remote_user_id
        principal_custom_values.detect do |pcv|
          pcv.customized_id.to_s == local_default_user_id
        end&.value
      end

      def local_default_user_id
        parsed_settings[:local_default_assignee]
      end

      def remote_task_url_id
        @remote_task_url_id ||= parsed_settings[:remote_task_url]
      end

      def remote_synchronizable_switch_id
        @remote_synchronizable_switch_id ||= parsed_settings[:remote_synchronizable_switch]
      end

      def fetch_remote_user_id(user)
        user&.custom_field_values&.detect { |cf| cf.custom_field.name == "Remote User ID" }&.value
      end

      def check_local_resource(set, target_field)
        target_set = parsed_settings[set]

        return true unless target_set

        target_set
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

      def generate_remote_issue_url(remote_issue)
        "#{parsed_settings[:target_site]}/issues/#{remote_issue.id}"
      end

      def turn_off_remote_synchronization
        attributes = {
          custom_fields: [
            { id: remote_synchronizable_switch_id, value: "0" },
          ]
        }

        remote_issue = RemoteIssue.find(issue.synchrony_id)

        remote_issue.update_attributes(attributes)
      rescue ActiveResource::ResourceNotFound
        Synchrony::Logger.info "Remote issue #{issue.synchrony_id} not found. Skipping."
      end

      def push_issue
        issue.skip_synchronization = true
        
        custom_fields = [
          { id: remote_cf_for_author_id, value: target_author_id.to_i },
          { id: remote_task_url_id, value: generate_issue_url },
          { id: remote_synchronizable_switch_id, value: "1" },
        ]

        custom_fields = parse_custom_fields(custom_fields)

        parent_issue_id = Issue.find_by(id: issue.parent_id)&.synchrony_id

        attributes = {
          subject:         issue.subject,
          description:     issue.description,
          done_ratio:      issue.done_ratio,
          estimated_hours: issue.estimated_hours,
          updated_on:      issue.updated_on,
          priority_id:     target_issue_priority.id,
          status_id:       target_issue_status.id,
          project_id:      target_project.id,
          tracker_id:      target_tracker.id,
          assigned_to_id:  target_assigned_to_id,
          parent_issue_id: parent_issue_id,
          custom_fields:   custom_fields,
        }

        Synchrony::Logger.info '---'
        Synchrony::Logger.info 'PUSHING attributes'
        Synchrony::Logger.info attributes

        begin
          remote_issue = RemoteIssue.find(
            issue.synchrony_id,
            params: { include: %i[journals attachments relations] }
          )

          if remote_issue.respond_to?(:parent) && parent_issue_id.blank?
            our_parent_issue = Issue.find_by(synchrony_id: remote_issue.parent.id)

            our_parent_issue.skip_synchronization = true

            attributes[:parent_issue_id] = remote_issue.parent.id

            issue.update!(parent_id: our_parent_issue.id) if our_parent_issue.present?
          end

          if remote_issue.update_attributes(attributes)
            issue.update_columns(synchronized_at: DateTime.current)

            issue.update(
              custom_fields: [
                { id: local_remote_url.id, value: generate_remote_issue_url(remote_issue) },
              ]
            )

            attachments = issue.attachments.select { |a| a.synchrony_id.blank? }

            import_attachments(attachments, remote_issue)

            notes = fetch_new_journal_entries(issue, remote_issue)

            import_notes(notes, remote_issue)

            link_new_detailed_journal_entry(issue, remote_issue)

            import_relations(issue, remote_issue)

            import_watchers(issue, remote_issue)
          else
            issue.update(
              custom_fields: [
                { id: local_last_sync_successful.id, value: "0" }
              ]
            )

            Synchrony::Logger.info "Issue #{issue.id} could not be synced: #{remote_issue.errors}"
            return
          end
        rescue ActiveResource::ResourceNotFound
          attributes[:start_date] = issue.start_date
          attributes[:due_date] = issue.due_date

          new_remote_issue = RemoteIssue.new(attributes)

          if new_remote_issue.save!
            issue.update_columns(synchrony_id: new_remote_issue.id, synchronized_at: DateTime.current)

            issue.update(
              custom_fields: [
                { id: local_remote_url.id, value: generate_remote_issue_url(new_remote_issue) },
              ]
            )

            attachments = issue.attachments.select { |a| a.synchrony_id.blank? }

            import_attachments(attachments, new_remote_issue)

            import_watchers(issue, remote_issue)
          else
            issue.update(
              custom_fields: [
                { id: local_last_sync_successful.id, value: "0" },
              ]
            )

            Synchrony::Logger.info "Issue #{issue.id} could not be synced: #{new_remote_issue.errors}"
            return
          end
        end

        issue.update(custom_fields: [{ id: local_last_sync_successful.id, value: "1" }])
      rescue ActiveResource::ResourceInvalid => e
        Synchrony::Logger.info "Issue export failed with error: "
        Synchrony::Logger.info e.class
        Synchrony::Logger.info e.message
        Synchrony::Logger.info "Most propably because author was not added to project members on instance B, "\
                               "or due to custom fields mismatch."
      end

      def parse_custom_fields(custom_fields)
        issue.custom_field_values.each do |cfv|
          next unless custom_field_synchronizable?(cfv.custom_field)

          next if issue.created_on == issue.updated_on && (cfv.value.blank? || cfv.value == [""])

          mapped_cf_data = parsed_settings[:custom_fields_set].detect do |set|
            cfv.custom_field.name == set[:local_custom_field]
          end

          remote_id = mapped_cf_data[:target_custom_field]


          if cfv.custom_field.field_format == "user" && cfv.custom_field.multiple
            users = local_users.select { |lu| cfv.value.include?(lu.id.to_s) }
            value = users.map { |u| fetch_remote_user_id(u) }.compact

            value == [] ? value = "" : value

            custom_fields << { id: remote_id, value: value }
          elsif cfv.custom_field.field_format == "user"
            user = local_users.detect { |lu| lu.id.to_s == cfv.value.to_s }
            value = fetch_remote_user_id(user)

            custom_fields << { id: remote_id, value: value || "" }
          else
            custom_fields << { id: remote_id, value: cfv.value }
          end
        end

        custom_fields
      end

      def import_attachments(attachments, remote_issue)
        attachments.each do |attachment|
          file = File.open(attachment.diskfile)
          Synchrony::Logger.info "Uploading file #{file.path}"
          Synchrony::Logger.info ""

          response = upload_file(file)

          Synchrony::Logger.info "-------------------------------"
          Synchrony::Logger.info ""

          if response.status == 201 && token = JSON.parse(response.body).dig("upload", "token")
            remote_issue.update_attributes(
              uploads: [
                {
                  token:        token,
                  filename:     attachment.filename,
                  content_type: attachment.content_type,
                  description:  attachment.description,
                }
              ]
            )

            r_i = RemoteIssue.find(remote_issue.id, params: { include: :attachments })

            Attachment.find_by(id: attachment.id)&.update_columns(synchrony_id: r_i.attachments.last.id)

          else
            issue.update(
              custom_fields: [
                { id: local_last_sync_successful.id, value: "0" }
              ]
            )

            Synchrony::Logger.info "Attachment #{attachment.id} could not be synced:"
            Synchrony::Logger.info "Status: #{response.status}"
            Synchrony::Logger.info "Body: #{response.body}"

            next
          end
        end
      end

      def import_relations(our_issue, remote_issue)
        Rails.logger.info "Updating relations for issue #{our_issue.id}:"

        incoming_relations = remote_issue.respond_to?(:relations) ? remote_issue.relations : []
        incoming_relations_attributes = incoming_relations.map(&:attributes)

        incoming_remote_issue_to_ids = incoming_relations_attributes.pluck("issue_to_id")
        incoming_remote_issue_from_ids = incoming_relations_attributes.pluck("issue_id")

        incoming_our_issues = Issue.where(
          synchrony_id: incoming_remote_issue_to_ids + incoming_remote_issue_from_ids,
        )

        incoming_our_issues_to = incoming_our_issues.select { |i| incoming_remote_issue_to_ids.include?(i.synchrony_id.to_s) }
        incoming_our_issues_from = incoming_our_issues.select { |i| incoming_remote_issue_from_ids.include?(i.synchrony_id.to_s) }

        mapped_incoming_relations_attributes = incoming_relations_attributes.map do |relation|
          incoming_our_issue_to = incoming_our_issues_to.detect do |i|
            i.synchrony_id.to_s == relation["issue_to_id"]
          end

          if incoming_our_issue_to.blank?
            Rails.logger.info "Issue with Remote ID #{relation["issue_to_id"]} not found. Skipping."

            next
          end

          incoming_our_issue_from = incoming_our_issues_from.detect do |i|
            i.synchrony_id.to_s == relation["issue_id"]
          end

          if incoming_our_issue_from.blank?
            Rails.logger.info "Issue with Remote ID #{relation["issue_from_id"]} not found. Skipping."

            next
          end

          {
            "relation_type" => relation["relation_type"],
            "issue_from_id" => incoming_our_issue_from.synchrony_id.to_s,
            "issue_to_id"   => incoming_our_issue_to.synchrony_id.to_s,
            "delay"         => relation["delay"] || "",
          }
        end.compact

        mapped_incoming_relations_attributes = mapped_incoming_relations_attributes.sort_by do |r|
          "#{r["relation_type"]}-#{r["issue_from_id"]}-#{r["issue_to_id"]}"
        end

        all_our_relations = our_issue.relations_to + our_issue.relations_from

        current_relations = all_our_relations.map do |r|
          next if r.issue_to.synchrony_id.blank? || r.issue_from.synchrony_id.blank?

          {
            "relation_type" => r.relation_type,
            "issue_from_id" => r.issue_from.synchrony_id.to_s,
            "issue_to_id"   => r.issue_to.synchrony_id.to_s,
            "delay"         => r.delay || "",
          }
        end.compact

        current_relations_attributes = current_relations.sort_by do |r|
          "#{r["relation_type"]}-#{r["issue_from_id"]}-#{r["issue_to_id"]}"
        end
        
        return if mapped_incoming_relations_attributes == current_relations_attributes

        
        relations_attributes_to_delete = mapped_incoming_relations_attributes - current_relations_attributes
        
        relations_attributes_to_delete.each do |attributes|
          remote_relation = incoming_relations.detect do |r|
            r.relation_type == attributes["relation_type"] &&
            r.issue_id == attributes["issue_from_id"] &&
            r.issue_to_id == attributes["issue_to_id"] &&
            r.delay == attributes["delay"]
          end
          
          remote_relation&.destroy
        end

        relations_attributes_to_add = if mapped_incoming_relations_attributes.any? 
                                        current_relations_attributes - mapped_incoming_relations_attributes
                                      else
                                        current_relations_attributes
                                      end

        new_relations = relations_attributes_to_add.each do |attributes|
          conn = Faraday.new(url: "#{target_site}issues/#{attributes["issue_from_id"]}/relations.json") do |faraday|
            faraday.response :logger,
                             Synchrony::Logger,
                             { headers: true, bodies: true, errors: true, log_level: :debug }
          end

          body = {
            relation: {
              relation_type: attributes["relation_type"],
              issue_to_id:   attributes["issue_to_id"],
              delay:         attributes["delay"],
            }
          }
          
          post_body = body.to_json

          conn.post do |req|
            req.options.timeout              = 5
            req.headers['Content-Type']      = 'application/json'
            req.headers["X-Redmine-API-Key"] = parsed_settings[:api_key]
            req.body                         = post_body
          end
        end
      end

      def import_watchers(our_issue, remote_issue)
        Rails.logger.info "Updating watchers for issue #{our_issue.id}:"

        remote_issue = RemoteIssue.find(remote_issue.id, params: { include: :watchers })

        incoming_remote_watchers = remote_issue.watchers.map(&:attributes)

        incoming_remote_watchers_ids = incoming_remote_watchers.pluck("id")

        incoming_watchers_principals = principal_custom_values.select do |pcv|
          incoming_remote_watchers_ids.include?(pcv.value)
        end

        current_watchers = our_issue.watchers

        current_watchers_ids = current_watchers.pluck(:user_id)

        current_watchers_principals = principal_custom_values.select do |pcv|
          current_watchers_ids.include?(pcv.customized_id)
        end

        current_watchers_remote_ids = current_watchers_principals.map(&:value)

        return if incoming_remote_watchers_ids.sort == current_watchers_remote_ids.sort

        watchers_to_delete = incoming_remote_watchers_ids - current_watchers_remote_ids
        watchers_to_add = current_watchers_remote_ids - incoming_remote_watchers_ids

        watchers_to_delete.each do |user_id|
          conn = Faraday.new(url: "#{target_site}issues/#{remote_issue.id}/watchers/#{user_id}.json") do |faraday|
            faraday.response :logger,
                             Synchrony::Logger,
                             { headers: true, bodies: true, errors: true, log_level: :debug }
          end

          conn.delete do |req|
            req.options.timeout              = 5
            req.headers['Content-Type']      = 'application/json'
            req.headers["X-Redmine-API-Key"] = parsed_settings[:api_key]
          end
        end

        begin
          conn = Faraday.new(url: "#{target_site}issues/#{remote_issue.id}/watchers.json") do |faraday|
            faraday.response :logger,
                              Synchrony::Logger,
                              { headers: true, bodies: true, errors: true, log_level: :debug }
          end

          body = {
            watcher: {
              user_ids: watchers_to_add,
            }
          }

          post_body = body.to_json

          conn.post do |req|
            req.options.timeout              = 5
            req.headers['Content-Type']      = 'application/json'
            req.headers["X-Redmine-API-Key"] = parsed_settings[:api_key]
            req.body                         = post_body
          end
        rescue StandardError
          Synchrony::Logger.info "One of the watchers could not be added to issue #{remote_issue.id}"
        end
      end

      def import_notes(notes, remote_issue)
        notes.each do |note|
          copied_issue = nil

          unless remote_issue.update_attributes(notes: note[:text])
            copied_issue = RemoteIssue.find(remote_issue.id, params: { include: :journals })
            copied_issue.update_attributes(notes: note[:text])
            # don't ask, please
          end

          r_i = copied_issue || RemoteIssue.find(remote_issue.id, params: { include: :journals })

          Journal.find_by(id: note[:id])&.update_columns(
            created_on: Time.zone.parse(r_i.journals.last.created_on.to_s),
            synchrony_id: r_i.journals.last.id,
          )
        end
      end

      def custom_field_synchronizable?(custom_field)
        return false if base_custom_field?(custom_field)

        cf_data = parsed_settings[:custom_fields_set].detect do |set|
          custom_field.name == set[:local_custom_field]
        end

        return false if cf_data.blank?

        cf_data[:sync] == "true"
      end

      def base_custom_field?(custom_field)
        [
          local_synchronizable_switch.name,
          local_remote_url.name,
          remote_user_id_cf.name,
          local_last_sync_successful.name,
        ].include?(custom_field.name)
      end

      def upload_file(file)
        conn = Faraday.new(url: upload_url) do |faraday|
          faraday.response :logger,
                           Synchrony::Logger,
                           { headers: true, bodies: true, errors: true, log_level: :debug }
        end

        conn.post do |req|
          req.options.timeout              = 5
          req.headers['Content-Type']      = 'application/octet-stream'
          req.headers["X-Redmine-API-Key"] = parsed_settings[:api_key]
          req.headers["Content-Length"]    = file.size.to_s
          req.body                         = file
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

        journal_notes.map do |journal|
          next if remote_journal_notes.any? { |rjn| rjn.notes.include?(journal.notes) }

          parse_our_note(journal)
        end.compact
      end

      def link_new_detailed_journal_entry(issue, remote_issue)
        last_journal = issue.journals.last

        return if last_journal.notes.present?

        reloaded_remote_issue = RemoteIssue.find(remote_issue.id, params: { include: :journals })

        last_remote_note = reloaded_remote_issue.journals.last

        last_journal.update_columns(
          synchrony_id: last_remote_note.id,
          created_on: Time.zone.parse(last_remote_note.created_on.to_s),
        )
      end

      def parse_our_note(journal)
        parsed_text = parse_visual_editor(journal.notes)
        text = "*#{journal.user.firstname} #{journal.user.lastname}* #{journal_mark}#{parsed_text}"

        {
          id:   journal.id,
          text: text,
        }
      end

      def journal_mark
        "napisał(a):\n\n"
      end

      def parse_visual_editor(notes)
        return notes unless /user#\d+/.match?(notes)

        notes.gsub(/user#\d+/) do |user_id|
          user = local_users.detect { |lu| lu.id.to_s == user_id.split("#").last }

          remote_user_id = fetch_remote_user_id(user)

          if user && remote_user_id
            "user##{remote_user_id}"
          elsif user
            "#{user.firstname} #{user.lastname}"
          else
            "<undefined>"
          end
        end
      end
    end
  end
end
