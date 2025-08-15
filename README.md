# discourse-auto-researcher

**Auto Researcher** is a custom Discourse **Automation** script that schedules an OpenAI **Responses API** call with your own prompt, variables, and parameters—then posts the model’s output as a new topic (with an AI-generated title). Optionally, it can PM the **raw JSON** response to a user for auditing/debugging.

This script is built as a lightweight Discourse plugin that registers a new Automation “scriptable.” It uses the existing **Recurring** trigger; you configure everything from the Admin UI. ([Discourse Meta][1])

---

## Why this exists

Discourse ships with **Automations** (now bundled in core), and it’s common to want a flexible, “bring-your-own-prompt” task that periodically researches something (with web search, if you want), then posts a report to a category—no coding or external CRON needed. Auto Researcher provides exactly that, while letting you pass through **any** Responses API parameter to stay future-proof. ([Discourse Meta][1])

---

## What it does (flow)

At the scheduled time:

1. Build a Responses API request from your prompt, variables, and options (temperature, max tokens, **reasoning.effort**, **web search**, etc.).
2. Create the response via `POST /v1/responses`; if you set **Poll timing**, re-check `GET /v1/responses/{id}` every N seconds until it completes.
3. Optionally PM the **raw JSON** to a user.
4. Parse the **output text**.
5. Make a quick second LLM call to craft a concise title.
6. Create the topic in your chosen **Category** as the selected **Creator** user.

OpenAI **Responses** is stateful (you can retrieve a response by id), supports **web search** as a built-in tool, and exposes a convenient `output_text` field used here. ([OpenAI Platform][2])

---

## Requirements

* A Discourse install that allows custom plugins (typical for **self-hosted**).
* **Discourse Automations** (bundled with core—no separate install).
* **Discourse AI** configured with an **OpenAI** API key (and optional Organization/Project), via Admin → Plugins → AI. ([Discourse Meta][1])

---

## Installation

1. **Add the plugin** to your container. On self-hosted Docker installs, edit `/var/discourse/containers/app.yml` and add your repo under `hooks > after_code`, then rebuild:

   ```bash
   cd /var/discourse
   ./launcher rebuild app
   ```

   (General “Install plugins on a self-hosted site” guide.) ([Discourse Meta][3])

2. **Upgrade / rebuild** as normal in the future. (FYI: Discourse has recently been moving popular plugins into core; Automations is already included.) ([Discourse Meta][4])

---

## Configuration (Discourse AI)

In the Admin UI, go to **Plugins → AI** to add your OpenAI key and (optionally) Organization/Project and define your models. The script reads these credentials from site settings—no extra secrets file. ([Discourse Meta][5])

---

## Using the new Automation

1. Go to **Admin → Customize → Automations** → **New**.
2. **Trigger:** choose **Recurring** (daily/weekly/cron-like cadence).
3. **Script/Action:** select **Auto Researcher**.
4. Fill out the options (see next section), then **Save** and **Enable**. ([Discourse Meta][1])

---

## Script options (fields)

> Tip: You can reference variables inside prompts using `{{variable}}`. The script also exposes helpful built-ins: `{{now_iso}}`, `{{today}}`, `{{week_start_iso}}`, `{{week_end_iso}}`.

