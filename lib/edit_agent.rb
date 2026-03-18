require 'faraday'
require 'json'
require 'securerandom'

module UltimateCMS
  class EditAgent
    CLAUDE_API = 'https://api.anthropic.com/v1/messages'
    MODEL = 'claude-sonnet-4-20250514'

    def initialize(github:, api_key:)
      @github = github
      @api_key = api_key
    end

    # Main entry: process all changes, create a PR
    def process(page:, changes:)
      # 1. Search the repo for each changed text
      file_candidates = find_candidates(changes)

      # 2. Read the candidate files
      file_contents = {}
      file_candidates.uniq.each do |path|
        begin
          file_contents[path] = @github.get_file(path)
        rescue => e
          # skip files we can't read
        end
      end

      # 3. Ask Claude to produce the exact edits
      edits = ask_agent(page, changes, file_contents)

      return { pr_url: nil, error: 'Agent could not determine edits' } if edits.empty?

      # 4. Create a branch
      branch_name = "ucms/edit-#{SecureRandom.hex(4)}"
      @github.create_branch(branch_name)

      # 5. Apply each edit
      edits.each do |edit|
        file = file_contents[edit['file']]
        next unless file

        new_content = file[:content].sub(edit['old'], edit['new'])

        # Verify the substitution actually changed something
        next if new_content == file[:content]

        @github.update_file(
          path: edit['file'],
          content: new_content,
          sha: file[:sha],
          branch: branch_name,
          message: "Update text in #{edit['file']} via UltimateCMS"
        )

        # Update sha for subsequent edits to the same file
        updated = @github.get_file(edit['file'], ref: branch_name)
        file_contents[edit['file']] = updated
      end

      # 6. Create a PR
      change_summary = changes.map { |c| "- \"#{truncate(c['old_text'], 40)}\" → \"#{truncate(c['new_text'], 40)}\"" }.join("\n")

      pr_url = @github.create_pull_request(
        title: "Content update via UltimateCMS",
        body: build_pr_body(page, changes, edits),
        head: branch_name
      )

      { pr_url: pr_url }
    end

    private

    # Search for text in repo to find candidate files
    def find_candidates(changes)
      candidates = []

      # Get repo tree to know all files
      all_files = @github.get_tree
      # Filter to text-like files
      text_extensions = %w[.html .htm .njk .liquid .erb .haml .slim .md .mdx .json .yml .yaml .toml .js .jsx .ts .tsx .vue .svelte .php .rb .py .twig .hbs .mustache .pug .ejs .txt .css .scss]
      text_files = all_files.select { |f| text_extensions.any? { |ext| f.end_with?(ext) } }

      changes.each do |change|
        old_text = change['old_text']
        # Try GitHub search first
        begin
          results = @github.search_code(old_text)
          results.each { |r| candidates << r['path'] }
        rescue
          # search API can be rate-limited, fall back to manual scan
        end

        # Also check likely files based on context
        context = change['context'] || {}
        # Data files, templates, content files are most likely
        likely_patterns = %w[_data/ content/ src/ pages/ templates/ views/ locales/ i18n/ public/ app/]
        text_files.each do |f|
          if likely_patterns.any? { |p| f.include?(p) } || f.end_with?('.html', '.njk', '.md', '.json')
            candidates << f
          end
        end
      end

      candidates.uniq.first(20) # limit to avoid too many API calls
    end

    # Ask Claude to determine the exact edits
    def ask_agent(page, changes, file_contents)
      # Build the prompt with all context
      files_context = file_contents.map do |path, file|
        "### #{path}\n```\n#{truncate(file[:content], 3000)}\n```"
      end.join("\n\n")

      changes_context = changes.map.with_index do |change, i|
        ctx = change['context'] || {}
        <<~CHANGE
          ## Change #{i + 1}
          - **Old text:** "#{change['old_text']}"
          - **New text:** "#{change['new_text']}"
          - **HTML tag:** <#{ctx['tag']}>
          - **CSS classes:** #{(ctx['classes'] || []).join(', ')}
          - **DOM path:** #{ctx['dom_path']}
          - **Parent tag:** #{ctx['parent_tag']} (classes: #{(ctx['parent_classes'] || []).join(', ')})
          - **Sibling texts:** #{(ctx['sibling_texts'] || []).join(' | ')}
          - **Section:** #{ctx.dig('section', 'tag')}#{'#' + ctx.dig('section', 'id') if ctx.dig('section', 'id')} — heading: "#{ctx.dig('section', 'heading')}"
          - **Link href:** #{ctx['href']}
        CHANGE
      end.join("\n")

      prompt = <<~PROMPT
        You are an expert at finding where text content lives in web project source code.

        A user has visually edited text on a rendered website. Your job is to find the EXACT location in the SOURCE CODE where each text change should be applied.

        ## Page context
        - URL: #{page['url']}
        - Path: #{page['path']}
        - Title: #{page['title']}
        - Repository: #{@github.owner}/#{@github.repo}

        ## Changes made by the user
        #{changes_context}

        ## Source files (candidates)
        #{files_context}

        ## Instructions
        For each change, find the exact string in the source files that produces the rendered text. Consider:
        - The text might be in an HTML file, a template (Nunjucks, Liquid, ERB), a JSON data file, a Markdown file, an i18n/locale file, or a JS/React component.
        - Match using the DOM path, CSS classes, section context, and sibling texts to disambiguate.
        - If text is in a JSON data file, edit the JSON value (not the key).
        - If text appears in multiple places, use the context to pick the right one.
        - Return the EXACT old string and new string as they appear in the source file (not the rendered HTML).

        ## Response format
        Return ONLY a JSON array of edits. No explanation, no markdown — just the JSON:
        ```json
        [
          {
            "file": "path/to/file.ext",
            "old": "exact string in source file to find",
            "new": "exact replacement string"
          }
        ]
        ```
        If you cannot find where a change should be made, omit it from the array.
      PROMPT

      response = call_claude(prompt)

      # Parse JSON from response
      json_match = response.match(/\[[\s\S]*\]/)
      return [] unless json_match

      JSON.parse(json_match[0])
    rescue JSON::ParserError => e
      []
    end

    def call_claude(prompt)
      conn = Faraday.new(url: CLAUDE_API) do |f|
        f.options.timeout = 60
        f.options.open_timeout = 10
      end

      res = conn.post do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['x-api-key'] = @api_key
        req.headers['anthropic-version'] = '2023-06-01'
        req.body = {
          model: MODEL,
          max_tokens: 4096,
          messages: [
            { role: 'user', content: prompt }
          ]
        }.to_json
      end

      raise "Claude API error: #{res.status} — #{res.body}" unless res.success?

      body = JSON.parse(res.body)
      body.dig('content', 0, 'text') || ''
    end

    def build_pr_body(page, changes, edits)
      change_lines = changes.map do |c|
        "- \"#{truncate(c['old_text'], 50)}\" → \"#{truncate(c['new_text'], 50)}\""
      end.join("\n")

      file_lines = edits.map { |e| "- `#{e['file']}`" }.uniq.join("\n")

      <<~BODY
        ## Content update via UltimateCMS

        **Page:** [#{page['path']}](#{page['url']})

        ### Changes
        #{change_lines}

        ### Files modified
        #{file_lines}

        ---
        *This PR was created automatically by [UltimateCMS](https://github.com) — visual editing with AI-powered source mapping.*
      BODY
    end

    def truncate(str, len)
      return '' unless str
      str.length > len ? str[0...len] + '...' : str
    end
  end
end
