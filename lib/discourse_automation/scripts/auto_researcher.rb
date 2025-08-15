# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

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

  # --- Fields ---
  field :creator, component: :user, required: true

  # Multi-line editor for prompts (composer-like)
  field :prompt, component: :message, required: true
  field :system_prompt, component: :message

  field :variables, component: :text # JSON input; safest across versions
  field :model, component: :text, required: true

  field :poll_timing, component: :number
  field :send_pm_with_full_response, component: :user
  field :category, component: :category, required: true

  field :stop, component: :list
  field :temperature, component: :number
  field :top_p, component: :number
  field :presence_penalty, component: :number
  field :frequency_penalty, component: :number
  field :seed, component: :number

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

  field :responses_api_overrides, component: :message # multi-line JSON

  # --- Helpers ---
  def self.val(fields, key)
    v = fields.dig(key.to_s, "value")
    v.is_a?(Hash) ? (v["raw"] || v["value"]) : v
  end

  def self.parse_json(text)
    return {} if text.blank?
    JSON.parse(text)
  rescue JSON::ParserError
    {}
  end

  def self.num(val)
    return nil if val.blank?
    Float(val) rescue nil
  end

  def self.subst(text, map)
    return "" if text.blank?
    text.gsub(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/) { |m| map.fetch($1, m) }
  end

  def self.time_vars
    now = Time.zone.now
    {
      "now_iso" => now.utc.iso8601,
      "today" => now.strftime("%Y-%m-%d"),
      "week_start_iso" => now.beginning_of_week(:monday).utc.iso8601,
      "week_end_iso" => now.end_of_week(:sunday).utc.iso8601
    }
  end

  def self.api_headers
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

  def self.http_post(url, payload)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true
    req = Net::HTTP::Post.new(uri.request_uri, api_headers)
    req.body = JSON.generate(payload)
    res = http.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue { "raw" => res.body })]
  end

  def self.http_get(url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true
    req = Net::HTTP::Get.new(uri.request_uri, api_headers)
    res = http.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue { "raw" => res.body })]
  end

  def self.extract_text(resp)
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

  def self.tools(enable_web, depth)
    return [] unless enable_web
    t = { "type" => "web_search_preview" }
    t["search_context_size"] = depth if %w[low medium high].include?(depth)
    [t]
  end

  def self.reasoning(effort)
    return nil if effort.blank?
    { "effort" => effort }
  end

  # --- Execute ---
  script do |_ctx, fields, _automation|
    creator_username = self.class.val(fields, :creator).to_s
    creator = User.find_by_username!(creator_username)

    category_id = fields.dig("category", "value").to_i
    model       = self.class.val(fields, :model).to_s

    user_vars   = self.class.parse_json(self.class.val(fields, :variables).to_s)
    vars        = self.class.time_vars.merge(user_vars)

    user_prompt = self.class.subst(self.class.val(fields, :prompt), vars)
    sys_prompt  = self.class.subst(self.class.val(fields, :system_prompt), vars)

    poll_every  = (self.class.num(self.class.val(fields, :poll_timing)) || 2).to_i.clamp(1, 30)

    stop_list   = fields.dig("stop", "value") || []
    temp        = self.class.num(self.class.val(fields, :temperature))
    top_p       = self.class.num(self.class.val(fields, :top_p))
    presence    = self.class.num(self.class.val(fields, :presence_penalty))
    frequency   = self.class.num(self.class.val(fields, :frequency_penalty))
    seed        = self.class.num(self.class.val(fields, :seed))

    reasoning_effort = fields.dig("reasoning_effort", "value")
    enable_web       = fields.dig("enable_web_search", "value") == true
    web_depth        = fields.dig("web_search_depth", "value").to_s
    include_sources  = fields.dig("include_sources", "value") == true

    overrides = self.class.parse_json(self.class.val(fields, :responses_api_overrides).to_s)

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
    payload["reasoning"] = self.class.reasoning(reasoning_effort) if reasoning_effort.present?
    tool_list = self.class.tools(enable_web, web_depth)
    payload["tools"] = tool_list if tool_list.any?

    payload = payload.deep_merge(overrides) if overrides.present?

    url = "https://api.openai.com/v1/responses"
    code, resp = self.class.http_post(url, payload)
    raise Discourse::InvalidParameters, "OpenAI error #{code}: #{resp}" if code >= 400

    while resp["status"] == "in_progress" && resp["id"].present?
      sleep(poll_every)
      _c, resp = self.class.http_get("#{url}/#{resp['id']}")
    end

    # Optional PM of raw JSON
    if (pm_user = self.class.val(fields, :send_pm_with_full_response)).present?
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

    body = self.class.extract_text(resp).to_s.strip
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

    code2, resp2 = self.class.http_post(url, title_payload)
    raise Discourse::InvalidParameters, "OpenAI title error #{code2}: #{resp2}" if code2 >= 400
    title = self.class.extract_text(resp2).to_s.strip
    title = title[0...300] if title.length > 300

    PostCreator.create!(
      creator,
      title: title,
      raw: body,
      category: category_id
    )
  end
end