| Field                              | Required | Description                                                                                                                                                                                                             |
| ---------------------------------- | -------: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Creator**                        |        ✓ | The Discourse user that will author the topic. Must have permission to post in the chosen category.                                                                                                                     |
| **Category to post in**            |        ✓ | Target category where the topic is created.                                                                                                                                                                             |
| **Model**                          |        ✓ | OpenAI model name for **Responses** (e.g., `gpt-4o`, `o4-mini`, `o3`, `gpt-5-mini`, subject to your account’s access).                                                                                                  |
| **Prompt**                         |        ✓ | The main **user** prompt. Supports `{{your_var}}` substitution.                                                                                                                                                         |
| **System prompt**                  |          | Optional **system/developer** instruction message.                                                                                                                                                                      |
| **Variables (JSON)**               |          | Arbitrary key→value pairs for substitution. Example: `{"region":"global","verbosity":"brief"}`.                                                                                                                         |
| **Poll timing (seconds)**          |          | If set, the script will re-fetch `GET /v1/responses/{id}` every N seconds until `status` is `completed`. Useful for long reasoning/tool runs. ([OpenAI Platform][6])                                                    |
| **Send PM with full response**     |          | Username to receive a private message containing the **raw JSON** returned by OpenAI. PMs are created with `archetype: private_message`. ([GitHub][7], [Discourse Meta][8])                                             |
| **temperature**                    |          | 0–2 (model-dependent). Higher ⇒ more random.                                                                                                                                                                            |
| **top\_p**                         |          | 0–1 nucleus sampling (use temp or top\_p, not both).                                                                                                                                                                    |
| **max\_output\_tokens**            |          | Hard cap on generated tokens.                                                                                                                                                                                           |
| **presence\_penalty**              |          | Penalize new-topic token presence.                                                                                                                                                                                      |
| **frequency\_penalty**             |          | Penalize repeated tokens.                                                                                                                                                                                               |
| **seed**                           |          | Deterministic runs (where supported).                                                                                                                                                                                   |
| **stop**                           |          | Stop sequence(s).                                                                                                                                                                                                       |
| **reasoning.effort**               |          | For reasoning models (e.g., o-series, some GPT-5 reasoning variants): `low` / `medium` / `high` (some providers add `minimal`). Only effective on models that support it. ([OpenAI Platform][9], [Microsoft Learn][10]) |
| **Enable web search**              |          | Adds OpenAI’s **web search** tool; the model decides when to use it.                                                                                                                                                    |
| **Web search depth**               |          | `quick` or `deep`.                                                                                                                                                                                                      |
| **Web search results**             |          | Limit number of results considered.                                                                                                                                                                                     |
| **Include sources**                |          | Ask the toolchain/model to include citations when available.                                                                                                                                                            |
| **Responses API overrides (JSON)** |          | Advanced: merge **any** Responses API parameters (e.g., `tools`, `tool_choice`, `metadata`, `previous_response_id`, `text.format` for structured outputs). Use with care. ([OpenAI Platform][2])                        |

> **Compatibility note:** Not every parameter applies to every model. It’s your responsibility to choose compatible settings—the script deliberately exposes raw Responses API controls to keep it general-purpose. See OpenAI’s docs for details. ([OpenAI Platform][2])

---

## Variable substitution

* Write `{{name}}` inside **Prompt** or **System prompt**.
* Provide `"name": "value"` in **Variables (JSON)**.
* Built-ins are always available:

  * `{{now_iso}}` – current time (UTC ISO 8601)
  * `{{today}}` – current date (server TZ)
  * `{{week_start_iso}}` / `{{week_end_iso}}` – Monday/Sunday bounds (UTC ISO 8601)

Example prompt:

```
Research major world events from {{week_start_iso}} to {{week_end_iso}}.
Group by region. Include bullet points and, if available, citations.
```

---

## Web search (optional)

To turn on live browsing/citations, enable **web search**. This uses OpenAI’s **built-in tool** for web search via the Responses API; you can adjust depth and result count. (Feature availability may vary by provider; we target OpenAI’s native implementation.) ([OpenAI Platform][11])

---

## Polling (optional)

For long-running jobs, set **Poll timing (seconds)**. The script will create a response, then GET `/v1/responses/{response_id}` every N seconds until the API reports `status: "completed"` (or an error). ([OpenAI Platform][6])

---

## How topics and PMs are created

Topics/PMs are created **server-side** with Discourse’s `PostCreator`. A PM is created by setting `archetype: private_message` and `target_usernames`, which is how Discourse itself models private conversations. ([GitHub][7], [Discourse Meta][12])

---

## Example: Weekly “World Events” report

* **Model:** `o4-mini` (or another model you’ve configured)
* **System prompt:** “You are a precise research analyst. Group by region; keep items short; include sources when available.”
* **Prompt:** “Summarize major world events between `{{week_start_iso}}` and `{{week_end_iso}}`. 5–10 items, then a short ‘What to watch next week’.”
* **Web search:** enabled; **depth:** `deep`; **results:** `8`; **include sources:** true
* **max\_output\_tokens:** 2000; **temperature:** 0.5
* **Category:** Reports → Weekly Briefings

---

## Advanced usage

### Responses API overrides (JSON)

Place any additional fields here to future-proof your workflows, for example:

```json
{
  "metadata": {"job": "weekly-events"},
  "previous_response_id": "resp_abc123",
  "text": {
    "format": {
      "type": "json_schema",
      "name": "weekly_brief",
      "schema": { "type": "object", "properties": { "items": { "type": "array" } }, "required": ["items"] }
    }
  }
}
```

* `previous_response_id` continues a stateful conversation.
* `text.format` requests **structured outputs** (JSON schema). ([OpenAI Platform][13])

---

## Troubleshooting

