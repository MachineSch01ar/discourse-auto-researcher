# discourse-auto-researcher

**Auto Researcher** is a Discourse **Automation** script that, on a schedule, calls OpenAI’s **Responses API** with your prompt + parameters, then posts the model’s output as a **new topic** (with an AI-generated title). It can optionally send the **raw JSON** API response to a user as a private message.

This plugin registers a new Automation **scriptable** named **Auto Researcher**. You keep using the standard **Recurring** trigger—everything else is configured in the Admin UI.

---

## Highlights

* ✅ Multi-line **Prompt** + **System prompt** (composer-style).
* ✅ **Variables** with a clean **Key/Value** UI; reference with `{{name}}`.
* ✅ Built-in timestamp variables: `{{now_iso}}`, `{{today}}`, `{{week_start_iso}}`, `{{week_end_iso}}`.
* ✅ Supports common Responses parameters (temperature, top\_p, penalties, seed, stop).
* ✅ **Reasoning effort** (`low|medium|high`) for models that support it.
* ✅ Built-in **Web search** tool with depth `low|medium|high`.
* ✅ Optional **polling** if the API reports an in-progress response.
* ✅ Optional PM with the **raw JSON** for auditing or debugging.
* ✅ **Overrides JSON**: free-form merge for *any* Responses API parameter not explicitly exposed.

---

## Requirements

* A Discourse install that allows custom plugins (self-hosted or plan with custom code).
* **Discourse AI** plugin configured with your OpenAI credentials:

  * `ai_openai_api_key` (required)
  * `ai_openai_organization` (optional)
  * `ai_openai_project` (optional)

The plugin reads those site settings—no duplicate secrets.

---

## Installation

1. Add the plugin to your app container (Docker example):

   ```yaml
   # /var/discourse/containers/app.yml
   hooks:
     after_code:
       - git clone https://github.com/MachineSch01ar/discourse-auto-researcher.git
   ```

2. Rebuild:

   ```bash
   cd /var/discourse
   ./launcher rebuild app
   ```

3. In Discourse, go to **Admin → Plugins → AI** and confirm your OpenAI settings.

---

## Repository layout

```
discourse-auto-researcher/
├── plugin.rb
├── config/
│   ├── settings.yml
│   └── locales/
│       ├── server.en.yml     # script title/description & site setting label
│       └── client.en.yml     # field labels/descriptions/choices
└── lib/
    └── discourse_automation/
        └── scripts/
            └── auto_researcher.rb
```

---

## Enable & create an automation

1. **Admin → Customize → Automations → New**
2. **Trigger:** *Recurring* (set cadence)
3. **Script:** *Auto Researcher*
4. Fill in the options (below), **Save**, and **Enable**
   *(You can also “Run now” to test immediately.)*

---

## How it works (flow)

1. At the scheduled time, the script builds a **Responses API** request from your **Prompt**, **System prompt**, **Variables**, and parameters.
2. `POST /v1/responses` to create the response.
   If the API returns `status: "in_progress"`, it **polls** `GET /v1/responses/{id}` every *N* seconds (your Poll timing) until completion.
3. Optionally sends a **PM** to your chosen user with the **exact raw JSON** returned by the API.
4. Extracts the **output text** from the response.
5. Makes a **second model call** to generate a concise topic **title**.
6. Creates the **topic** in your chosen category as the selected **Creator** user.

---

## Script options (fields)

> Tip: You can use variables anywhere the UI shows a text or message field: write `{{my_key}}`.

| Field                          | Type                 | Required | Notes                                                                        |
| ------------------------------ | -------------------- | -------: | ---------------------------------------------------------------------------- |
| **Creator**                    | User                 |        ✓ | Author of the new topic (must have permission in the category).              |
| **Prompt**                     | Message (multi-line) |        ✓ | Main user prompt sent to the model. Supports `{{variables}}`.                |
| **System prompt**              | Message (multi-line) |          | Optional system/developer instruction sent before the user prompt.           |
| **Variables**                  | **Key/Value**        |          | Add any number of pairs; reference as `{{key}}`.                             |
| **Model**                      | Text                 |        ✓ | Responses API model name (e.g., `gpt-4o`, `gpt-4o-mini`, `o3`, etc.).        |
| **Poll timing**                | Text (number)        |          | Seconds between status checks if the API shows `in_progress` (default 2s).   |
| **Send PM with full response** | User                 |          | Sends a PM to this user with the raw JSON response.                          |
| **Category to post in**        | Category             |        ✓ | Where the new topic will be created.                                         |
| **stop**                       | List                 |          | One or more stop sequences (one per line).                                   |
| **temperature**                | Text (number)        |          | 0–2 (model-dependent).                                                       |
| **top\_p**                     | Text (number)        |          | 0–1 nucleus sampling.                                                        |
| **presence\_penalty**          | Text (number)        |          | −2..2                                                                        |
| **frequency\_penalty**         | Text (number)        |          | −2..2                                                                        |
| **seed**                       | Text (number)        |          | For reproducibility on supported models.                                     |
| **reasoning.effort**           | Choices              |          | `low`, `medium`, `high` (only for models that support it).                   |
| **Enable web search tool**     | Boolean              |          | Adds OpenAI’s built-in web search tool.                                      |
| **Web search depth**           | Choices              |          | `low`, `medium`, `high` search context size (only if web search is enabled). |
| **Include sources in output**  | Boolean              |          | Asks the model to include citations when web search was used.                |
| **Overrides JSON**             | Message (multi-line) |          | Free-form JSON merged into the final request (see below).                    |

