# frozen_string_literal: true

# name: discourse-auto-researcher
# about: Automation script that calls OpenAI Responses API and creates a new topic with the result
# version: 0.1.0
# authors: Dylan Wardlow | Cognifai Technologies Lab
# url: https://github.com/MachineSch01ar/discourse-auto-researcher
# required_version: 3.3.0


after_initialize do
  script_path = File.expand_path("../lib/discourse_automation/scripts/auto_researcher.rb", __FILE__)
  load script_path
end