* **No topic was created** – Ensure the **Creator** can post in the target category (permissions) and that the model produced text (`output_text`). The script falls back to concatenating message parts if `output_text` is missing. ([OpenAI Platform][14])
* **Long latency** – Reduce `reasoning.effort`, `max_output_tokens`, or disable web search; some reasoning models take longer by design. ([OpenAI Platform][9])
* **Credentials** – Confirm OpenAI credentials in **Admin → Plugins → AI** and that your model is configured/enabled. ([Discourse Meta][5])
* **Hosted plans** – Custom plugins typically require self-hosting or a plan that allows custom code. (Automations UI is in core, but this script is a custom plugin.) ([Discourse Meta][1])

---

## Local development

This plugin registers a new Automation “scriptable” via `add_automation_scriptable`, the standard way to extend Discourse Automations. If you want to modify fields or behavior, edit `plugin.rb` and rebuild your container. ([Discourse Meta][15])

---

## Security & privacy

* The plugin **does not** store your keys; it reads them from Discourse AI’s site settings.
* All outbound requests go directly from your server to OpenAI’s API.
* Consider your data handling obligations when enabling **web search** or posting unvetted outputs to public categories. ([Discourse Meta][5])

---

## License

MIT (see `LICENSE`).

---

## References

* **Discourse Automations** (official, included-in-core) and how to create custom scriptables. ([Discourse Meta][1])
* **Installing Discourse plugins** (self-hosted / Docker). ([Discourse Meta][3])
* **PostCreator** and PM creation via `archetype: private_message`. ([GitHub][7], [Discourse Meta][12])
* **OpenAI Responses API**: API reference, retrieve by id, web search tool, output\_text convenience. ([OpenAI Platform][2])
* **Reasoning effort** parameter and model notes. ([OpenAI Platform][9], [Microsoft Learn][10])
* **Configure OpenAI in Discourse AI** (Admin guide). ([Discourse Meta][5])

---

### Quick start checklist

* [ ] Add the plugin to your Discourse and rebuild. ([Discourse Meta][3])
* [ ] Confirm OpenAI credentials and model config in **Plugins → AI**. ([Discourse Meta][5])
* [ ] Create a new **Automation → Auto Researcher** with **Recurring** trigger. ([Discourse Meta][1])
* [ ] Paste your **Prompt**, choose **Model**, set **Category/Creator**.
* [ ] (Optional) Enable **web search**, set **Poll timing**, and a **PM** recipient for raw JSON.
* [ ] Enable and watch your scheduled report appear as a topic.

[1]: https://meta.discourse.org/t/discourse-automation/195773?utm_source=chatgpt.com "Discourse Automation - Plugin"
[2]: https://platform.openai.com/docs/api-reference/responses?utm_source=chatgpt.com "API Reference"
[3]: https://meta.discourse.org/t/install-plugins-on-a-self-hosted-site/19157?utm_source=chatgpt.com "Install plugins on a self-hosted site"
[4]: https://meta.discourse.org/t/core-plugins-added-to-my-updated-site-today/374360?utm_source=chatgpt.com "Core plugins added to my updated site today"
[5]: https://meta.discourse.org/t/configure-api-keys-for-openai/280783?utm_source=chatgpt.com "Configure API Keys for OpenAI - Integrations"
[6]: https://platform.openai.com/docs/api-reference/responses/get?utm_source=chatgpt.com "Responses.retrieve()"
[7]: https://github.com/discourse/discourse/blob/master/lib/post_creator.rb?utm_source=chatgpt.com "discourse/lib/post_creator.rb at main"
[8]: https://meta.discourse.org/t/distinguish-private-messages-from-posts/51468?utm_source=chatgpt.com "Distinguish private messages from posts? - Dev"
[9]: https://platform.openai.com/docs/guides/reasoning?utm_source=chatgpt.com "Reasoning models - OpenAI API"
[10]: https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/reasoning?utm_source=chatgpt.com "Azure OpenAI reasoning models - GPT-5 series, o3-mini ..."
[11]: https://platform.openai.com/docs/guides/tools-web-search?utm_source=chatgpt.com "Web search - OpenAI API"
[12]: https://meta.discourse.org/t/creating-a-private-message-with-multiple-users/141956?utm_source=chatgpt.com "Creating a private message with multiple users - Support"
[13]: https://platform.openai.com/docs/guides/migrate-to-responses?utm_source=chatgpt.com "Migrating to Responses API"
[14]: https://platform.openai.com/docs/guides/text?utm_source=chatgpt.com "Text generation - OpenAI API"
[15]: https://meta.discourse.org/t/create-custom-automations/275931?utm_source=chatgpt.com "Create custom Automations - Developer Guides"