### Built-in variables

These are always available:

* `{{now_iso}}` — current UTC time, ISO-8601
* `{{today}}` — current date (`YYYY-MM-DD`), site timezone
* `{{week_start_iso}}` — Monday 00:00 of the current week, UTC ISO-8601
* `{{week_end_iso}}` — Sunday 23:59:59 of the current week, UTC ISO-8601

**Example Variables (Key/Value):**

| Key          | Value                                      |
| ------------ | ------------------------------------------ |
| country      | Canada                                     |
| time\_window | {{week\_start\_iso}} to {{week\_end\_iso}} |
| audience     | general readers                            |

Use them in prompts like:
“Find the 5 biggest news stories in **{{country}}** between **{{time\_window}}**.”

---

## Overrides JSON (advanced)

Anything you put here is **deep-merged** into the request body after the basic fields—use it for parameters not exposed explicitly.

**Examples**

* **Structured output (JSON schema)**

  ```json
  {
    "text": {
      "format": {
        "type": "json_schema",
        "name": "weekly_brief",
        "schema": {
          "type": "object",
          "properties": {
            "items": { "type": "array", "items": { "type": "string" } },
            "next_week_watch": { "type": "array", "items": { "type": "string" } }
          },
          "required": ["items"]
        }
      }
    }
  }
  ```

* **Tool choice + metadata + max tokens**

  ```json
  {
    "tool_choice": "auto",
    "metadata": { "job": "weekly-events", "owner": "auto-researcher" },
    "max_output_tokens": 2000
  }
  ```

> ⚠️ Compatibility is your responsibility: not every parameter applies to every model. If you pass an unsupported field, the API may error.

---

## Example automation

**Weekly world events brief**

* **Model:** `gpt-4o-mini` (or any available capable model)
* **Enable web search:** ✓; **Depth:** `medium`; **Include sources:** ✓
* **Prompt:**

  ```
  Summarize the 5–10 most significant world events between {{week_start_iso}} and {{week_end_iso}} for {{country}}.
  Group by region. Provide 1–2 sentence summaries. Include a short "What to watch next week" section.
  ```
* **System prompt:**

  ```
  You are a precise, impartial research analyst. Be concise and include citations when web search is used.
  ```
* **Variables:**
  `country = Global`
* **Overrides JSON (optional):** structured outputs to get consistent headings.

---

## Troubleshooting

* **“Missing translation for …auto\_researcher.title”**
  Ensure `config/locales/server.en.yml` contains:

  ```yml
  discourse_automation:
    scriptables:
      auto_researcher:
        title: "Auto Researcher"
        description: "…"
  ```

* **“No setting named 'auto\_researcher\_enabled' exists”**
  You need `config/settings.yml` and `config/locales/server.en.yml`:

  ```yml
  # settings.yml
  plugins:
    auto_researcher_enabled:
      default: true
      client: true
  ```

  ```yml
  # server.en.yml
  site_settings:
    auto_researcher_enabled: "Enable the Auto Researcher plugin"
  ```

* **Variables UI not showing**
  The field must be `component: :"key-value"` (with a hyphen). Older Discourse builds may not support it—update Discourse or temporarily switch to `component: :text` and paste JSON.

* **“Data for `poll_timing` invalid or component `number` unknown”**
  Your build doesn’t support `:number`. This plugin uses `:text` and parses to a number; keep it that way.

* **OpenAI/auth errors**
  Verify **Admin → Plugins → AI** key/org/project are set and that the model name is valid for your account.

* **Empty output**
  Some requests can produce only tool traces or no text. The script falls back to aggregating message parts; if still empty, the run is aborted and logged.

* **Where to read logs**

  * UI: `/logs` (Admin)
  * Shell: `./launcher logs app | tail -n 200`

---

## Contributing

PRs welcome! Please keep the scriptable UI minimal and lean on **Overrides JSON** to expose new Responses API features without code churn. Add translation keys for any new fields in both **client** and **server** locales.

---

## License

MIT © contributors.
