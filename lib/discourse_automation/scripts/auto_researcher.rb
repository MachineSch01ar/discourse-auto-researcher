# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module ::DiscourseAutomation
  module AutoResearcherHelpers
    module_function

    def val(fields, key)
      v = fields.dig(key.to_s, "value")
      v.is_a?(Hash) ? (v["raw"] || v["value"]) : v
    end

    # Robustly parse Variables from multiple shapes:
    # - :"key-value" UI => Array[{ "key"=>"k", "value"=>"v" }, ...]
    # - JSON object string => {"k":"v", ...}
    # - JSON array string  => [{"key":"k","value":"v"}, ...]
    # - Hash with "raw"/"value" string (message/text components)
    # - nil/empty
    def variables_hash(fields)
      raw = fields.dig("variables", "value")

      case raw
      when Array
        # key-value repeater
        return raw
          .select { |kv| kv.is_a?(Hash) && kv["key"].present? }
          .map { |kv| [kv["key"].to_s, (kv["value"] || "").to_s] }
          .to_h
      when Hash
        # Possibly a message component { "raw" => "..." }
        str = raw["raw"] || raw["value"]
        return parse_variables_string(str)
      when String
        return parse_variables_string(raw)
      when NilClass
        return {}
      else
        return {}
      end
    end

    def parse_variables_string(str)
      s = (str || "").to_s.strip
      return {} if s.empty?

      begin
        parsed = JSON.parse(s)
      rescue JSON::ParserError
        return {}
      end

      case parsed
      when Hash
        parsed.transform_keys(&:to_s).transform_values { |v| v.nil? ? "" : v.to_s }
      when Array
        parsed
          .select { |kv| kv.is_a?(Hash) && kv["key"].present? }
          .map { |kv| [kv["key"].to_s, (kv["value"] || "").to_s] }
          .to_h
      else
        {}
      end
    end

    def parse_json(text)
      return {} if text.blank?
      JSON.parse(text)
    rescue JSON::ParserError
      {}
    end

    def num(val)
      return nil if val.blank?
      Float(val) rescue nil
    end

    def subst(text, map)
      return "" if text.blank?
      text.gsub(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/) { |m| map.fetch($1, m) }
    end

    def time_vars
      now = Time.zone.now
      {
        "now_iso" => now.utc.iso8601,
        "today" => now.strftime("%Y-%m-%d"),
        "week_start_iso" => now.beginning_of_week(:monday).utc.iso8601,
        "week_end_iso" => now.end_of_week(:sunday).utc.iso8601
      }
    end

    def api_headers
      h = {
        "Authorization" => "Bearer #{SiteSetting.ai_openai_api_key}",
        "Content-Type"  => "application/json"
      }
      if SiteSetting.respond_to?(:ai_openai_organization) && SiteSetting.ai_openai_organization.present?
        h["OpenAI-Organization"] = SiteSetting.ai_openai_organization
      end
      if SiteSetting.respond_to?(:ai_openai_project) && SiteSetting.ai_openai_project.present?
        h["OpenAI-Project"] = SiteSetting.ai_openai_project
      end
      h
    end

    def http_post(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true
      req = Net::HTTP::Post.new(uri.request_uri, api_headers)
      req.body = JSON.generate(payload)
      res = http.request(req)
      [res.code.to_i, (JSON.parse(res.body) rescue { "raw" => res.body })]
    end

    def http_get(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true
      req = Net::HTTP::Get.new(uri.request_uri, api_headers)
      res = http.request(req)
      [res.code.to_i, (JSON.parse(res.body) rescue { "raw" => res.body })]
    end

    def extract_text(resp)
      return resp["output_text"] if resp["output_text"].present?
      if resp["output"].is_a?(Array)
        parts = resp["output"].flat_map do |m|
          Array(m["content"]).map do |c|
            (c["type"] == "output_text" || c["type"] == "text") ? c["text"] : nil
          end
        end.compact
        return parts.join("\n\n") if parts.any?
      end
      resp.to_s
    end

    def tools(enable_web, depth)
      return [] unless enable_web
      t = { "type" => "web_search_preview" }
      t["search_context_size"] = depth if %w[low medium high].include?(depth)
      [t]
    end

    def reasoning(effort)
      return nil if effort.blank?
      { "effort" => effort }
    end

    # Parse stop sequences from multi-line message field (or JSON array)
    def parse_stop_list(fields)
      raw = val(fields, :stop).to_s
      if raw.strip.start_with?("[")
        begin
          arr = JSON.parse(raw)
          return Array(arr).map(&:to_s).map(&:strip).reject(&:empty?)
        rescue JSON::ParserError
          # fall through
        end
      end
      raw.split(/\r?\n/).map(&:strip).reject(&:empty?)
    end
  end
end

module ::DiscourseAutomation
  class Scriptables
    class AutoResearcher
      SCRIPT_NAME = "auto_researcher"
    end
  end
end

DiscourseAutomation::Scriptable.add(
  DiscourseAutomation::Scriptables::AutoResearcher::SCRIPT_NAME
) do
  version 1
  triggerables [:recurring]

  # ---------- Fields ----------
  field :creator, component: :user, required: true

  # Multi-line editors for prompts
  field :prompt, component: :message, required: true
  field :system_prompt, component: :message

  # Key/Value repeater UI (with hyphen). If your build lacks this component,
  # the back-end now also accepts JSON via string.
  field :variables, component: :"key-value"

  field :model, component: :text, required: true

  # Use :text for numerics (some builds don't have :number)
  field :poll_timing, component: :text
  field :send_pm_with_full_response, component: :user
  field :category, component: :category, required: true

  # STOP: multi-line message (one per line, or JSON array)
  field :stop, component: :message

  field :temperature, component: :text
  field :top_p, component: :text
  field :presence_penalty, component: :text
  field :frequency_penalty, component: :text
  field :seed, component: :text

  field :reasoning_effort,
        component: :choices,
        extra: {
          content: [
            { id: "low",    name: "discourse_automation.scriptables.auto_researcher.fields.reasoning_effort.choices.low" },
            { id: "medium", name: "discourse_automation.scriptables.auto_researcher.fields.reasoning_effort.choices.medium" },
            { id: "high",   name: "discourse_automation.scriptables.auto_researcher.fields.reasoning_effort.choices.high" }
          ]
        }

  field :enable_web_search, component: :boolean
  field :web_search_depth,
        component: :choices,
        extra: {
          content: [
            { id: "low",    name: "discourse_automation.scriptables.auto_researcher.fields.web_search_depth.choices.low" },
            { id: "medium", name: "discourse_automation.scriptables.auto_researcher.fields.web_search_depth.choices.medium" },
            { id: "high",   name: "discourse_automation.scriptables.auto_researcher.fields.web_search_depth.choices.high" }
          ]
        }
  field :include_sources, component: :boolean

  # Free-form JSON merged into POST /v1/responses
  field :responses_api_overrides, component: :message

  # ---------- Execute ----------
  script do |_ctx, fields, _automation|
    H = ::DiscourseAutomation::AutoResearcherHelpers

    creator_username = H.val(fields, :creator).to_s
    creator = User.find_by_username!(creator_username)

    category_id = fields.dig("category", "value").to_i
    model       = H.val(fields, :model).to_s

    user_vars   = H.variables_hash(fields)
    vars        = H.time_vars.merge(user_vars)

    user_prompt = H.subst(H.val(fields, :prompt), vars)
    sys_prompt  = H.subst(H.val(fields, :system_prompt), vars)

    poll_every  = (H.num(H.val(fields, :poll_timing)) || 2).to_i.clamp(1, 30)

    stop_list   = H.parse_stop_list(fields)
    temp        = H.num(H.val(fields, :temperature))
    top_p       = H.num(H.val(fields, :top_p))
    presence    = H.num(H.val(fields, :presence_penalty))
    frequency   = H.num(H.val(fields, :frequency_penalty))
    seed        = H.num(H.val(fields, :seed))

    reasoning_effort = fields.dig("reasoning_effort", "value")
    enable_web       = fields.dig("enable_web_search", "value") == true
    web_depth        = fields.dig("web_search_depth", "value").to_s
    include_sources  = fields.dig("include_sources", "value") == true

    overrides = H.parse_json(H.val(fields, :responses_api_overrides).to_s)

    # Build payload
    user_text = user_prompt.dup
    if include_sources
      user_text << "\n\nWhen you use web search, include concise inline citations to your sources."
    end

    input = []
    input << { "role" => "system", "content" => sys_prompt } if sys_prompt.present?
    input << { "role" => "user", "content" => user_text }

    payload = { "model" => model, "input" => input }
    payload["stop"] = stop_list if stop_list.present?
    payload["temperature"] = temp if temp
    payload["top_p"] = top_p if top_p
    payload["presence_penalty"] = presence if presence
    payload["frequency_penalty"] = frequency if frequency
    payload["seed"] = seed if seed
    payload["reasoning"] = H.reasoning(reasoning_effort) if reasoning_effort.present?
    tool_list = H.tools(enable_web, web_depth)
    payload["tools"] = tool_list if tool_list.any?

    payload = payload.deep_merge(overrides) if overrides.present?

    url = "https://api.openai.com/v1/responses"
    code, resp = H.http_post(url, payload)
    raise Discourse::InvalidParameters, "OpenAI error #{code}: #{resp}" if code >= 400

    while resp["status"] == "in_progress" && resp["id"].present?
      sleep(poll_every)
      _c, resp = H.http_get("#{url}/#{resp['id']}")
    end

    # Optional PM of raw JSON
    if (pm_user = H.val(fields, :send_pm_with_full_response)).present?
      if (target = User.find_by_username(pm_user))
        PostCreator.create!(
          creator,
          archetype: Archetype.private_message,
          target_usernames: target.username,
          title: "[Auto Researcher] Raw API response",
          raw: "```json\n#{JSON.pretty_generate(resp)}\n```"
        )
      end
    end

    body = H.extract_text(resp).to_s.strip
    raise Discourse::InvalidParameters, "Empty model output" if body.blank?

    # Title call
    title_payload = {
      "model" => model,
      "input" => [
        { "role" => "system", "content" => "Return a concise, clear forum topic title (max 12 words). No quotes." },
        { "role" => "user", "content" => body }
      ]
    }
    title_payload["tools"] = tool_list if tool_list.any?
    title_payload = title_payload.deep_merge(overrides) if overrides.present?

    code2, resp2 = H.http_post(url, title_payload)
    raise Discourse::InvalidParameters, "OpenAI title error #{code2}: #{resp2}" if code2 >= 400
    title = H.extract_text(resp2).to_s.strip
    title = title[0...300] if title.length > 300

    PostCreator.create!(
      creator,
      title: title,
      raw: body,
      category: category_id
    )
  end
end
