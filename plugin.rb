# frozen_string_literal: true

# name: discourse-auto-researcher
# about: Automation script that calls OpenAI Responses API and creates a new topic with the result
# version: 0.1.0
# authors: Dylan Wardlow | Cognifai Technologies Lab
# url: https://github.com/MachineSch01ar/discourse-auto-researcher
# required_version: 3.3.0

enabled_site_setting :auto_researcher_enabled

after_initialize do
  if defined?(DiscourseAutomation)
    AUTO_RESEARCHER = "auto_researcher"

    add_automation_scriptable(AUTO_RESEARCHER) do
      version 1
      triggerables [:recurring]

      # -------- Script Options (fields) --------
      field :creator, component: :user, required: true
      field :variables, component: :json, required: false
      field :prompt, component: :text, required: true
      field :model, component: :text, required: true
      field :system_prompt, component: :text, required: false
      field :poll_timing_seconds, component: :number, required: false
      field :send_pm_user, component: :user, required: false
      field :category, component: :category, required: true

      # Common Responses API params (optional)
      field :temperature, component: :number, required: false
      field :top_p, component: :number, required: false
      field :max_output_tokens, component: :number, required: false
      field :presence_penalty, component: :number, required: false
      field :frequency_penalty, component: :number, required: false
      field :seed, component: :number, required: false
      field :stop, component: :text, required: false

      field :reasoning_effort, component: :choices, required: false,
            extra: { choices: %w[low medium high] }

      # Built-in web search tool (optional)
      field :web_search_enabled, component: :boolean, required: false
      field :web_search_depth, component: :choices, required: false,
            extra: { choices: %w[quick deep] }
      field :web_search_results, component: :number, required: false
      field :web_search_include_sources, component: :boolean, required: false

      # Advanced catch-all for ANY Responses API parameters (JSON object)
      field :responses_api_overrides, component: :json, required: false

      # -------- Script Body --------
      script do |context, fields, automation|
        require "net/http"
        require "uri"
        require "json"

        def read_field(fields, key)
          fields.dig(key.to_s, "value")
        end

        # Resolve creator
        creator_val = read_field(fields, :creator)
        creator =
          if creator_val.is_a?(Hash) && creator_val["id"]
            User.find(creator_val["id"])
          else
            User.find_by_username(creator_val) || Discourse.system_user
          end

        # Resolve category
        category_id = read_field(fields, :category).to_i
        category = Category.find(category_id)

        # Variables
        user_vars = read_field(fields, :variables) || {}
        user_vars = user_vars.transform_keys(&:to_s)

        # Built-in time helpers
        now = Time.zone.now
        builtins = {
          "now_iso" => now.utc.iso8601,
          "today" => now.strftime("%Y-%m-%d"),
          "week_start_iso" => now.beginning_of_week(:monday).utc.iso8601,
          "week_end_iso" => now.end_of_week(:sunday).utc.iso8601
        }
        vars = builtins.merge(user_vars)

        def substitute_vars(text, vars)
          return "" if text.blank?
          text.gsub(/\{\{\s*([a-zA-Z0-9_\-]+)\s*\}\}/) { |m| vars[$1] || "" }
        end

        system_prompt = substitute_vars(read_field(fields, :system_prompt).to_s, vars)
        user_prompt   = substitute_vars(read_field(fields, :prompt).to_s, vars)
        model         = read_field(fields, :model).to_s

        # Build the Responses API payload
        body = { model: model, input: [] }
        body[:input] << { role: "system", content: system_prompt } if system_prompt.present?
        body[:input] << { role: "user", content: user_prompt }

        # Common scalar parameters
        {
          temperature: :to_f, top_p: :to_f, max_output_tokens: :to_i,
          presence_penalty: :to_f, frequency_penalty: :to_f, seed: :to_i
        }.each do |k, caster|
          v = read_field(fields, k)
          body[k] = v.public_send(caster) if v.present?
        end

        stop = read_field(fields, :stop)
        body[:stop] = stop if stop.present?

        effort = read_field(fields, :reasoning_effort)
        body[:reasoning] = { effort: effort } if effort.present?

        if read_field(fields, :web_search_enabled)
          body[:tools] = [{ type: "web_search" }]
          body[:tool_config] = { web_search: {} }
          depth = read_field(fields, :web_search_depth)
          results = read_field(fields, :web_search_results)
          include_sources = read_field(fields, :web_search_include_sources)
          body[:tool_config][:web_search][:depth] = depth if depth.present?
          body[:tool_config][:web_search][:results] = results.to_i if results.present?
          body[:tool_config][:web_search][:sources] = !!include_sources unless include_sources.nil?
        end

        overrides = read_field(fields, :responses_api_overrides)
        body.merge!(overrides.symbolize_keys) if overrides.is_a?(Hash)

        # Credentials (from Discourse AI settings / site settings)
        api_key       = SiteSetting.try(:ai_openai_api_key).presence
        organization  = SiteSetting.try(:ai_openai_organization).presence
        project       = SiteSetting.try(:ai_openai_project).presence
        raise Discourse::InvalidParameters, "Missing OpenAI API key (configure in Admin > Plugins > AI)" if api_key.blank?

        def openai_request(path, method: :post, body: nil, api_key:, organization: nil, project: nil)
          uri = URI("https://api.openai.com/v1/#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 30
          http.read_timeout = 600

          headers = {
            "Authorization" => "Bearer #{api_key}",
            "Content-Type"  => "application/json",
          }
          headers["OpenAI-Organization"] = organization if organization
          headers["OpenAI-Project"]      = project if project

          req = method == :post ? Net::HTTP::Post.new(uri, headers) : Net::HTTP::Get.new(uri, headers)
          req.body = JSON.dump(body) if body
          res = http.request(req)
          { status: res.code.to_i, json: JSON.parse(res.body) }
        end

        # Create response (and optionally poll)
        create = openai_request("responses", method: :post, body: body,
                                api_key: api_key, organization: organization, project: project)

        response_id = create[:json]["id"]
        status      = create[:json]["status"]
        poll_every  = read_field(fields, :poll_timing_seconds).to_i
        poll_every  = 0 if poll_every.negative?

        while status != "completed" && poll_every > 0
          sleep(poll_every)
          r = openai_request("responses/#{response_id}", method: :get,
                             api_key: api_key, organization: organization, project: project)
          create = r
          status = r[:json]["status"]
        end

        result = create[:json]

        # Optionally PM the full raw JSON response
        if (pm_val = read_field(fields, :send_pm_user)).present?
          pm_user =
            if pm_val.is_a?(Hash) && pm_val["id"]
              User.find(pm_val["id"])
            else
              User.find_by_username(pm_val)
            end
          if pm_user
            PostCreator.create!(
              Discourse.system_user,
              title: "Auto Researcher response JSON (#{Time.now.utc.iso8601})",
              raw: "```json\n#{JSON.pretty_generate(result)}\n```",
              archetype: Archetype.private_message,
              target_usernames: pm_user.username
            )
          end
        end

        # Extract text (prefer output_text; fallback to aggregating message items)
        output_text = result["output_text"].to_s
        if output_text.blank? && result["output"].is_a?(Array)
          texts = []
          result["output"].each do |item|
            if item["type"] == "message"
              (item["content"] || []).each do |part|
                if part["type"] == "output_text" || part["type"] == "text"
                  texts << part["text"]
                end
              end
            end
          end
          output_text = texts.join("\n\n").strip
        end
        output_text = "(no text output)" if output_text.blank?

        # Title generation via model (second call)
        title_body = {
          model: model,
          input: [
            { role: "system", content: "Write a concise, informative topic title (max 80 chars). Return only the title text." },
            { role: "user", content: "Draft a title for the following content:\n\n#{output_text[0..8000]}" }
          ]
        }
        if (t = read_field(fields, :temperature)).present?
          title_body[:temperature] = t.to_f
        end
        title_res   = openai_request("responses", method: :post, body: title_body,
                                     api_key: api_key, organization: organization, project: project)
        topic_title = title_res[:json]["output_text"].to_s.strip
        topic_title = output_text[0, 80].gsub(/\s+/, " ").strip if topic_title.blank?

        # Permission check & create topic
        guardian = Guardian.new(creator)
        raise Discourse::InvalidAccess, "Creator cannot post in category id=#{category.id}" unless guardian.can_create_topic_on_category?(category)

        PostCreator.create!(
          creator,
          title: topic_title,
          raw: output_text,
          category: category.id
        )
      end
    end
  end
end
