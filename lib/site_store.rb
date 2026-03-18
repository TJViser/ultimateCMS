require 'json'
require 'securerandom'

module UltimateCMS
  # Simple file-based store for prototype.
  # In production: replace with PostgreSQL / Redis.
  class SiteStore
    SITES_FILE = File.join(__dir__, '..', 'data', 'sites.json')
    SESSIONS_FILE = File.join(__dir__, '..', 'data', 'sessions.json')

    def initialize
      Dir.mkdir(File.dirname(SITES_FILE)) rescue nil
      @sites = load_file(SITES_FILE)
      @sessions = load_file(SESSIONS_FILE)
    end

    # --- Sites ---

    def create(repo:, branch:, github_token:, allowed_origins: [])
      key = "sk_#{SecureRandom.hex(8)}"
      site = {
        key: key,
        repo: repo,
        branch: branch,
        github_token: github_token,  # owner's token (for repo access)
        allowed_origins: allowed_origins,
        created_at: Time.now.iso8601
      }
      @sites[key] = site
      save_file(SITES_FILE, @sites)
      site
    end

    def get(key)
      @sites[key]
    end

    def list_for_token(token)
      @sites.values.select { |s| s[:github_token] == token }
    end

    # --- Sessions ---

    def save_session(token, data)
      @sessions[token] = data.merge(created_at: Time.now.iso8601)
      save_file(SESSIONS_FILE, @sessions)
    end

    def get_session(token)
      @sessions[token]
    end

    private

    def load_file(path)
      return {} unless File.exist?(path)
      data = JSON.parse(File.read(path))
      # Symbolize keys for each value
      data.transform_values { |v| v.is_a?(Hash) ? v.transform_keys(&:to_sym) : v }
    rescue
      {}
    end

    def save_file(path, data)
      # Convert symbol keys to strings for JSON
      json_data = data.transform_values { |v| v.is_a?(Hash) ? v.transform_keys(&:to_s) : v }
      File.write(path, JSON.pretty_generate(json_data))
    end
  end
end
